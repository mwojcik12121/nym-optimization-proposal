#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

NYM_REPO=""
NYX_REPO=""
WASMVM_REPO=""
BUILD_JOBS=""
stage=""

usage() {
  printf 'Usage: ./build.sh --nym NAME --nyx NAME --wasmvm NAME --build-jobs N\n'
}

build_die() {
  printf '[build] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${stage}" ]]; then
    rm -rf "${stage}"
  fi
}

validate_repo_name() {
  local name="${1:-}"
  local option="${2:-repository}"

  [[ -n "${name}" ]] || build_die "${option} requires a repository name"
  [[ "${name}" != "." && "${name}" != ".." ]] || build_die "${option} must name a directory below src/"
  [[ "${name}" != */* && "${name}" != *\\* ]] || build_die "${option} accepts a repository name, not a path"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || build_die "${option} contains unsupported characters: ${name}"
}

parse_arguments() {
  while (( $# > 0 )); do
    case "$1" in
      --nym)
        (( $# >= 2 )) || build_die '--nym requires a repository name'
        NYM_REPO="$2"
        shift 2
        ;;
      --nyx)
        (( $# >= 2 )) || build_die '--nyx requires a repository name'
        NYX_REPO="$2"
        shift 2
        ;;
      --wasmvm)
        (( $# >= 2 )) || build_die '--wasmvm requires a repository name'
        WASMVM_REPO="$2"
        shift 2
        ;;
      --build-jobs)
        (( $# >= 2 )) || build_die '--build-jobs requires a positive integer'
        BUILD_JOBS="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        build_die "unknown option: $1"
        ;;
    esac
  done

  validate_repo_name "${NYM_REPO}" '--nym'
  validate_repo_name "${NYX_REPO}" '--nyx'
  validate_repo_name "${WASMVM_REPO}" '--wasmvm'
  [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || build_die '--build-jobs must be a positive integer'
}

require_repo() {
  local name="${1:?repository name required}"
  local label="${2:?repository label required}"
  local directory="${ROOT}/src/${name}"

  [[ -d "${directory}" ]] || build_die "${label} repository not found: src/${name}"
}

require_repo_file() {
  local directory="${1:?repository directory required}"
  local file="${2:?relative file required}"
  local label="${3:?repository label required}"

  [[ -f "${directory}/${file}" ]] || build_die "${label} repository is missing ${file}: ${directory}/${file}"
}

check_source_layouts() {
  local nym_dir="${ROOT}/src/${NYM_REPO}"
  local nyx_dir="${ROOT}/src/${NYX_REPO}"
  local wasmvm_dir="${ROOT}/src/${WASMVM_REPO}"

  require_repo_file "${nym_dir}" Cargo.toml 'Nym'
  require_repo_file "${nyx_dir}" go.mod 'Nyx'
  require_repo_file "${nyx_dir}" Makefile 'Nyx'
  require_repo_file "${wasmvm_dir}" go.mod 'wasmvm'
  require_repo_file "${wasmvm_dir}" Makefile 'wasmvm'
}

source_revision() {
  local directory="${1:?repository directory required}"
  local revision="working-tree"
  local dirty=""

  if command -v git >/dev/null 2>&1 && git -C "${directory}" rev-parse --verify HEAD >/dev/null 2>&1; then
    revision="$(git -C "${directory}" rev-parse --short=12 HEAD)"
    if [[ -n "$(git -C "${directory}" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
      dirty="+dirty"
    fi
  fi

  printf '%s%s\n' "${revision}" "${dirty}"
}

source_version() {
  local directory="${1:?repository directory required}"
  local fallback="${2:?fallback version required}"
  local version="${fallback}"

  if command -v git >/dev/null 2>&1 && git -C "${directory}" describe --tags --always --dirty >/dev/null 2>&1; then
    version="$(git -C "${directory}" describe --tags --always --dirty)"
  fi

  printf '%s\n' "${version}" | LC_ALL=C tr -c 'A-Za-z0-9._+\n-' '-'
}

print_resource_guidance() {
  local free_kib
  local free_gib

  free_kib="$(df -Pk "${ROOT}" | awk 'NR==2 {print $4}')"
  free_gib=$((free_kib / 1024 / 1024))

  printf '[build] host free space visible here: approximately %s GiB\n' "${free_gib}" >&2
  printf '[build] practical minimum: 2 threads, 6 GiB RAM plus swap, 30 GiB free; recommended slow-machine profile: --build-jobs 1, 8 GiB RAM, 40 GiB free\n' >&2

  if (( free_gib < 20 )); then
    printf '[build] WARNING: less than 20 GiB is visible; Docker build cache may exhaust available space\n' >&2
  fi
}

parse_arguments "$@"
require_repo "${NYM_REPO}" 'Nym'
require_repo "${NYX_REPO}" 'Nyx'
require_repo "${WASMVM_REPO}" 'wasmvm'
check_source_layouts

command -v docker >/dev/null 2>&1 || build_die 'docker is required'
docker info >/dev/null 2>&1 || build_die 'Docker daemon is not reachable'
docker buildx version >/dev/null 2>&1 || build_die 'docker buildx is required'

WASMVM_BUILD_TARGET="${WASMVM_BUILD_TARGET:-auto}"
[[ "${WASMVM_BUILD_TARGET}" == auto || "${WASMVM_BUILD_TARGET}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || build_die 'WASMVM_BUILD_TARGET must be auto or a Make target name'

NYM_RUST_IMAGE="${NYM_RUST_IMAGE:-rust:1.89.0-bookworm}"
CONTRACT_RUST_IMAGE="${CONTRACT_RUST_IMAGE:-rust:1.86.0-bookworm}"
WASMVM_RUST_IMAGE="${WASMVM_RUST_IMAGE:-rust:1.88.0-bookworm}"
NYXD_GO_IMAGE="${NYXD_GO_IMAGE:-golang:1.23.11-bookworm}"

NYM_SOURCE_DIR="${ROOT}/src/${NYM_REPO}"
NYXD_SOURCE_DIR="${ROOT}/src/${NYX_REPO}"
WASMVM_SOURCE_DIR="${ROOT}/src/${WASMVM_REPO}"

NYM_SOURCE_REVISION="$(source_revision "${NYM_SOURCE_DIR}")"
NYXD_SOURCE_REVISION="$(source_revision "${NYXD_SOURCE_DIR}")"
WASMVM_SOURCE_REVISION="$(source_revision "${WASMVM_SOURCE_DIR}")"
NYXD_SOURCE_VERSION="${NYXD_SOURCE_VERSION:-$(source_version "${NYXD_SOURCE_DIR}" local-source)}"

stage="$(mktemp -d "${ROOT}/.build-output.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${ROOT}/bin"

print_resource_guidance
printf '[build] repositories: nym=src/%s nyx=src/%s wasmvm=src/%s\n' "${NYM_REPO}" "${NYX_REPO}" "${WASMVM_REPO}" >&2
printf '[build] jobs=%s nym-rust=%s contract-rust=%s wasmvm-rust=%s wasmvm-target=%s go=%s\n' "${BUILD_JOBS}" "${NYM_RUST_IMAGE}" "${CONTRACT_RUST_IMAGE}" "${WASMVM_RUST_IMAGE}" "${WASMVM_BUILD_TARGET}" "${NYXD_GO_IMAGE}" >&2
printf '[build] compiling Nym binaries plus mixnet and node-families contracts from selected local repositories\n' >&2

docker buildx build \
  --platform linux/amd64 \
  --target export \
  --output "type=local,dest=${stage}" \
  --build-context "nym-src=${NYM_SOURCE_DIR}" \
  --build-context "nyx-src=${NYXD_SOURCE_DIR}" \
  --build-context "wasmvm-src=${WASMVM_SOURCE_DIR}" \
  --build-arg "BUILD_JOBS=${BUILD_JOBS}" \
  --build-arg "NYM_REPO=${NYM_REPO}" \
  --build-arg "NYX_REPO=${NYX_REPO}" \
  --build-arg "WASMVM_REPO=${WASMVM_REPO}" \
  --build-arg "NYM_RUST_IMAGE=${NYM_RUST_IMAGE}" \
  --build-arg "CONTRACT_RUST_IMAGE=${CONTRACT_RUST_IMAGE}" \
  --build-arg "WASMVM_RUST_IMAGE=${WASMVM_RUST_IMAGE}" \
  --build-arg "WASMVM_BUILD_TARGET=${WASMVM_BUILD_TARGET}" \
  --build-arg "NYXD_GO_IMAGE=${NYXD_GO_IMAGE}" \
  --build-arg "NYM_SOURCE_REVISION=${NYM_SOURCE_REVISION}" \
  --build-arg "NYXD_SOURCE_REVISION=${NYXD_SOURCE_REVISION}" \
  --build-arg "NYXD_SOURCE_VERSION=${NYXD_SOURCE_VERSION}" \
  --build-arg "WASMVM_SOURCE_REVISION=${WASMVM_SOURCE_REVISION}" \
  -f docker/Dockerfile.builder \
  .

required_exports=(
  "bin/nyxd"
  "bin/nym-node"
  "bin/nym-socks5-client"
  "bin/nym-base58"
  "lib/libwasmvm.x86_64.so"
  "contracts/mixnet_contract.env"
  "contracts/mixnet_contract_env_names"
  "contracts/mixnet_instantiate_template.json"
  "contracts/node_families_instantiate_template.json"
  "contracts/mixnet_contract.wasm"
  "contracts/node_families_contract.wasm"
  "metadata/build.env"
)

for file in "${required_exports[@]}"; do
  [[ -s "${stage}/${file}" ]] || build_die "builder did not export ${file}"
done

printf '%s\n' \
  'MIXNET_CONTRACT_INCLUDED=true' \
  'NODE_FAMILIES_CONTRACT_INCLUDED=true' \
  'COSMWASM_ARTIFACT_PROFILE=stripped-signext-lowered-Os' \
  >> "${stage}/metadata/build.env"

grep -Fqx 'FORMAT=nym-binaries' "${stage}/metadata/build.env" || build_die 'builder emitted an unexpected handoff format'
grep -Fqx 'TESTER_LAYOUT_API=2' "${stage}/metadata/build.env" || build_die 'builder emitted an incompatible tester layout API'

printf '[build] preparing the runtime dependency image for the offline test host\n' >&2

docker build \
  --platform linux/amd64 \
  --pull=false \
  -f docker/Dockerfile.runtime-base \
  -t nym-test/runtime-base:v2 \
  .

docker save nym-test/runtime-base:v2 -o "${stage}/runtime-base-image.tar"

artifact="${ROOT}/bin/nym-binaries.tar.gz"
rm -f "${artifact}"
tar -C "${stage}" -czf "${artifact}" .

printf '[build] handoff artifact: %s\n' "${artifact}" >&2
printf '[build] copy the artifact to the testing machine\n' >&2
