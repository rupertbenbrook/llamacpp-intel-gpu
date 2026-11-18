# C#/.NET/Docker coding-agent benchmark

Run from the repository root with the local llama.cpp container healthy. Requires .NET SDK 11, OpenCode V2 and Docker Desktop for the Docker task. The fixture is copied into a disposable, fixed-path workspace; **hidden verification code stays outside** it.

```powershell
./bench/dotnet/run.ps1 -Label 9b-128k -Task pagination
./bench/dotnet/run.ps1 -Label 9b-128k -Task pagination,cancellation,filter,docker -TimeoutMinutes 20
```

| Task | Agent must do | Hidden checks |
|---|---|---|
| `pagination` | Correct 1-based paging in `TicketService` | Boundaries, total count, validation |
| `cancellation` | Pass the caller's cancellation token to repository | Token identity; already-cancelled request |
| `filter` | Add case-insensitive status query across API and service | Service count/page ordering and real HTTP endpoint |
| `docker` | Correct Dockerfile so `/health` is reachable from host | `docker build`, `docker run -p 127.0.0.1:18081:8080`, HTTP response, multi-stage build |

Results append to `bench/dotnet-results.csv` (ignored by Git). Every task starts from the same intentionally flawed fixture. A failing hidden test is a task failure, even if the agent claims success. The script checks that OpenCode exited successfully and reports timeouts separately. Use `-KeepWorkspace` to inspect the agent's modified files and, on failure, the output files whose locations the script prints. Docker containers are cleaned after each attempt; the image `oc-dotnet-bench:verify` may remain in the local image cache.

The first test run on the Qwen3.8 9B at 128k/q8_0 passed pagination (8.5 min) and cancellation (5.0 min), failed filtering due to an invalid `IReadOnlyList<T>.Length` edit (9.5 min), and timed out on Dockerfile repair (12 min). The Docker challenge prompt was then clarified to specify the build context; those results are **not** a controlled comparison with a future run. Small sample sizes are noisy: run three repetitions with cold and warm-cache cases separately before comparing configurations. A 128k allocated context is not itself a 128k-token workload.

## Fair comparisons

- Keep fixture, prompt and verifier unchanged when comparing model settings. Log any prompt changes with the results.
- Allow one model run at a time; Docker builds can compete with inference for system memory.
- Keep `WorkDirectory` fixed between runs for comparable prompt caching, but reset it between tasks (the runner does this).
- Do not trust a response claiming tests pass: the verifier and HTTP checks decide.
- Do not run this on an untrusted model endpoint: an agent that can invoke Docker and shell commands has broad local privileges.
