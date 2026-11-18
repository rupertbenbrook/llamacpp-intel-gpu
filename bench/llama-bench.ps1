<#
.SYNOPSIS
  Runs llama-bench inside the llamacpp image against the cached model.
  Stops the server first so the GPU memory is free, and restarts it afterwards.
.EXAMPLE
  ./bench/llama-bench.ps1 -Label baseline
  ./bench/llama-bench.ps1 -Label batch -BenchArgs '-p 4096 -n 0 -b 512,1024,2048 -ub 256,512,1024'
#>
param(
    [string]$Label = 'run',
    # Extra llama-bench arguments; values can be comma-separated lists to sweep
    [string]$BenchArgs = '-p 512,4096 -n 128 -fa 0,1',
    [int]$Repetitions = 2,
    # Substring of the GGUF file name to benchmark (searched in the models volume)
    [string]$Model = 'Qwen3.8-9B-Q4_K_M',
    [string]$GpuLayers = '99',
    [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'llama-bench-results.csv'

Push-Location $root
try {
    docker compose stop llamacpp | Out-Null
    $cmd = "m=`$(find /models -name '*.gguf' | grep -v mmproj | grep -- '$Model' | head -1); echo model=`$m >&2; " +
           "test -n `"`$m`" || exit 2; /app/llama-bench -m `$m -ngl $GpuLayers -r $Repetitions $BenchArgs -o csv"
    $csv = docker compose run --rm --no-deps -T --entrypoint sh llamacpp -c $cmd 2>$null |
        Where-Object { $_ -match '^"?build_commit|^"' }
    if (-not $csv) { throw 'llama-bench produced no output' }
    $rows = $csv | ConvertFrom-Csv
    $rows | ForEach-Object {
        [pscustomobject]@{
            timestamp = (Get-Date -Format s); label = $Label; model = $Model; test = if ([int]$_.n_prompt -gt 0) { "pp$($_.n_prompt)" } else { "tg$($_.n_gen)" }
            n_batch = $_.n_batch; n_ubatch = $_.n_ubatch; flash_attn = $_.flash_attn
            type_k = $_.type_k; type_v = $_.type_v; n_threads = $_.n_threads
            model_type = $_.model_type; avg_ts = [math]::Round([double]$_.avg_ts, 2); stddev_ts = [math]::Round([double]$_.stddev_ts, 2)
        }
    } | Tee-Object -Variable results | Export-Csv $out -Append
    $results | Format-Table label, test, n_batch, n_ubatch, flash_attn, type_k, avg_ts, stddev_ts -AutoSize
}
finally {
    if (-not $NoRestart) { docker compose up -d llamacpp | Out-Null }
    Pop-Location
}
