# llama.cpp on an Intel integrated GPU

[![Build and publish Intel SYCL image](https://github.com/rupertbenbrook/llamacpp-intel-gpu/actions/workflows/image.yml/badge.svg)](https://github.com/rupertbenbrook/llamacpp-intel-gpu/actions/workflows/image.yml)

A Docker Compose setup for an OpenAI-compatible llama.cpp server on an Intel GPU, built with SYCL ahead-of-time for **Arrow Lake-S (`arl-s`)**. The default model is [empero-ai/Qwen3.8-9B-Distill-GGUF](https://huggingface.co/empero-ai/Qwen3.8-9B-Distill-GGUF), using its `Q4_K_M` quantisation. **No model weights are in this repository or the container image.** llama.cpp downloads the selected GGUF on first start and keeps it in a named Docker volume.

This was tested on a Core Ultra 7 265 (`Intel(R) Graphics [0x7d67]`) with Windows, Docker Desktop and WSL2. An upstream prebuilt Intel llama.cpp image could see this GPU, but failed at runtime on a BF16 kernel; an ahead-of-time build targeting `arl-s` with XMX disabled worked. Other Intel GPUs may require different build arguments and have not been tested.

## Requirements

- Windows 11, current Intel graphics driver, WSL2 and Docker Desktop using Linux containers. A `/dev/dxg` GPU device and `/usr/lib/wsl/lib` libraries must be available inside Docker's Linux environment.
- Around 6 GB of free disk space for the 9B Q4_K_M model, plus image/build-cache space if compiling locally.
- The container listens on `127.0.0.1:8080` **on the host**. It has no authentication; do not expose it to the network without adding your own protection.

### Start using a GHCR image (after its first successful CI build)

```powershell
git clone https://github.com/rupertbenbrook/llamacpp-intel-gpu.git
cd llamacpp-intel-gpu
Copy-Item .env.example .env
# Uses the published arl-s build; does not compile llama.cpp on your machine
docker compose -f compose.yml -f compose.ghcr.yml up -d
```

Or build from source locally (the first build can take several minutes):

```powershell
docker compose up -d --build
```

Follow the startup/download log, then check health and available models:

```powershell
docker compose logs -f llamacpp
Invoke-RestMethod http://127.0.0.1:8080/health
Invoke-RestMethod http://127.0.0.1:8080/v1/models
```

The startup log should list a `level_zero:gpu` Intel device. Initial startup downloads the GGUF; later restarts reuse the `models` volume. `docker compose down` **keeps** that volume; `docker compose down -v` deletes it and all cached models. On native Linux, change the device to `/dev/dri` and remove the WSL2 library mount in `compose.yml`.

### Use from OpenCode

The provided `opencode.json` registers a local provider. From the directory containing this file, choose `llamacpp/qwen3.8-9b` in OpenCode, or run:

```powershell
opencode run --standalone -m llamacpp/qwen3.8-9b "Read README.md and summarise the prerequisites."
```

For other projects, copy the `providers.llamacpp` entry into your **global** `~/.config/opencode/opencode.json` (on Windows, `%USERPROFILE%\.config\opencode\opencode.json`), or add it to that project's config. Keep the configured model ID in sync with `MODEL_ALIAS`. Only one model is loaded at a time, even if OpenCode lists several IDs; choosing one that does not match the active server alias will not switch models. If you increase `CTX_SIZE`, update the matching `limit.context` in OpenCode too.

### Change model or server settings

Copy `.env.example` to `.env` and change `HF_MODEL`, `MODEL_ALIAS` and `CTX_SIZE` there. The included OpenCode config advertises 128k for the 9B model; update it if you change the context. Compose's other tunables have defaults in `compose.yml` and can be overridden in `.env` as well. Apply changes with `docker compose up -d` (or include both `-f` flags when using the GHCR image). For private/gated Hugging Face models, pass `HF_TOKEN` to the container securely; don't commit your token.

To serve an existing GGUF from the `models` volume, set `MODEL_FILE=/models/path/to/file.gguf`; it overrides the Hugging Face model. The selected settings are Q4_K_M, `UBATCH_SIZE=1024`, `PARALLEL=1`, `CACHE_RAM=8192`, `CACHE_TYPE_K/V=q8_0`, 128k context and reasoning enabled (`REASONING_BUDGET=-1`). In two .NET coding-agent runs, reasoning enabled passed 8/8 tasks; setting `REASONING_BUDGET=0` passed 7/8 and produced a costly API-breaking failure. Two server slots passed only 2/4 in the tested suite. Keep the default for coding work; see the [benchmark findings](bench/README.md) for timings and limitations.

### Context and memory

The 9B model defaults to a **128k-token context** with `q8_0` KV cache on this machine. At 128k it completed a two-turn server benchmark and two .NET/Docker coding-agent suites with reasoning enabled (8/8 hidden checks passed). An ~8k-token prompt took ~88–90 s to process on a cold cache and subsequent turns reused the prefix. This does **not** verify a fully filled 128k-token prompt: performance and memory use can change as the context fills. Set `CTX_SIZE=65536` or `32768` if you need more memory headroom, and update the matching `limit.context` in `opencode.json`. Docker's WSL2 VM and the integrated GPU share host RAM. The 35B-A3B MoE experiments were substantially slower and are not recommended; see [`bench/README.md`](bench/README.md).

## Images and CI

[GitHub Actions](.github/workflows/image.yml) builds an `linux/amd64` image every Monday, on pushes to `main`, on `v*` tags and on manual dispatch. Pull requests build without publishing. Successful builds publish to `ghcr.io/rupertbenbrook/llamacpp-intel-gpu` with tags:

- `latest-arl-s` — latest main/weekly build; mutable
- `weekly-arl-s` — latest scheduled build; mutable
- `sha-<commit>-arl-s` — source-repository commit for the image
- `v<version>-arl-s` — release tag builds

The Dockerfile uses upstream llama.cpp `master` by default (so the weekly build can pick up upstream changes); for a repeatable build, set the `LLAMACPP_REF` Docker build arg to a tag or commit and pin `BASE_IMAGE` in the Dockerfile to a digest. The tag's source-repository SHA does **not** identify an upstream llama.cpp commit. CI does not have an Intel GPU: it validates that the image builds, but cannot guarantee GPU runtime behaviour or model quality. Check the Actions status and GHCR package visibility before relying on a newly published image.

## Benchmarks

[`bench/README.md`](bench/README.md) documents the tuning history. [`bench/dotnet/README.md`](bench/dotnet/README.md) adds isolated C#/.NET/Docker coding-agent challenges with hidden verification. Bench result CSVs and GGUFs are local only and intentionally excluded from Git. The 9B setup was tested via `/v1/chat/completions` and real OpenCode tool-use runs on the specified machine.

## License

Container build scripts and configuration in this repository are under the MIT license. llama.cpp, Intel components and Hugging Face models retain their own licenses and distribution terms; the repository and GHCR image do not bundle model weights.
