# Codex TPS dashboard v4. Read-only local JSONL; no external dependencies/network/IPC.
$ErrorActionPreference = 'Stop'

function Get-Text($obj, [string]$key) {
  if ($null -eq $obj) { return '' }
  $prop = $obj.PSObject.Properties[$key]
  if ($null -eq $prop -or $null -eq $prop.Value) { return '' }
  return [string]$prop.Value
}
function Read-Session([string]$path, [datetime]$modified) {
  $stream = [System.IO.File]::Open($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  $reader = New-Object System.IO.StreamReader($stream,[System.Text.Encoding]::UTF8)
  $id = ''; $parent = ''; $rootId = ''; $model = 'unknown'; $cwd = ''
  $stats = @{}; $prevEvent = $null; $lastUsage = $null
  try {
    while ($null -ne ($line = $reader.ReadLine())) {
      if ($line -notmatch '"(session_meta|turn_context|token_count|thread_settings_applied)"') { continue }
      try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue } # partial line
      $p = $e.payload
      if ($e.type -eq 'session_meta') {
        $id = Get-Text $p 'id'
        $parent = Get-Text $p 'parent_thread_id'
        $rootId = Get-Text $p 'session_id'
        if (-not $parent -and $p.source -and $p.source.subagent -and $p.source.subagent.thread_spawn) {
          $parent = Get-Text $p.source.subagent.thread_spawn 'parent_thread_id'
        }
        $cwd = Get-Text $p 'cwd'
      }
      if ($e.type -eq 'turn_context') {
        $m = Get-Text $p 'model'
        if ($m -and $m -ne $model) { $model = $m; $prevEvent = $null }
      }
      if ($e.type -eq 'event_msg' -and $p.type -eq 'thread_settings_applied') {
        $m = Get-Text $p.thread_settings 'model'
        if ($m -and $m -ne $model) { $model = $m; $prevEvent = $null }
      }
      if ($e.type -ne 'event_msg' -or $p.type -ne 'token_count' -or -not $p.info -or -not $p.info.last_token_usage) { continue }
      # shortcut: repeated usage may count twice; revisit when event identity is reliable.
      $rawTokens = Get-Text $p.info.last_token_usage 'output_tokens'
      if (-not $rawTokens) { continue }
      try { $t = [DateTimeOffset]::Parse([string]$e.timestamp); $tokens = [double]::Parse($rawTokens,[Globalization.CultureInfo]::InvariantCulture) } catch { continue }
      if (-not $stats.ContainsKey($model)) {
        $stats[$model] = [pscustomobject]@{ Name=$model; Samples=0; TokenSum=[double]0; SecondSum=[double]0; Latest=[double]0; LatestAt=$t }
      }
      $s = $stats[$model]
      # Only compare adjacent token events of the same model; skip model switches.
      if ($null -ne $prevEvent -and $prevEvent.Model -eq $model) {
        $dt = ($t - $prevEvent.Time).TotalSeconds
        if ($dt -ge 0.25 -and $dt -le 600 -and $tokens -gt 0) {
          $s.Samples++
          $s.TokenSum += $tokens
          $s.SecondSum += $dt
          $s.Latest = $tokens / $dt
          $s.LatestAt = $t
        }
      }
      $prevEvent = [pscustomobject]@{ Time=$t; Model=$model }
      $lastUsage = $t
    }
  } finally { $reader.Dispose() }
  if (-not $id) { $id = [IO.Path]::GetFileNameWithoutExtension($path) }
  # shortcut: grouping follows direct parents only; extend after nested-log validation.
  if (-not $rootId) { $rootId = if ($parent) { $parent } else { $id } }
  if ($rootId -eq $id -and $parent) { $rootId = $parent }
  return [pscustomobject]@{ Id=$id; Parent=$parent; Root=$rootId; Cwd=$cwd; Modified=$modified; Stats=$stats; Path=$path; LastUsage=$lastUsage }
}
function Sort-SessionMembers([object[]]$members) {
  $members | Sort-Object @{Expression={ if ($_.Id -eq $_.Root) {0} else {1} }; Ascending=$true}, @{Expression='Modified'; Descending=$true}
}
function ShortId([string]$id) { if ($id.Length -gt 8) { return $id.Substring(0,8) }; return $id }
function Put-Frame([string[]]$lines) {
  $width = [Math]::Max(30,[Console]::WindowWidth - 1)
  $height = [Console]::WindowHeight
  $count = [Math]::Min($lines.Count,$height - 1)
  try { [Console]::SetCursorPosition(0,0) } catch { return }
  for ($j=0; $j -lt [Math]::Max($count,$script:lastFrameLines); $j++) {
    if ($j -ge ($height - 1)) { break }
    $row = if ($j -lt $count) { $lines[$j] } else { '' }
    if ($row.Length -gt $width) { $row = $row.Substring(0,$width) }
    [Console]::Write($row.PadRight($width))
    if ($j -lt ($height - 2)) { [Console]::WriteLine() }
  }
  $script:lastFrameLines = $count
}

# Importing functions for synthetic tests must never start the session scan.
if ($MyInvocation.InvocationName -eq '.') { return }

$base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$root = Join-Path $base 'sessions'
$lastFrameLines = 0
$maxFiles = 80
$activeMinutes = 15

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try { [Console]::Clear(); [Console]::CursorVisible = $false } catch { }
try {
  while ($true) {
    $now = Get-Date
    $out = New-Object 'System.Collections.Generic.List[string]'
    $out.Add('Codex TPS  |  session / model / subagent  |  Ctrl+C to exit')
    $out.Add('Local read-only | Scan + 3s pause | TPS = estimate from log events')
    $out.Add('')
    if (-not (Test-Path -LiteralPath $root)) {
      $out.Add('Log folder not found: ' + $root)
    } else {
      $files = @(Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $now.AddMinutes(-$activeMinutes) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First $maxFiles)
      $sessions = @()
      foreach ($file in $files) {
        try { $sessions += Read-Session $file.FullName $file.LastWriteTime } catch { } # retry on next refresh
      }
      $roots = @($sessions | Group-Object Root | Sort-Object { ($_.Group | Measure-Object Modified -Maximum).Maximum } -Descending)
      $index = 0
      foreach ($g in $roots) {
        $index++
        $members = @(Sort-SessionMembers $g.Group)
        $main = @($members | Where-Object { $_.Id -eq $_.Root } | Select-Object -First 1)
        $project = if ($main.Count -gt 0 -and $main[0].Cwd) { Split-Path $main[0].Cwd -Leaf } else { 'project unknown' }
        $out.Add(('Session {0} [{1}]  {2}' -f $index,(ShortId $g.Name),$project))
        foreach ($member in $members) {
          $who = if ($member.Id -eq $g.Name) { 'main' } else { 'agent ' + (ShortId $member.Id) }
          if ($member.Stats.Count -eq 0) {
            $out.Add(('  {0}: waiting for token samples' -f $who))
            continue
          }
          foreach ($stat in @($member.Stats.Values | Sort-Object Name)) {
            $latest = '--'; $average = '--'; $state='waiting'
            if ($stat.Samples -gt 0) {
              $latest = ('{0:N1}' -f $stat.Latest)
              $average = ('{0:N1}' -f ($stat.TokenSum / $stat.SecondSum))
              $age = ($now.ToUniversalTime() - $stat.LatestAt.UtcDateTime).TotalSeconds
              $state = if ($age -le 15) { 'recent' } else { 'idle' }
            }
            $out.Add(('  {0} | {1} | TPS ~{2} | Avg ~{3} | {4} | n={5}' -f $who,$stat.Name,$latest,$average,$state,$stat.Samples))
          }
        }
        $out.Add('')
      }
      if ($roots.Count -eq 0) { $out.Add('Waiting for recent Codex sessions...') }
    }
    $out.Add('Avg = sum(output tokens) / sum(event intervals), per session+model.')
    $out.Add('recent/idle is inferred; not a guaranteed running status.')
    $out.Add('Different models/agents NEVER combined. Intervals may include wait time.')
    Put-Frame $out.ToArray()
    Start-Sleep -Seconds 3
  }
} finally { try { [Console]::CursorVisible = $true } catch {} }
