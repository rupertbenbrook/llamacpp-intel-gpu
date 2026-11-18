<#
.SYNOPSIS
  Runs a fixed set of real opencode agent tasks against the local model and records
  wall time and pass/fail for each. Each run uses a fresh copy of bench/fixture.
.EXAMPLE
  ./bench/opencode-tasks.ps1 -Label baseline
#>
param(
    [string]$Label = 'run',
    [string]$Model = 'llamacpp/qwen3.8-9b',
    [int]$TimeoutMinutes = 15
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'opencode-results.csv'

$tasks = @(
    @{ name = 'read';   prompt = 'Read notes.md and tell me which port the API service listens on. Answer with just the number.'
       check = { param($o, $d) $o -match '8080' } }
    @{ name = 'search'; prompt = 'Which file in this project defines the function parse_config? Answer with just the file path.'
       check = { param($o, $d) $o -match 'loader\.py' } }
    @{ name = 'edit';   prompt = 'In notes.md change the API service port from 8080 to 9090. Do not change anything else.'
       check = { param($o, $d) $c = Get-Content (Join-Path $d 'notes.md') -Raw; $c -match '9090' -and $c -notmatch '8080' -and $c -match 'unless-stopped' } }
    @{ name = 'bugfix'; prompt = 'The area function in src/geometry.py returns the wrong result. Fix the bug.'
       check = { param($o, $d) (Get-Content (Join-Path $d 'src/geometry.py') -Raw) -match 'return\s+width\s*\*\s*height' } }
)

$results = foreach ($t in $tasks) {
    # Same path every time (like a real project dir) so opencode's prompt prefix is identical across sessions
    $dir = Join-Path $env:TEMP 'oc-bench-work'
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $PSScriptRoot 'fixture') $dir -Recurse
    Copy-Item (Join-Path $root 'opencode.json') $dir
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        param($dir, $model, $prompt)
        Set-Location $dir
        opencode run --standalone -m $model $prompt 2>&1 | Out-String
    } -ArgumentList $dir, $Model, $t.prompt
    $done = Wait-Job $job -Timeout ($TimeoutMinutes * 60)
    $output = if ($done) { Receive-Job $job } else { Stop-Job $job; 'TIMEOUT' }
    Remove-Job $job -Force
    $sw.Stop()
    $plain = $output -replace '\x1b\[[0-9;]*m'
    $pass = ($plain -ne 'TIMEOUT') -and [bool](& $t.check $plain $dir)
    $tools = ([regex]::Matches($plain, '(?m)^\s*\S{1,2}\s+(Read|Edit|Write|Grep|Glob|List|Bash|Search|Patch)\b')).Count
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        timestamp = (Get-Date -Format s); label = $Label; task = $t.name
        pass = $pass; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 0); tool_calls = $tools
        tail = (($plain.Trim() -split "`n" | Select-Object -Last 2) -join ' | ').Trim()
    }
}
$results | Export-Csv $out -Append
$results | Format-Table label, task, pass, seconds, tool_calls, tail -AutoSize -Wrap
"Passed $(@($results | Where-Object pass).Count)/$($results.Count), total $([math]::Round(($results | Measure-Object seconds -Sum).Sum / 60, 1)) min"
