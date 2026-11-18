<#
.SYNOPSIS
  Run isolated C#/.NET/Docker coding-agent challenges against the configured OpenCode model.
  Verification sources are outside the agent workspace. Requires .NET 11, Docker for the docker
  challenge and a running local llama.cpp server. Results go to ../dotnet-results.csv (ignored).
.EXAMPLE
  ./bench/dotnet/run.ps1 -Label baseline -Task pagination
  ./bench/dotnet/run.ps1 -Label baseline -Task pagination,filter,cancellation,docker
#>
param(
    [string]$Label = 'run',
    [ValidateSet('pagination', 'filter', 'cancellation', 'docker')]
    [string[]]$Task = @('pagination', 'filter', 'cancellation', 'docker'),
    [string]$Model = 'llamacpp/qwen3.8-9b',
    [int]$TimeoutMinutes = 15,
    [string]$WorkDirectory = (Join-Path $env:TEMP 'oc-dotnet-bench'),
    [switch]$KeepWorkspace
)
$ErrorActionPreference = 'Stop'
$bench = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $bench -Parent
$resultsPath = Join-Path $bench 'dotnet-results.csv'
$verifyProject = Join-Path $PSScriptRoot 'verify/AgentBench.Verify.csproj'
$fixture = Join-Path $PSScriptRoot 'fixture'
$prompts = @{
    pagination = 'Fix the pagination bug in TicketService.ListAsync: pages are 1-based, and TotalCount should describe all matches, not just the current page. Keep argument validation. Build the solution when done.'
    cancellation = 'Ensure TicketService.ListAsync forwards the caller CancellationToken to the repository, including when it is already cancelled. Do not change the public API. Build the solution when done.'
    filter = 'Add an optional status filter to GET /api/tickets, pass it to TicketService.ListAsync, and filter case-insensitively before pagination and TotalCount. An absent status must return all tickets. Keep existing endpoint behaviour and build the solution.'
    docker = 'Fix the Dockerfile so a container serves /health to the host on port 8080. Preserve SDK/runtime stages and do not change app source. Build context is the solution root (docker build -f src/AgentBench.Api/Dockerfile .). Verify it by starting a container and reaching the endpoint from the host.'
}

try { $h = Invoke-RestMethod 'http://127.0.0.1:8080/health' -TimeoutSec 10; if ($h.status -ne 'ok') { throw 'not ready' } }
catch { throw "Local model is not ready at http://127.0.0.1:8080/health: $_" }

$results = foreach ($challenge in $Task) {
    # Stable path allows prompt cache reuse. Delete all prior outputs between challenges.
    Remove-Item $WorkDirectory -Force -Recurse -ErrorAction SilentlyContinue
    Copy-Item $fixture $WorkDirectory -Recurse
    Copy-Item (Join-Path $repo 'opencode.json') $WorkDirectory
    $dockerTag = 'oc-dotnet-bench:verify'
    $port = 18081
    $containerName = 'oc-dotnet-bench-verify'
    $stdout = Join-Path $env:TEMP "oc-dotnet-$challenge-$PID.out"
    $stderr = Join-Path $env:TEMP "oc-dotnet-$challenge-$PID.err"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $errorText = ''
    $pass = $false
    try {
        $prompt = $prompts[$challenge]
        # Windows Start-Process joins ArgumentList into a single command line: quote prompts
        # (especially -p in `docker run -p`) so flags inside the prompt are not parsed as CLI options.
        $quotedPrompt = '"' + ($prompt -replace '"', '\"') + '"'
        $p = Start-Process opencode -WorkingDirectory $WorkDirectory -ArgumentList @('run', '--standalone', '-m', $Model, $quotedPrompt) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
        if (-not $p.WaitForExit($TimeoutMinutes * 60000)) {
            $timedOut = $true
            # Kill the process tree, not just the CLI parent.
            taskkill /PID $p.Id /T /F 2>$null | Out-Null
        }
        if (-not $timedOut) {
            $p.Refresh()
            if ($p.ExitCode -ne 0) {
                $cliError = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
                throw "OpenCode exited $($p.ExitCode): $cliError"
            }
            $buildOutput = & dotnet build (Join-Path $WorkDirectory 'AgentBench.slnx') --nologo -v q 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "Build failed: $($buildOutput.Trim() | Select-Object -Last 1)" }
            if ($challenge -ne 'docker') {
                $verification = & dotnet run --project $verifyProject "-p:FixtureRoot=$WorkDirectory" -- $challenge 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Hidden verifier: $($verification.Trim())" }
                if ($challenge -eq 'filter') {
                    # Test the real HTTP API independently of service-level verification.
                    $env:ASPNETCORE_URLS = "http://127.0.0.1:$port"
                    $apiOut = Join-Path $env:TEMP "oc-dotnet-api-$PID.out"
                    $apiErr = Join-Path $env:TEMP "oc-dotnet-api-$PID.err"
                    $api = Start-Process dotnet -ArgumentList @('run', '--no-build', '--project', (Join-Path $WorkDirectory 'src/AgentBench.Api')) -PassThru -NoNewWindow -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr
                    try {
                        $ready = $false
                        for ($i = 0; $i -lt 30; $i++) {
                            try { $response = Invoke-RestMethod "http://127.0.0.1:$port/api/tickets?status=open&page=2&pageSize=2" -TimeoutSec 3; $ready = $true; break } catch { Start-Sleep 1 }
                        }
                        if (-not $ready -or $response.totalCount -ne 3 -or @($response.items).Count -ne 1 -or $response.items[0].id -ne 5) { throw 'HTTP filter/page 2 verification failed' }
                    }
                    finally { taskkill /PID $api.Id /T /F 2>$null | Out-Null; Remove-Item Env:ASPNETCORE_URLS -ErrorAction SilentlyContinue }
                }
            }
            else {
                # Run the actual image. A correct Dockerfile must listen on 0.0.0.0, not localhost.
                $dockerOutput = & docker build --quiet -t $dockerTag -f (Join-Path $WorkDirectory 'src/AgentBench.Api/Dockerfile') $WorkDirectory 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw "Docker build failed: $($dockerOutput.Trim())" }
                & docker run -d --name $containerName -p "127.0.0.1:${port}:8080" $dockerTag | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'docker run failed' }
                $ready = $false
                for ($i = 0; $i -lt 30; $i++) {
                    try { if ((Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 3).status -eq 'ok') { $ready = $true; break } } catch { Start-Sleep 1 }
                }
                if (-not $ready) { throw 'Container health endpoint unreachable from host' }
                $dockerfile = Get-Content (Join-Path $WorkDirectory 'src/AgentBench.Api/Dockerfile') -Raw
                if ($dockerfile -notmatch 'FROM\s+mcr\.microsoft\.com/dotnet/sdk:11' -or $dockerfile -notmatch 'FROM\s+mcr\.microsoft\.com/dotnet/aspnet:11') { throw 'Must preserve SDK/runtime stages' }
            }
            $pass = $true
        }
    }
    catch { $errorText = "$_" }
    finally {
        if ($challenge -eq 'docker') { & docker rm -f $containerName 2>$null | Out-Null }
        $sw.Stop()
    }
    $reply = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { '' }
    $reply = $reply -replace '\x1b\[[0-9;]*m', ''
    [pscustomobject]@{
        timestamp = (Get-Date -Format s); label = $Label; model = $Model; task = $challenge
        pass = $pass; timeout = $timedOut; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        error = ($errorText -replace '[\r\n]+', ' ')
        reply_tail = (($reply.Trim() -split '\r?\n' | Select-Object -Last 2) -join ' | ').Trim()
    }
    if ($KeepWorkspace -and -not $pass) { Write-Host "Agent output saved to $stdout and $stderr" }
    else { Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue }
    if (-not $KeepWorkspace) { Remove-Item $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
$results | Export-Csv $resultsPath -Append
$results | Format-Table task, pass, timeout, seconds, error, reply_tail -AutoSize -Wrap
"Passed $(@($results | Where-Object pass).Count)/$($results.Count) in $([math]::Round(($results | Measure-Object seconds -Sum).Sum / 60, 1)) min"
