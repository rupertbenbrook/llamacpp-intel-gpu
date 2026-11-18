# Build llama.cpp with SYCL (Intel GPU) support, compiled ahead-of-time for the
# target GPU. The prebuilt image JIT-compiles kernels at runtime, which fails on
# some Intel iGPUs (e.g. Arrow/Meteor Lake) with "bf conversion instruction not supported".
# The official Intel image already ships the oneAPI compiler, ocloc and GPU runtime,
# so it is used as the base for both stages.
ARG BASE_IMAGE=ghcr.io/ggml-org/llama.cpp:server-intel

FROM ${BASE_IMAGE} AS build
# Device architecture for ahead-of-time compilation (see `ocloc compile --help`)
ARG SYCL_DEVICE_ARCH=arl-s
# XMX (DPAS) matrix engines exist only on Arc dGPUs / Xe2+; Xe-LPG iGPUs (MTL/ARL) lack them
ARG SYCL_SUPPORT_XMX=OFF
ARG LLAMACPP_REF=master
RUN apt-get update && apt-get install -y --no-install-recommends git cmake ninja-build libssl-dev \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${LLAMACPP_REF} https://github.com/ggml-org/llama.cpp /src
WORKDIR /src
RUN cmake -B build -G Ninja \
      -DGGML_SYCL=ON -DGGML_SYCL_F16=ON \
      -DGGML_SYCL_DEVICE_ARCH=${SYCL_DEVICE_ARCH} \
      -DGGML_SYCL_SUPPORT_XMX=${SYCL_SUPPORT_XMX} \
      -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
      -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --target llama-server llama-bench llama-quantize -j \
    && mkdir -p /out && cp build/bin/llama-server build/bin/llama-bench build/bin/llama-quantize /out/ \
    && find build -name '*.so*' -exec cp -P {} /out/ \;

FROM ${BASE_IMAGE}
RUN rm -rf /app/*.so* /app/llama*
COPY --from=build /out/ /app/
ENV LD_LIBRARY_PATH=/app:/usr/lib/wsl/lib:${LD_LIBRARY_PATH}

COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
