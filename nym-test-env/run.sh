#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

source "${ROOT}/controls/info.sh"

scenario="${1:-}"
project=""
logs_pid=""
run_datetime="$(date '+%Y%m%d_%H%M%S')"
logs_dir="${ROOT}/logs"

services=()
container_ids=()
node_log_pids=()
compose=()

runner_die() {
  local status="${1}"
  shift
  nym_test_log ERR runner "$*"
  exit "${status}"
}

build_images() {
  local file
  local number

  command -v docker >/dev/null 2>&1 \
    || nym_abort images 'docker is required'
  docker info >/dev/null 2>&1 \
    || nym_abort images 'Docker daemon is not reachable'
  docker compose version >/dev/null 2>&1 \
    || nym_abort images 'Docker Compose v2 is required'
  docker image inspect nym-test/runtime-base:v2 >/dev/null 2>&1 \
    || nym_abort images 'nym-test/runtime-base:v2 is missing'

  for file in \
    bin/bin/nyxd \
    bin/bin/nym-node \
    bin/bin/nym-socks5-client \
    bin/bin/nym-base58 \
    bin/lib/libwasmvm.x86_64.so \
    bin/contracts/mixnet_contract.wasm \
    bin/contracts/mixnet_instantiate_template.json \
    bin/contracts/mixnet_contract_env_names \
    bin/contracts/mixnet_contract.env \
    bin/contracts/node_families_contract.wasm \
    bin/contracts/node_families_instantiate_template.json \
    bin/metadata/build.env; do
    [[ -s "${file}" ]] \
      || nym_abort images "missing imported artifact: ${file}"
  done

  grep -Eq '^FORMAT=(nym-binaries|nym-test-build-output-v2)$' bin/metadata/build.env \
    || nym_abort images 'imported artifact has the wrong format'
  grep -Fqx 'TESTER_LAYOUT_API=2' bin/metadata/build.env \
    || nym_abort images 'imported artifact is incompatible with tester layout API 2'
  grep -Fqx 'COSMWASM_ARTIFACT_PROFILE=stripped-signext-lowered-Os' bin/metadata/build.env \
    || nym_abort images 'imported contracts are not deployable; rebuild them with the current nym-build-env'

  nym_test_log INF images 'creating Nyxd seed image from imported nyxd, libwasmvm, and mixnet contract; build network disabled'
  docker build \
    --network=none \
    --pull=false \
    -f docker/Dockerfile.nyxd-seed \
    -t nym-test/nyxd-seed:imported \
    .

  nym_test_log INF images 'creating nym-node base image from imported binaries; build network disabled'
  docker build \
    --network=none \
    --pull=false \
    -f docker/Dockerfile.nym-node \
    -t nym-test/nym-node-base:imported \
    .

  nym_test_log INF images 'creating eight distinct node images'
  "${compose[@]}" build --pull=false

  for number in 01 02 03 04 05 06 07 08; do
    docker image inspect "nym-test/node${number}:local" >/dev/null 2>&1 \
      || nym_abort images "final image missing: nym-test/node${number}:local"
  done

  nym_test_log INF images 'all eight runtime images are ready'
}

start_node_log_capture() {
  local index
  local file
  local remote
  local deadline

  mkdir -p "${logs_dir}"

  for index in "${!services[@]}"; do
    file="${logs_dir}/${services[$index]}_scenario${scenario}_${run_datetime}.log"
    remote="/var/lib/nym/logs/${services[$index]}.log"
    : > "${file}"
    deadline=$((SECONDS + 5))
    while docker inspect -f '{{.State.Running}}' "${container_ids[$index]}" 2>/dev/null | grep -qx true; do
      if docker exec "${container_ids[$index]}" test -f "${remote}" >/dev/null 2>&1; then
        docker exec "${container_ids[$index]}" tail -n +1 -F "${remote}" > "${file}" 2>&1 &
        node_log_pids+=("$!")
        break
      fi
      (( SECONDS >= deadline )) && break
      sleep 0.1
    done
  done
}

stop_node_log_capture() {
  local pid
  local deadline

  for pid in "${node_log_pids[@]}"; do
    [[ -n "${pid}" ]] || continue

    deadline=$((SECONDS + 5))

    while kill -0 "${pid}" 2>/dev/null && (( SECONDS < deadline )); do
      sleep 0.1
    done

    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" >/dev/null 2>&1 || true
    fi

    wait "${pid}" >/dev/null 2>&1 || true
  done

  node_log_pids=()
}

save_node_logs() {
  local index
  local file
  local remote
  local temporary

  mkdir -p "${logs_dir}"

  for index in "${!services[@]}"; do
    local cid="${container_ids[$index]:-}"
    file="${logs_dir}/${services[$index]}_scenario${scenario}_${run_datetime}.log"
    remote="/var/lib/nym/logs/${services[$index]}.log"
    temporary="${file}.tmp.$$"

    [[ -n "${cid}" ]] || continue
    rm -f "${temporary}"
    if docker cp "${cid}:${remote}" "${temporary}" >/dev/null 2>&1; then
      mv -f "${temporary}" "${file}"
    else
      rm -f "${temporary}"
      docker logs "${cid}" > "${file}" 2>&1 || true
    fi
  done
}


cleanup() {
  local status=$?

  trap - EXIT INT TERM
  set +e

  if [[ -n "${logs_pid}" ]]; then
    kill "${logs_pid}" >/dev/null 2>&1 || true
    wait "${logs_pid}" >/dev/null 2>&1 || true
    logs_pid=""
  fi

  if (( ${#compose[@]} > 0 )); then
    "${compose[@]}" stop --timeout 10 >/dev/null 2>&1 || true
  fi

  stop_node_log_capture
  save_node_logs

  if (( ${#compose[@]} > 0 )); then
    "${compose[@]}" down \
      --volumes \
      --remove-orphans \
      --timeout 10 \
      >/dev/null 2>&1 || true
  fi

  exit "${status}"
}

containers_running() {
  local index
  local state

  for index in "${!services[@]}"; do
    local cid="${container_ids[$index]:-}"
    [[ -n "${cid}" ]] || continue
    state="$(
      docker inspect \
        -f '{{.State.Running}} {{.State.ExitCode}}' \
        "${cid}" \
        2>/dev/null || true
    )"

    if [[ "${state}" != true\ * ]]; then
      nym_test_log ERR runner \
        "${services[$index]} exited before scenario release (${state:-unavailable})"
      return 1
    fi
  done

  return 0
}

wait_for_marker() {
  local marker="${1}"
  local timeout="${2}"
  local started="${SECONDS}"

  while ! "${compose[@]}" exec -T node01 \
    test -f "${marker}" >/dev/null 2>&1; do

    containers_running || return 1

    if (( SECONDS - started >= timeout )); then
      nym_test_log ERR runner "timeout waiting for ${marker}"
      return 1
    fi

    sleep 0.25
  done

  return 0
}

wait_for_nodes() {
  local timeout="${1}"
  local started="${SECONDS}"
  local service
  local pending

  while true; do
    pending=0

    for service in "${services[@]}"; do
      if ! "${compose[@]}" exec -T node01 \
        test -f "/run/nym-shared/ready/${service}" \
        >/dev/null 2>&1; then
        pending=$((pending + 1))
      fi
    done

    (( pending == 0 )) && return 0

    containers_running || return 1

    if (( SECONDS - started >= timeout )); then
      nym_test_log ERR runner \
        "timeout waiting for ${pending} node(s)"
      return 1
    fi

    sleep 0.25
  done
}

print_initial_chain_logs() {
  local line
  local height
  local last_height=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ committed[[:space:]]+state.*height=([0-9]+) ]]; then
      height="${BASH_REMATCH[1]}"

      if (( height >= 1 && height <= 200 && height > last_height )); then
        printf '%s\n' "${line}"
        last_height="${height}"
      fi
    fi
  done < <(
    "${compose[@]}" logs \
      --no-color \
      --no-log-prefix \
      node01 \
      2>/dev/null || true
  )
}

read_common_height() {
  "${compose[@]}" exec -T node01 \
    jq -r \
      '.synchronized_height // .common_height // .minimum_height // 0' \
      /run/nym-shared/chain-ready.json
}

stream_logs() {
  "${compose[@]}" logs \
    -f \
    --tail 0 \
    --no-color \
    --no-log-prefix \
    "${services[@]}"
}

print_failure_logs() {
  local index
  local state
  local file

  stop_node_log_capture
  save_node_logs

  for index in "${!services[@]}"; do
    state="$(
      docker inspect \
        -f '{{.State.Running}} {{.State.ExitCode}}' \
        "${container_ids[$index]}" \
        2>/dev/null || true
    )"

    if [[ "${state}" != true\ * ]]; then
      file="${logs_dir}/${services[$index]}_scenario${scenario}_${run_datetime}.log"
      nym_test_log ERR runner "${services[$index]} startup/runtime log: ${file}"
      tail -n 160 "${file}" >&2 2>/dev/null || true
    fi
  done
}

wait_for_completion() {
  local index
  local state
  local running
  local code
  local failure=0

  while true; do
    running=0

    for index in "${!services[@]}"; do
      state="$(
        docker inspect \
          -f '{{.State.Running}} {{.State.ExitCode}}' \
          "${container_ids[$index]}" \
          2>/dev/null || true
      )"

      if [[ "${state}" == true\ * ]]; then
        running=$((running + 1))
        continue
      fi

      code="${state##* }"

      if [[ "${code}" =~ ^[0-9]+$ ]] &&
         (( code != 0 )) &&
         (( failure == 0 )); then
        failure="${code}"
        nym_test_log ERR runner \
          "${services[$index]} failed with exit code ${code}"
      fi
    done

    (( failure != 0 )) && return "${failure}"
    (( running == 0 )) && return 0

    sleep 0.25
  done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -n "${scenario}" ]] ||
  runner_die 2 "usage: ./run.sh SCENARIO_NUMBER"

[[ "${scenario}" =~ ^[0-9]+$ ]] ||
  runner_die 2 "scenario must be a non-negative integer"

[[ $# -eq 1 ]] ||
  runner_die 2 "usage: ./run.sh SCENARIO_NUMBER"

shopt -s nullglob
scenario_files=(scenarios/node??_scenario"${scenario}".sh)

(( ${#scenario_files[@]} > 0 )) ||
  runner_die 2 "no scenario ${scenario} files found"

for file in "${scenario_files[@]}"; do
  base="$(basename "${file}")"
  node="${base%%_scenario*}"

  [[ "${node}" =~ ^node0[1-8]$ ]] ||
    runner_die 2 "invalid scenario file: ${file}"

  services+=("${node}")
done

mapfile -t services < <(
  printf '%s\n' "${services[@]}" |
    LC_ALL=C sort -u
)

for validator in node01 node02 node03; do
  found=false

  for service in "${services[@]}"; do
    if [[ "${service}" == "${validator}" ]]; then
      found=true
      break
    fi
  done

  "${found}" ||
    runner_die 2 "scenario ${scenario} must contain ${validator}"
done

project="nymtest_s${scenario}_$$"

export SCENARIO_NUMBER="${scenario}"
export NYM_SELECTED_NODES="$(
  IFS=,
  printf '%s' "${services[*]}"
)"

compose=(
  docker compose
  -p "${project}"
  -f docker/compose.yaml
)

build_images

if ! start_output="$(
  "${compose[@]}" up \
    -d \
    --no-build \
    --force-recreate \
    "${services[@]}" 2>&1
)"; then
  printf '%s\n' "${start_output}" >&2
  runner_die 1 "could not start scenario containers"
fi

for service in "${services[@]}"; do
  cid="$("${compose[@]}" ps -a -q "${service}")"

  if [[ -z "${cid}" ]]; then
    "${compose[@]}" ps -a >&2 || true
    runner_die 1 "could not resolve container ${service}"
  fi

  container_ids+=("${cid}")
done

start_node_log_capture

if ! wait_for_marker \
  /run/nym-shared/chain-ready.json \
  "${CHAIN_READY_TIMEOUT:-660}"; then

  print_failure_logs
  exit 1
fi

print_initial_chain_logs

if ! wait_for_nodes "${NODE_READY_TIMEOUT:-240}"; then
  print_failure_logs
  exit 1
fi

common_height="$(
  read_common_height 2>/dev/null || echo unknown
)"

stream_logs &
logs_pid=$!

sleep 0.2

"${compose[@]}" exec -T node01 \
  touch /run/nym-shared/scenario-release \
  >/dev/null ||
  runner_die 1 "could not release scenario"

nym_test_log INF runner \
  "validators synchronized on the live chain at common height ${common_height}; starting scenario ${scenario}: ${services[*]}"

if wait_for_completion; then
  :
else
  status=$?
  print_failure_logs
  exit "${status}"
fi

if [[ -n "${logs_pid}" ]]; then
  kill "${logs_pid}" >/dev/null 2>&1 || true
  wait "${logs_pid}" >/dev/null 2>&1 || true
  logs_pid=""
fi

stop_node_log_capture
save_node_logs

nym_test_log INF runner \
  "scenario ${scenario} completed successfully; node logs saved in ${logs_dir}"
