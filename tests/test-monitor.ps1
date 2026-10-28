$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\monitor.ps1')

function Assert-Equal($actual, $expected, [string]$label) {
  if ($actual -ne $expected) { throw "$label : expected $expected, got $actual" }
  Write-Output "PASS $label"
}
$epoch = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
function New-Event([string]$type, $payload, [double]$seconds = 0) {
  @{ type=$type; payload=$payload; timestamp=$epoch.AddSeconds($seconds).ToString('o') } | ConvertTo-Json -Compress -Depth 12
}
function New-Token([double]$seconds, $tokens) {
  New-Event 'event_msg' @{ type='token_count'; info=@{ last_token_usage=@{ output_tokens=$tokens } } } $seconds
}
function New-Model([string]$model, [switch]$settings) {
  if ($settings) {
    New-Event 'event_msg' @{ type='thread_settings_applied'; thread_settings=@{ model=$model } }
  } else {
    New-Event 'turn_context' @{ model=$model }
  }
}
$fixtureRoot = Join-Path $PSScriptRoot ('.synthetic-' + [guid]::NewGuid().ToString('N'))
$fixturePaths = New-Object 'System.Collections.Generic.List[string]'
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
function Read-Fixture([string]$name, [string[]]$lines) {
  $path = Join-Path $fixtureRoot ($name + '.jsonl')
  $fixturePaths.Add($path)
  [IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
  Read-Session $path ([datetime]'2026-01-01')
}
try {
  $s = Read-Fixture 'basic' @(
    (New-Event 'session_meta' @{ id='main'; cwd='C:\synthetic\project' })
    (New-Model 'A')
    (New-Token 0 10)
    (New-Token 2 100)
    (New-Token 3 80)
  )
  Assert-Equal $s.Id 'main' 'session identity'
  Assert-Equal $s.Root 'main' 'main is its own root'
  Assert-Equal $s.Stats.A.Samples 2 'two adjacent samples'
  Assert-Equal $s.Stats.A.Latest 80 'latest TPS'
  Assert-Equal ($s.Stats.A.TokenSum / $s.Stats.A.SecondSum) 60 'weighted average TPS'

  $single = Read-Fixture 'single' @((New-Token 0 25))
  Assert-Equal $single.Id 'single' 'filename identity fallback'
  Assert-Equal $single.Stats.unknown.Samples 0 'single event has no TPS'
  Assert-Equal $single.Stats.unknown.Name 'unknown' 'missing model stays unknown'

  foreach ($settings in @($false, $true)) {
    $s = Read-Fixture ('switch-' + $settings) @(
      (New-Model 'A' -settings:$settings)
      (New-Token 0 10)
      (New-Model 'B' -settings:$settings)
      (New-Model 'A' -settings:$settings)
      (New-Token 2 100)
      (New-Token 3 80)
    )
    Assert-Equal $s.Stats.A.Samples 1 "A-B-A resets interval, settings=$settings"
    Assert-Equal $s.Stats.A.Latest 80 "post-switch latest, settings=$settings"
  }

  $s = Read-Fixture 'two-models' @(
    (New-Model 'A')
    (New-Token 0 10)
    (New-Token 1 50)
    (New-Model 'B')
    (New-Token 2 10)
    (New-Token 4 120)
  )
  Assert-Equal $s.Stats.A.Latest 50 'model A stays separate'
  Assert-Equal $s.Stats.B.Latest 60 'model B stays separate'

  $s = Read-Fixture 'limits' @(
    (New-Token 0 10)
    (New-Token 0.1 100)
    (New-Token 0.35 10)
    (New-Token 600.35 600)
    (New-Token 1200.6 100)
    (New-Token 1201.6 0)
    (New-Token 1202.6 -5)
  )
  Assert-Equal $s.Stats.unknown.Samples 2 'inclusive 0.25 and 600 second limits'
  Assert-Equal $s.Stats.unknown.TokenSum 610 'reject short, long, zero and negative samples'

  $s = Read-Fixture 'partial' @(
    (New-Model 'A')
    (New-Token 0 10)
    '{"type":"event_msg","payload":{"type":"token_count"'
    '{"type":"event_msg","timestamp":"invalid","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":100}}}}'
    (New-Token 1 'invalid')
    (New-Token 2 100)
    (New-Model 'A')
    (New-Token 3 80)
  )
  Assert-Equal $s.Stats.A.Samples 2 'partial and malformed events skipped; same model keeps interval'

  $s = Read-Fixture 'repeated' @(
    (New-Token 0 10)
    (New-Token 1 50)
    (New-Token 1 50)
    (New-Token 2 50)
  )
  Assert-Equal $s.Stats.unknown.Samples 2 'same timestamp ignored; later identical usage still counts'
  Assert-Equal $s.Stats.unknown.TokenSum 100 'documented repeated snapshot limitation'

  $s = Read-Fixture 'child' @(
    (New-Event 'session_meta' @{ id='child'; source=@{ subagent=@{ thread_spawn=@{ parent_thread_id='main' } } } })
  )
  Assert-Equal $s.Parent 'main' 'nested parent metadata'
  Assert-Equal $s.Root 'main' 'direct child grouping'

  $s = Read-Fixture 'grandchild' @(
    (New-Event 'session_meta' @{ id='grandchild'; parent_thread_id='child' })
  )
  Assert-Equal $s.Root 'child' 'documented one-level grouping limitation'

  $sorted = @(Sort-SessionMembers @(
    [pscustomobject]@{ Id='old-agent'; Root='main'; Modified=[datetime]'2026-01-02' }
    [pscustomobject]@{ Id='new-agent'; Root='main'; Modified=[datetime]'2026-01-03' }
    [pscustomobject]@{ Id='main'; Root='main'; Modified=[datetime]'2026-01-01' }
  ))
  Assert-Equal ($sorted.Id -join ',') 'main,new-agent,old-agent' 'main first, then newest agents'
  Write-Output 'All synthetic checks passed. No real session logs were read.'
} finally {
  if ($fixturePaths.Count -gt 0) { Remove-Item -LiteralPath $fixturePaths.ToArray() -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $fixtureRoot -ErrorAction SilentlyContinue
}
