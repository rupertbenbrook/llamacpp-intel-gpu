<#
.SYNOPSIS
  Benchmarks the running llama-server the way opencode uses it:
  a large system prompt (like opencode's instructions + tool definitions) followed by
  a second conversation turn that should reuse the cached prompt.
.EXAMPLE
  ./bench/server-bench.ps1 -Label baseline
  # restart the server with different settings, then:
  $env:UBATCH_SIZE=1024; docker compose up -d; ./bench/server-bench.ps1 -Label ub1024
#>
param(
    [string]$Label = 'run',
    [int]$PromptTokens = 6000,
    [int]$GenTokens = 128,
    [string]$Url = 'http://localhost:8080'
)
$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'server-results.csv'

# wait for the server
for ($i = 0; $i -lt 90; $i++) {
    try { if ((Invoke-RestMethod "$Url/health" -TimeoutSec 5).status -eq 'ok') { break } } catch {}
    Start-Sleep 5
}

# Build a varied filler system prompt and trim it to roughly $PromptTokens tokens.
# A random nonce at the start guarantees nothing is served from a previous run's cache.
$nonce = [guid]::NewGuid().ToString()
$verbs = 'read', 'edit', 'search', 'list', 'run', 'write', 'review', 'refactor', 'test', 'document'
$things = 'file', 'directory', 'function', 'module', 'config', 'container', 'request', 'schema', 'branch', 'log'
$sb = [System.Text.StringBuilder]::new("Session $nonce. You are a coding agent. Follow these rules.`n")
$n = 1
while ($sb.Length -lt $PromptTokens * 5) {
    $v = $verbs[$n % 10]; $t = $things[[math]::Floor($n / 10) % 10]
    [void]$sb.AppendLine("Rule ${n}: when asked to $v a $t, first check the $($things[($n * 7) % 10]) and confirm the $($things[($n * 3) % 10]) is valid; report result code $(($n * 37) % 1000).")
    $n++
}
$text = $sb.ToString()
# Shrink iteratively because token counts are not proportional to character counts.
# Count chat-template tokens, not just raw text: the server includes message framing.
for ($i = 0; $i -lt 6; $i++) {
    $tokens = (Invoke-RestMethod "$Url/tokenize" -Method Post -ContentType 'application/json' -Body (@{
        messages = @(@{ role = 'system'; content = $text }, @{ role = 'user'; content = 'What result code does rule 17 report? Answer with just the number.' })
        add_special = $true
    } | ConvertTo-Json -Depth 5)).tokens.Count
    if ($tokens -le $PromptTokens + 40) { break }
    $text = $text.Substring(0, [int]($text.Length * ($PromptTokens / $tokens) * 0.98))
}

function Invoke-Chat($messages) {
    $body = @{ model = 'bench'; messages = $messages; max_tokens = $GenTokens; temperature = 0; cache_prompt = $true } | ConvertTo-Json -Depth 5
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "$Url/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3600
    $sw.Stop()
    [pscustomobject]@{ r = $r; wall = $sw.Elapsed.TotalSeconds }
}

$msgs = @(@{ role = 'system'; content = $text }, @{ role = 'user'; content = 'What result code does rule 17 report? Answer with just the number.' })
$t1 = Invoke-Chat $msgs
$msgs += @{ role = 'assistant'; content = [string]$t1.r.choices[0].message.content }
$msgs += @{ role = 'user'; content = 'And rule 42?' }
$t2 = Invoke-Chat $msgs

$envs = docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' llamacpp
$cfg = @{}; $envs | Where-Object { $_ -match '=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $cfg[$k] = $v }
$mem = (docker stats --no-stream --format '{{.MemUsage}}' llamacpp) -replace ' /.*'

$row = [pscustomobject]@{
    timestamp        = (Get-Date -Format s)
    label            = $Label
    model            = if ($cfg.MODEL_FILE) { Split-Path $cfg.MODEL_FILE -Leaf } else { $cfg.HF_MODEL -replace '^[^/]+/' -replace '-GGUF' }
    batch            = $cfg.BATCH_SIZE; ubatch = $cfg.UBATCH_SIZE; fa = $cfg.FLASH_ATTN
    kv               = "$($cfg.CACHE_TYPE_K)/$($cfg.CACHE_TYPE_V)"
    cache_reuse      = $cfg.CACHE_REUSE; cache_ram = $cfg.CACHE_RAM; ctx = $cfg.CTX_SIZE
    t1_prompt_tokens = $t1.r.timings.prompt_n
    t1_ttft_s        = [math]::Round($t1.r.timings.prompt_ms / 1000, 1)
    t1_pp_tps        = [math]::Round($t1.r.timings.prompt_per_second, 1)
    t1_tg_tps        = [math]::Round($t1.r.timings.predicted_per_second, 2)
    t2_cached_tokens = $t2.r.timings.cache_n
    t2_new_tokens    = $t2.r.timings.prompt_n
    t2_ttft_s        = [math]::Round($t2.r.timings.prompt_ms / 1000, 1)
    t2_tg_tps        = [math]::Round($t2.r.timings.predicted_per_second, 2)
    total_wall_s     = [math]::Round($t1.wall + $t2.wall, 1)
    container_mem    = $mem
}
$row | Export-Csv $out -Append
$row | Format-List
