ARG NYM_RUST_IMAGE=rust:1.89.0-bookworm
ARG CONTRACT_RUST_IMAGE=rust:1.86.0-bookworm
ARG WASMVM_RUST_IMAGE=rust:1.88.0-bookworm
ARG NYXD_GO_IMAGE=golang:1.23.11-bookworm
ARG BINARYEN_VERSION=114
ARG BUILD_JOBS=1

FROM ${WASMVM_RUST_IMAGE} AS wasmvm-builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BUILD_JOBS
ARG WASMVM_BUILD_TARGET=auto
ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=0 \
    CARGO_BUILD_JOBS=${BUILD_JOBS}
RUN apt-get update && apt-get install -y --no-install-recommends \
      binutils build-essential ca-certificates clang git libclang-dev make pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/wasmvm
COPY --from=wasmvm-src . ./
COPY scripts/wasmvm-source.sh /usr/local/lib/nym/wasmvm-source.sh
RUN set -eux; \
    rustc --version; \
    . /usr/local/lib/nym/wasmvm-source.sh; \
    if [[ "${WASMVM_BUILD_TARGET}" == auto ]]; then \
      WASMVM_SELECTED_TARGET="$(wasmvm_build_target /src/wasmvm/Makefile)" || { \
        echo 'ERROR: wasmvm Makefile has neither build-libwasmvm nor build-rust target; set WASMVM_BUILD_TARGET to a valid target if this fork uses another name' >&2; \
        exit 1; \
      }; \
    else \
      wasmvm_make_target_exists /src/wasmvm/Makefile "${WASMVM_BUILD_TARGET}" || { \
        echo "ERROR: wasmvm Makefile does not define requested target ${WASMVM_BUILD_TARGET}" >&2; \
        exit 1; \
      }; \
      WASMVM_SELECTED_TARGET="${WASMVM_BUILD_TARGET}"; \
    fi; \
    echo "using wasmvm Makefile target: ${WASMVM_SELECTED_TARGET}"; \
    make -j "${BUILD_JOBS}" "${WASMVM_SELECTED_TARGET}"; \
    wasmvm_normalize_outputs /src/wasmvm; \
    test -s internal/api/libwasmvm.x86_64.so; \
    test -s internal/api/bindings.h; \
    if nm -D internal/api/libwasmvm.x86_64.so | grep -Eq '[[:space:]]U[[:space:]]+__rust_probestack$'; then \
      echo 'ERROR: libwasmvm contains unresolved __rust_probestack; keep wasmvm on Rust 1.88 or update its Wasmer dependency' >&2; \
      exit 1; \
    fi

FROM ${NYXD_GO_IMAGE} AS nyxd-builder
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG BUILD_JOBS
ARG NYXD_SOURCE_REVISION=working-tree
ARG NYXD_SOURCE_VERSION=local-source
ENV DEBIAN_FRONTEND=noninteractive \
    GOMAXPROCS=${BUILD_JOBS} \
    GOFLAGS=-p=${BUILD_JOBS}
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash build-essential ca-certificates git make pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/wasmvm
COPY --from=wasmvm-src . ./
COPY --from=wasmvm-builder /src/wasmvm/internal/api/libwasmvm.x86_64.so /src/wasmvm/internal/api/libwasmvm.x86_64.so
COPY --from=wasmvm-builder /src/wasmvm/internal/api/bindings.h /src/wasmvm/internal/api/bindings.h
WORKDIR /src/nyxd
COPY --from=nyx-src . ./
COPY scripts/wasmvm-source.sh /usr/local/lib/nym/wasmvm-source.sh
RUN set -eux; \
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
      rm -rf .git; \
      git init -q; \
      git config user.email source-build@invalid; \
      git config user.name source-build; \
      git add -A; \
      git commit -qm 'local source build'; \
    fi; \
    . /usr/local/lib/nym/wasmvm-source.sh; \
    WASMVM_DECLARED_MODULE="$(go_module_path /src/wasmvm/go.mod)"; \
    NYXD_WASMVM_MODULE="$(nyxd_wasmvm_module /src/nyxd/go.mod)"; \
    test -n "${WASMVM_DECLARED_MODULE}"; \
    test -n "${NYXD_WASMVM_MODULE}"; \
    if [[ "${WASMVM_DECLARED_MODULE}" != "${NYXD_WASMVM_MODULE}" ]]; then \
      echo "adapting local wasmvm module ${WASMVM_DECLARED_MODULE} -> ${NYXD_WASMVM_MODULE}"; \
      adapt_wasmvm_module /src/wasmvm "${WASMVM_DECLARED_MODULE}" "${NYXD_WASMVM_MODULE}"; \
    fi; \
    go mod edit "-replace=${NYXD_WASMVM_MODULE}=/src/wasmvm"; \
    make LEDGER_ENABLED=false VERSION="${NYXD_SOURCE_VERSION}" COMMIT="${NYXD_SOURCE_REVISION}" build; \
    test -x build/nyxd; \
    LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd version; \
    LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd rollback --help >/dev/null; \
    LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd tx wasm instantiate2 --help >/dev/null; \
    LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd query wasm build-address --help >/dev/null; \
    LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd start --help | grep -Fq -- '--wasm.skip-wasmvm-version-check' || \
      LD_LIBRARY_PATH=/src/wasmvm/internal/api build/nyxd start --help | grep -Fq -- '--wasm.skip_wasmvm_version_check'

FROM ${NYM_RUST_IMAGE} AS nym-builder
ARG BUILD_JOBS
ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=0 \
    CARGO_BUILD_JOBS=${BUILD_JOBS}
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates clang cmake git libclang-dev \
      libdbus-1-dev libssl-dev libsqlite3-dev libudev-dev make \
      perl pkg-config protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/nym
COPY --from=nym-src . ./
RUN set -eux; \
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
      rm -rf .git; \
      git init -q; \
      git config user.email source-build@invalid; \
      git config user.name source-build; \
      git add -A; \
      git commit -qm 'local source build'; \
    fi; \
    rustc --version; \
    cargo build --release --locked -j "${BUILD_JOBS}" -p nym-node -p nym-socks5-client; \
    test -x target/release/nym-node; \
    test -x target/release/nym-socks5-client; \
    target/release/nym-node --version; \
    target/release/nym-socks5-client --version; \
    INIT_HELP="$(target/release/nym-socks5-client init --help 2>&1)"; \
    printf '%s\n' "${INIT_HELP}" | grep -Fq -- '--provider'; \
    printf '%s\n' "${INIT_HELP}" | grep -Fq -- '--port'; \
    printf '%s\n' "${INIT_HELP}" | grep -Eq -- '--gateway([ =]|$)|--gateway-id([ =]|$)'; \
    printf '%s\n' "${INIT_HELP}" | grep -Eq -- '--nym-apis([ =]|$)|--nym-api-urls([ =]|$)'; \
    target/release/nym-socks5-client run --help >/dev/null

FROM ${CONTRACT_RUST_IMAGE} AS nym-contract-builder
ARG BUILD_JOBS
ARG BINARYEN_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=0 \
    CARGO_BUILD_JOBS=${BUILD_JOBS}
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    archive="binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz"; \
    release="https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}"; \
    cd /tmp; \
    curl -fsSLo "${archive}" "${release}/${archive}"; \
    curl -fsSLo "${archive}.sha256" "${release}/${archive}.sha256"; \
    sha256sum -c "${archive}.sha256"; \
    tar -xzf "${archive}" -C /opt; \
    install -m 0755 "/opt/binaryen-version_${BINARYEN_VERSION}/bin/wasm-opt" /usr/local/bin/wasm-opt; \
    rm -rf "${archive}" "${archive}.sha256" "/opt/binaryen-version_${BINARYEN_VERSION}"; \
    wasm-opt --version; \
    wasm-opt --help | grep -Fq -- '--signext-lowering'
WORKDIR /src/nym
COPY scripts/mixnet-contract.sh /usr/local/bin/mixnet-contract.sh
COPY --from=nym-src . ./
RUN set -eux; \
    rustc --version | grep -Fq '1.86.0'; \
    bash /usr/local/bin/mixnet-contract.sh \
      /src/nym \
      /out/contracts \
      "${BUILD_JOBS}"

FROM debian:bookworm-slim AS helper-builder
RUN apt-get update && apt-get install -y --no-install-recommends g++ \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/base58.cpp /tmp/base58.cpp
RUN g++ -std=c++17 -O2 -Wall -Wextra -Werror -pedantic \
      /tmp/base58.cpp -o /usr/local/bin/nym-base58

FROM debian:bookworm-slim AS metadata-builder
ARG BINARYEN_VERSION
ARG CONTRACT_RUST_IMAGE
ARG NYM_REPO=unknown
ARG NYX_REPO=unknown
ARG WASMVM_REPO=unknown
ARG NYM_SOURCE_REVISION=working-tree
ARG NYXD_SOURCE_REVISION=working-tree
ARG NYXD_SOURCE_VERSION=local-source
ARG WASMVM_SOURCE_REVISION=working-tree
ARG NYM_RUST_IMAGE
ARG WASMVM_RUST_IMAGE
ARG NYXD_GO_IMAGE
ARG BUILD_JOBS
RUN mkdir -p /out/metadata && printf '%s\n' \
      'FORMAT=nym-binaries' \
      'ARCH=amd64' \
      'TESTER_LAYOUT_API=2' \
      'NYXD_REQUIRED_START_FLAG=--wasm.skip_wasmvm_version_check' \
      'NYM_TRAFFIC_CLIENT=nym-socks5-client' \
      "NYM_REPO=${NYM_REPO}" \
      "NYX_REPO=${NYX_REPO}" \
      "WASMVM_REPO=${WASMVM_REPO}" \
      "NYM_SOURCE_REVISION=${NYM_SOURCE_REVISION}" \
      "NYXD_SOURCE_REVISION=${NYXD_SOURCE_REVISION}" \
      "NYXD_SOURCE_VERSION=${NYXD_SOURCE_VERSION}" \
      "WASMVM_SOURCE_REVISION=${WASMVM_SOURCE_REVISION}" \
      "NYM_RUST_IMAGE=${NYM_RUST_IMAGE}" \
      "CONTRACT_RUST_IMAGE=${CONTRACT_RUST_IMAGE}" \
      "WASMVM_RUST_IMAGE=${WASMVM_RUST_IMAGE}" \
      "NYXD_GO_IMAGE=${NYXD_GO_IMAGE}" \
      "BINARYEN_VERSION=${BINARYEN_VERSION}" \
      "BUILD_JOBS=${BUILD_JOBS}" \
      > /out/metadata/build.env

FROM scratch AS export
COPY --from=nyxd-builder /src/nyxd/build/nyxd /bin/nyxd
COPY --from=nym-builder /src/nym/target/release/nym-node /bin/nym-node
COPY --from=nym-builder /src/nym/target/release/nym-socks5-client /bin/nym-socks5-client
COPY --from=helper-builder /usr/local/bin/nym-base58 /bin/nym-base58
COPY --from=wasmvm-builder /src/wasmvm/internal/api/libwasmvm.x86_64.so /lib/libwasmvm.x86_64.so
COPY --from=metadata-builder /out/metadata/build.env /metadata/build.env
COPY --from=nym-contract-builder /out/contracts/ /contracts/
