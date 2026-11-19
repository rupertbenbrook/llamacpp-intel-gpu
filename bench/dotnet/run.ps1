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
    [int]$TimeoutMinutes = 30,
    [string]$WorkDirectory = (Join-Path $env:TEMP 'oc-dotnet-bench'),
    [switch]$NoWarmup,
    [switch]$KeepWorkspace
)
$ErrorActionPreference = 'Stop'
$bench = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $bench -Parent
$resultsPath = Join-Path $bench 'dotnet-results.csv'
$verifyProject = Join-Path $PSScriptRoot 'verify/AgentBench.Verify.csproj'
$fixture = Join-Path $PSScriptRoot 'fixture'
# The bench workspace is the only directory the runner deletes. Keep it outside the fixture and repo.
$workspacePath = [IO.Path]::GetFullPath($WorkDirectory).TrimEnd('\', '/')
$fixturePath = [IO.Path]::GetFullPath($fixture).TrimEnd('\', '/')
$repoPath = [IO.Path]::GetFullPath($repo).TrimEnd('\', '/')
if ($workspacePath.Equals($fixturePath, [StringComparison]::OrdinalIgnoreCase) -or $workspacePath.Equals($repoPath, [StringComparison]::OrdinalIgnoreCase) -or $repoPath.StartsWith($workspacePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $fixturePath.StartsWith($workspacePath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe WorkDirectory: $WorkDirectory"
}
$prompts = @{
    pagination = 'Fix the pagination bug in TicketService.ListAsync: pages are 1-based, and TotalCount should describe all matches, not just the current page. Keep argument validation. Build the solution when done.'
    cancellation = 'Ensure TicketService.ListAsync forwards the caller CancellationToken to the repository, including when it is already cancelled. Do not change the public API. Build the solution when done.'
    filter = 'Implement this complete change in the API and service. Add an optional status query parameter to GET /api/tickets and pass it to TicketService.ListAsync. Filter case-insensitively before TotalCount and paging. Pagination is 1-based: page 1 uses Skip(0), page 2 uses Skip(pageSize). With the fixture and status=open, pageSize=2 must return IDs [1,3] on page 1, [5] on page 2, and TotalCount must be 3. Without status, all 5 tickets remain. Preserve validation and compatibility. Run dotnet build AgentBench.slnx and fix every compiler error before finishing.'
    docker = 'Fix only src/AgentBench.Api/Dockerfile so the API will serve /health through a published port. Preserve the SDK/runtime stages and do not change app source. The external verifier will build and run the Docker image, so do not run Docker commands yourself. Make the app listen on 0.0.0.0 inside the container, not 127.0.0.1. Run dotnet build AgentBench.slnx and fix all compiler errors before finishing.'
}

try { $h = Invoke-RestMethod 'http://127.0.0.1:8080/health' -TimeoutSec 10; if ($h.status -ne 'ok') { throw 'not ready' } }
catch { throw "Local model is not ready at http://127.0.0.1:8080/health: $_" }

if (-not $NoWarmup) {
    # Warm the stable OpenCode/system-prompt prefix once; exclude this from task timings.
    $warm = Start-Process opencode -ArgumentList @('run', '--standalone', '-m', $Model, 'Reply with exactly OK.') -PassThru -Wait -NoNewWindow -RedirectStandardOutput (Join-Path $env:TEMP 'oc-dotnet-warm.out') -RedirectStandardError (Join-Path $env:TEMP 'oc-dotnet-warm.err')
    if ($warm.ExitCode -ne 0) { throw "Warmup failed with exit code $($warm.ExitCode)" }
}

$results = foreach ($challenge in $Task) {
    # Stable path allows prompt cache reuse. Delete all prior outputs between challenges.
    Write-Host ("[{0}] preparing {1}: reset workspace" -f (Get-Date -Format HH:mm:ss), $challenge)
    Remove-Item $WorkDirectory -Force -Recurse -ErrorAction SilentlyContinue
    if (Test-Path $WorkDirectory) { throw "Could not clear benchmark workspace: $WorkDirectory" }
    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
    Copy-Item (Join-Path $fixture '*') $WorkDirectory -Recurse -Force
    Copy-Item (Join-Path $fixture '.dockerignore') $WorkDirectory -Force
    Get-ChildItem $WorkDirectory -Directory -Recurse -Include bin,obj | Remove-Item -Recurse -Force
    Copy-Item (Join-Path $repo 'opencode.json') $WorkDirectory -Force
    foreach ($required in @('AgentBench.slnx', 'AGENTS.md', 'src/AgentBench.Api/Dockerfile', 'src/AgentBench.Core/Tickets.cs')) {
        if (-not (Test-Path (Join-Path $WorkDirectory $required))) { throw "Benchmark workspace is missing $required in $WorkDirectory" }
    }
    $dockerTag = 'oc-dotnet-bench:verify'
    $port = 18081
    $containerName = 'oc-dotnet-bench-verify'
    $stdout = Join-Path $env:TEMP "oc-dotnet-$challenge-$PID.out"
    $stderr = Join-Path $env:TEMP "oc-dotnet-$challenge-$PID.err"
    $logFile = Join-Path (Join-Path $bench 'dotnet-agent-log') "$challenge-$PID.log"
    New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null
    $timedOut = $false
    $errorText = ''
    $pass = $false
    if ($challenge -eq 'docker') { & docker rm -f $containerName 2>$null | Out-Null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $prompt = $prompts[$challenge]
        # Windows Start-Process joins ArgumentList into a single command line: quote prompts
        # (especially -p in `docker run -p`) so flags inside the prompt are not parsed as CLI options.
        $quotedPrompt = '"' + ($prompt -replace '"', '\"') + '"'
        $p = Start-Process opencode -WorkingDirectory $WorkDirectory -ArgumentList @('run', '--standalone', '-m', $Model, $quotedPrompt) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow

        # OpenCode writes tool activity and retries to stderr; stdout is usually empty until completion.
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $lastOutSize = 0L
        $lastErrSize = 0L
        $lastActivity = Get-Date
        $lastHeartbeat = Get-Date
        Write-Host ("[{0}] {1}: started (timeout {2} min)" -f (Get-Date -Format HH:mm:ss), $challenge, $TimeoutMinutes)
        while (-not $p.HasExited) {
            Start-Sleep -Seconds 10
            $outSize = if (Test-Path $stdout) { (Get-Item $stdout).Length } else { 0L }
            $errSize = if (Test-Path $stderr) { (Get-Item $stderr).Length } else { 0L }
            if ($outSize -ne $lastOutSize -or $errSize -ne $lastErrSize) {
                $lastOutSize = $outSize
                $lastErrSize = $errSize
                $lastActivity = Get-Date
                $lastHeartbeat = Get-Date
                $source = if ($errSize -gt 0) { $stderr } else { $stdout }
                $tail = (Get-Content $source -Tail 1 -ErrorAction SilentlyContinue) -join ' '
                $tail = ($tail -replace '\x1b\[[0-9;]*m', '').Trim()
                if ($tail.Length -gt 110) { $tail = $tail.Substring(0, 110) }
                Write-Host ("[{0}] {1}: {2} min, stderr {3} KB | {4}" -f (Get-Date -Format HH:mm:ss), $challenge, [math]::Round($sw.Elapsed.TotalMinutes, 1), [math]::Round($errSize / 1024, 1), $tail)
            }
            if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 60) {
                Write-Host ("[{0}] {1}: {2} min elapsed; last agent output {3} min ago" -f (Get-Date -Format HH:mm:ss), $challenge, [math]::Round($sw.Elapsed.TotalMinutes, 1), [math]::Round(((Get-Date) - $lastActivity).TotalMinutes, 1))
                $lastHeartbeat = Get-Date
            }
        }
        if ($timedOut) {
            Write-Host ("[{0}] {1}: TIMEOUT after {2} min, killing process tree" -f (Get-Date -Format HH:mm:ss), $challenge, $TimeoutMinutes)
            & taskkill /PID $p.Id /T /F 2>$null | Out-Null
            for ($i = 0; $i -lt 30 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh() }
            if (-not $p.HasExited) { Write-Host "Warning: OpenCode process $($p.Id) still alive after kill" }
        }
        else {
            Write-Host ("[{0}] {1}: agent finished in {2} min" -f (Get-Date -Format HH:mm:ss), $challenge, [math]::Round($sw.Elapsed.TotalMinutes, 1))
        }
        if (-not $timedOut) {
            $p.Refresh()
            if ($p.ExitCode -ne 0) {
                $cliError = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { '' }
                throw "OpenCode exited $($p.ExitCode): $cliError"
            }
        }
        if (-not $timedOut) {
            Write-Host ("[{0}] {1}: external verification started" -f (Get-Date -Format HH:mm:ss), $challenge)
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
    $reply = if (Test-Path $stdout) { (Get-Content $stdout -Raw) } else { '' }
    $agentErrors = if (Test-Path $stderr) { (Get-Content $stderr -Raw) } else { '' }
    $reply = $reply -replace '\x1b\[[0-9;]*m', ''
    $agentErrors = $agentErrors -replace '\x1b\[[0-9;]*m', ''
    if (-not $pass) { [System.IO.File]::WriteAllText($logFile, "STDOUT:`n$reply`nSTDERR:`n$agentErrors") }
    [pscustomobject]@{
        timestamp = (Get-Date -Format s); label = $Label; model = $Model; task = $challenge
        pass = $pass; timeout = $timedOut; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        error = ($errorText -replace '[\r\n]+', ' ')
        reply_tail = (([string]$reply).Trim() -split '\r?\n' | Select-Object -Last 2) -join ' | ' -replace '^\s+|\s+$', ''
    }
    Write-Host ("[{0}] {1}: {2} in {3} s{4}" -f (Get-Date -Format HH:mm:ss), $challenge, $(if ($pass) { 'PASS' } elseif ($timedOut) { 'TIMEOUT' } else { 'FAIL' }), [math]::Round($sw.Elapsed.TotalSeconds, 1), $(if ($errorText) { " | $errorText" } else { '' }))
    if (-not $pass) { Write-Host "Failed task agent log: $logFile" }
    if ($KeepWorkspace -and -not $pass) { Write-Host "Agent output also saved to $stdout and $stderr" }
    else { Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue }
    if (-not $KeepWorkspace) { Remove-Item $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
$results | Export-Csv $resultsPath -Append
$results | Format-Table task, pass, timeout, seconds, error, reply_tail -AutoSize -Wrap
"Passed $(@($results | Where-Object pass).Count)/$($results.Count) in $([math]::Round(($results | Measure-Object seconds -Sum).Sum / 60, 1)) min"
