#!/bin/sh
set -e

# MODEL_FILE (a path inside the models volume) overrides the Hugging Face download,
# e.g. for locally re-quantised variants.
if [ -n "${MODEL_FILE}" ]; then
  set -- -m "${MODEL_FILE}"
else
  : "${HF_MODEL:?HF_MODEL must be set (e.g. owner/repo:Q4_K_M)}"
  set -- -hf "${HF_MODEL}"
fi

# Leave GPU layers / CPU-expert split unset unless given, so llama.cpp's --fit
# can size them automatically to the iGPU's free shared memory.
if [ -n "${GPU_LAYERS}" ] && [ "${GPU_LAYERS}" != "auto" ]; then
  set -- "$@" --n-gpu-layers "${GPU_LAYERS}"
fi
if [ -n "${N_CPU_MOE}" ]; then
  set -- "$@" --n-cpu-moe "${N_CPU_MOE}"
fi
echo "Available SYCL devices:"
sycl-ls 2>/dev/null || true

# -hf downloads the GGUF from Hugging Face into $LLAMA_CACHE on first start
# and reuses the cached copy afterwards.
exec /app/llama-server \
  "$@" \
  --alias "${MODEL_ALIAS:-local-model}" \
  --host 0.0.0.0 --port 8080 \
  --ctx-size "${CTX_SIZE:-32768}" \
  --batch-size "${BATCH_SIZE:-2048}" \
  --ubatch-size "${UBATCH_SIZE:-512}" \
  --flash-attn "${FLASH_ATTN:-auto}" \
  --cache-type-k "${CACHE_TYPE_K:-f16}" \
  --cache-type-v "${CACHE_TYPE_V:-f16}" \
  --parallel "${PARALLEL:-1}" \
  --cache-reuse "${CACHE_REUSE:-0}" \
  --cache-ram "${CACHE_RAM:-0}" \
  --threads "${THREADS:--1}" \
  --reasoning-budget "${REASONING_BUDGET:--1}" \
  --metrics \
  --jinja \
  ${EXTRA_ARGS}
