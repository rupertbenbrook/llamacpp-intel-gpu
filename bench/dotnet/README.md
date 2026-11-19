# C#/.NET/Docker coding-agent benchmark

Run from the repository root with the local llama.cpp container healthy. Requires .NET SDK 11, OpenCode V2 and Docker Desktop for the Docker task. The fixture is copied into a disposable, fixed-path workspace; **hidden verification code stays outside** it.

```powershell
./bench/dotnet/run.ps1 -Label 9b-128k -Task pagination
./bench/dotnet/run.ps1 -Label 9b-128k -Task pagination,cancellation,filter,docker -TimeoutMinutes 30
# Add -NoWarmup to measure cold-start behavior instead of warmed prompt-cache behavior
```

The runner copies the fixture contents to a fixed temporary workspace, checks its layout, and removes copied `bin/` and `obj/` directories. It polls both OpenCode output files every 10 s; OpenCode writes tool activity and request retries to stderr, while stdout is generally empty until the final reply. It prints elapsed time and the latest stderr line when output changes, plus a heartbeat every minute of inactivity. A task that exceeds `-TimeoutMinutes` is killed as a process tree and recorded with `timeout=True`. To retain live progress, redirect the run to a file under the ignored `bench/dotnet-agent-log/` directory, for example with `Tee-Object`.

| Task | Agent must do | Hidden checks |
|---|---|---|
| `pagination` | Correct 1-based paging in `TicketService` | Boundaries, total count, validation |
| `cancellation` | Pass the caller's cancellation token to repository | Token identity; already-cancelled request |
| `filter` | Add case-insensitive status query across API and service | Service count/page ordering and real HTTP endpoint |
| `docker` | Correct Dockerfile so `/health` is reachable from host | `docker build`, `docker run -p 127.0.0.1:18081:8080`, HTTP response, multi-stage build |

Results append to `bench/dotnet-results.csv` (ignored by Git). Every task starts from the same intentionally flawed fixture. A failing hidden test is a task failure, even if the agent claims success. The runner checks that OpenCode exited successfully and reports timeouts separately. For the `docker` task the agent only edits the Dockerfile and builds the solution; the runner builds and runs the image itself, so the agent cannot get stuck in Docker name/build loops. Use `-KeepWorkspace` to inspect the agent's modified files and, on failure, the output files whose locations the script prints. Docker containers are cleaned after each attempt; the image `oc-dotnet-bench:verify` may remain in the local image cache.

## Measured results

All results below used Qwen3.8 9B Q4_K_M, 128k context, q8_0 K/V, `UBATCH_SIZE=1024`, warmup enabled, sequential tasks and a 30-minute per-task timeout. Times include external verification, not the warmup. Later rows used the corrected workspace layout, fixed prompts and hidden checks; the initial reference tasks were executed separately, with Docker rerun after correcting its workspace layout. They are useful reference observations, not a strictly identical full-suite replicate.

| Setting and run | Pagination | Cancellation | Filter | Docker | Passed | Total |
|---|---:|---:|---:|---:|---:|---:|
| Reasoning `-1`, `PARALLEL=1`, initial reference | 243.7 s | 233.6 s | 453.3 s | 118.4 s | **4/4** | 17.5 min |
| Reasoning `-1`, `PARALLEL=1`, repeat | 261.8 s | 151.6 s | 263.0 s | 133.0 s | **4/4** | 13.5 min |
| Reasoning `0`, `PARALLEL=1`, first run | 153.6 s | 111.8 s | 533.5 s | 93.4 s | **4/4** | 14.9 min |
| Reasoning `0`, `PARALLEL=1`, repeat | 1343.8 s (fail: public return type changed) | 111.7 s | 283.2 s | 83.2 s | **3/4** | 30.4 min |
| Reasoning `0`, `PARALLEL=2` | 452.4 s (fail: paging) | 111.6 s | 1802.9 s (timeout) | 93.2 s | **2/4** | 41.0 min |

The initial failures before the reference used different prompts or a broken workspace copy and are **not** comparable. A 15-minute suite in the presence of long OpenCode requests timed out on all four tasks and is not a model-quality baseline. These are small, noisy samples: reasoning enabled with one slot passed **8/8** versus **7/8** with reasoning disabled and **2/4** with two slots. Keep reasoning enabled and `PARALLEL=1` by default; do not infer a reliable speed advantage from one quick run. A 128k allocated context is not itself a 128k-token workload.

## Fair comparisons

- Keep fixture, prompt and verifier unchanged when comparing model settings. Log any prompt changes with the results.
- Allow one model run at a time; Docker builds can compete with inference for system memory.
- Keep `WorkDirectory` fixed between runs for comparable prompt caching, but reset it between tasks (the runner does this).
- Do not trust a response claiming tests pass: the verifier and HTTP checks decide.
- Do not run this on an untrusted model endpoint: an agent that can invoke Docker and shell commands has broad local privileges.
