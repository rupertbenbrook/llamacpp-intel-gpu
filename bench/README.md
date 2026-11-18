# Benchmarking & tuning

Three levels of measurement, from fastest to most realistic. Each appends to a CSV in this folder.

| Script | Measures | Output |
|---|---|---|
| `llama-bench.ps1` | Raw prompt-processing (pp) and generation (tg) tokens/s; sweeps settings | `llama-bench-results.csv` |
| `server-bench.ps1` | An opencode-shaped exchange: ~6k-token system prompt, then a 2nd turn that should reuse the cache. Time to first token, speeds, memory | `server-results.csv` |
| `opencode-tasks.ps1` | Real `opencode run` tasks (read, search, edit, bugfix) on a copy of `fixture/`; pass/fail + wall time | `opencode-results.csv` |

## Changing settings

All server settings in `compose.yml` take `${VAR:-default}` values, so a run can override them from the shell without editing files:

```powershell
$env:UBATCH_SIZE = 1024; $env:FLASH_ATTN = 'on'
docker compose up -d                       # recreates the container with the new settings
./bench/server-bench.ps1 -Label 'ub1024-fa'
Remove-Item env:UBATCH_SIZE, env:FLASH_ATTN  # back to defaults
```

To keep a setting permanently, change its default in `compose.yml`.

`llama-bench` sweeps comma-separated values in one go (stops the server while it runs):

```powershell
./bench/llama-bench.ps1 -Label batch -BenchArgs '-p 4096 -n 0 -b 2048 -ub 256,512,1024,2048'
```

## Findings (Arrow Lake iGPU, Qwen3.8-9B Distill)

| Step | Result | Kept? |
|---|---|---|
| Flash attention on | pp ≈ same, tg 9.0 → 8.1 t/s | No (off) |
| ubatch 512 → 1024 | pp +4% (92 → 96 t/s) | Yes |
| GGML_SYCL_DISABLE_OPT / _GRAPH | no gain / slower | No |
| KV cache q8_0 | slightly slower | No (use only to save memory) |
| Quant Q8_0 / Q4_0 vs Q4_K_M | tg 5.5 / 4.4 vs 9.2 t/s | Q4_K_M |
| GPU vs CPU-only | pp 1.6x, tg 5x faster on GPU | GPU |
| `CACHE_RAM=8192` | new opencode sessions reuse the cached ~6k-token prompt: 4 tasks 8.0 → 4.5 min | Yes |
| `REASONING_BUDGET=0` | 4.5 → 3.1 min, 4/4 pass on simple tasks | Optional |

## Notes
- opencode's real system prompt is about 6k tokens, so prompt-processing speed and cache reuse matter more than generation speed.
- A 35B MoE model is also under test. Forcing all layers onto the GPU caused an out-of-memory crash. At Q4_K_M/128k with automatic fitting and a 3 GB safety margin it was stable but **impractically slow**: 7.4 prompt tokens/s and 0.64–2.1 generated tokens/s (versus ~75/~9 for the 9B), with 8.5 GB of Docker memory and 16.4 GB of GPU-shared memory used. Smaller quantisations are being investigated. The 9B benchmarks above are not transferable to the 35B model.
- opencode sends a small title-generation request alongside the main one; `PARALLEL` controls whether those run concurrently.
- Compare runs by `label`; change one setting at a time.
