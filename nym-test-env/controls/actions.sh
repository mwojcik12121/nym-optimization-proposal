#!/usr/bin/env bash


CONTROL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${CONTROL_ROOT}/controls/info.sh"

initialize_selected_nodes() {
  local selected="${NYM_SHARED_DIR:?}/selected-nodes"
  local temporary="${selected}.${NODE_NAME:-node}.$$"

  : "${NYM_SELECTED_NODES:?NYM_SELECTED_NODES required}"
  mkdir -p "${NYM_SHARED_DIR}"
  printf '%s\n' "${NYM_SELECTED_NODES//,/$'\n'}" > "${temporary}"
  mv -f "${temporary}" "${selected}"
}

_require_validator() {
  [[ "${NODE_ROLE:-}" == validator ]] \
    || nym_fail action "this action requires a Nyx validator node"
}

_require_nym_node() {
  [[ "${NODE_ROLE:-}" == mixnode* || "${NODE_ROLE:-}" == *gateway* ]] \
    || nym_fail action "this action requires nym-node"
}

scenario_barrier() {
  local name="${1:?barrier name required}"
  local timeout="${2:-300}"
  local selected="${NYM_SHARED_DIR:?}/selected-nodes"
  local directory="${NYM_SHARED_DIR}/barriers/${SCENARIO_NUMBER}/${name}"
  local expected
  local current
  local started="${SECONDS}"

  [[ -f "${selected}" ]] || nym_fail action "selected-nodes file is missing"
  mkdir -p "${directory}"
  : > "${directory}/${NODE_NAME}"
  expected="$(grep -cve '^$' "${selected}")"

  while true; do
    current="$(find "${directory}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    if (( current >= expected )); then
      if [[ "${NODE_NAME:-}" == node01 ]]; then
        nym_test_log INF scenario "barrier '${name}' released"
      fi
      return 0
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "barrier '${name}' timed out (${current}/${expected})"
      return 1
    fi
    sleep 0.25
  done
}

wait_for_tcp() {
  local host="${1:?host required}"
  local port="${2:?port required}"
  local timeout="${3:-60}"
  local started="${SECONDS}"
  until nc -z -w 1 "${host}" "${port}" >/dev/null 2>&1; do
    if (( SECONDS - started >= timeout )); then
      nym_fail action "TCP ${host}:${port} not ready"
      return 1
    fi
    sleep 0.5
  done
}

wait_for_http() {
  local url="${1:?URL required}"
  local timeout="${2:-60}"
  local started="${SECONDS}"
  until curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; do
    if (( SECONDS - started >= timeout )); then
      nym_fail action "HTTP ${url} not ready"
      return 1
    fi
    sleep 0.5
  done
}

wait_for_shared_file() {
  local file="${1:?file required}"
  local timeout="${2:-360}"
  local started="${SECONDS}"

  while [[ ! -s "${file}" ]]; do
    if (( SECONDS - started >= timeout )); then
      nym_fail action "timed out waiting for shared file ${file}"
      return 1
    fi
    sleep 0.25
  done
}

node_start() {
  [[ -n "${NODE_START_COMMAND:-}" ]] \
    || nym_fail action "NODE_START_COMMAND is not configured"
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "${NODE_PID}" 2>/dev/null; then
    return 0
  fi
  NYM_PROCESS_LOG="${NYM_PROCESS_LOG:-/var/lib/nym/logs/${NODE_NAME}-${NODE_ROLE}.log}"
  export NYM_PROCESS_LOG
  : > "${NYM_PROCESS_LOG}"
  bash -lc "exec ${NODE_START_COMMAND}" \
    > >(nym_application_stream "${NODE_ROLE}" "${NYM_PROCESS_LOG}") 2>&1 &
  NODE_PID=$!
  export NODE_PID
}

node_stop() {
  local deadline

  if [[ -z "${NODE_PID:-}" ]] || ! kill -0 "${NODE_PID}" 2>/dev/null; then
    NODE_PID=""
    export NODE_PID
    return 0
  fi
  kill -TERM "${NODE_PID}" 2>/dev/null || true
  deadline=$((SECONDS + 20))
  while kill -0 "${NODE_PID}" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.2
  done
  if kill -0 "${NODE_PID}" 2>/dev/null; then
    nym_test_log ERR action "node process did not stop after 20 seconds; forcing termination"
    kill -KILL "${NODE_PID}" 2>/dev/null || true
  fi
  wait "${NODE_PID}" 2>/dev/null || true
  NODE_PID=""
  export NODE_PID
}

node_restart() {
  node_stop
  node_start
}

node_pause() {
  [[ -n "${NODE_PID:-}" ]] && kill -0 "${NODE_PID}" 2>/dev/null \
    || nym_fail action "node process is not running"
  nym_test_log INF action "pausing PID ${NODE_PID}"
  kill -STOP "${NODE_PID}"
}

node_resume() {
  [[ -n "${NODE_PID:-}" ]] && kill -0 "${NODE_PID}" 2>/dev/null \
    || nym_fail action "node process is not running"
  nym_test_log INF action "resuming PID ${NODE_PID}"
  kill -CONT "${NODE_PID}"
}

wait_for_signed_height() {
  local target="${1:?target height required}"
  local timeout="${2:-300}"
  local state_file="${NYXD_HOME}/data/priv_validator_state.json"
  local height=0
  local started="${SECONDS}"

  _require_validator
  while true; do
    height="$(jq -r '.height // "0"' "${state_file}" 2>/dev/null || echo 0)"
    [[ "${height}" =~ ^[0-9]+$ ]] || height=0
    if (( height >= target )); then
      return 0
    fi
    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "${NODE_PID}" 2>/dev/null; then
      local exit_status=0
      set +e
      wait "${NODE_PID}" 2>/dev/null
      exit_status=$?
      set -e
      NODE_PID=""
      export NODE_PID
      nym_fail action "nyxd exited before block ${target} (signed height ${height}, exit status ${exit_status})"
      return 1
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "timed out waiting for signed block ${target} (height ${height})"
      return 1
    fi
    sleep 0.25
  done
}

wait_for_committed_height() {
  local target="${1:?target height required}"
  local timeout="${2:-300}"
  local started="${SECONDS}"
  local status_json=""
  local height=0
  local exit_status=0

  _require_validator
  while true; do
    status_json="$(curl -fsS --max-time 1 "${NYXD_RPC_HTTP}/status" 2>/dev/null || true)"
    if [[ -n "${status_json}" ]]; then
      height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"${status_json}" 2>/dev/null || echo 0)"
      [[ "${height}" =~ ^[0-9]+$ ]] || height=0
      if (( height >= target )); then
        return 0
      fi
    fi

    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "${NODE_PID}" 2>/dev/null; then
      set +e
      wait "${NODE_PID}" 2>/dev/null
      exit_status=$?
      set -e
      NODE_PID=""
      export NODE_PID
      nym_fail action "nyxd exited before committed block ${target} (committed height ${height}, exit status ${exit_status})"
      return 1
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "timed out waiting for committed block ${target} (height ${height})"
      return 1
    fi
    sleep 0.2
  done
}

wait_for_configured_halt_and_stop() {
  local halt_height="${1:-${BOOTSTRAP_HALT_HEIGHT:-201}}"
  local timeout="${2:-60}"
  local started="${SECONDS}"
  local log_file="${NYM_PROCESS_LOG:-/var/lib/nym/logs/${NODE_NAME}-bootstrap.log}"
  local marker="halt per configuration height ${halt_height}"
  local exit_status=0

  _require_validator
  while true; do
    if [[ -s "${log_file}" ]] && grep -Fq "${marker}" "${log_file}"; then
      if [[ -n "${NODE_PID:-}" ]] && kill -0 "${NODE_PID}" 2>/dev/null; then
        node_stop
      elif [[ -n "${NODE_PID:-}" ]]; then
        set +e
        wait "${NODE_PID}" 2>/dev/null
        exit_status=$?
        set -e
        NODE_PID=""
        export NODE_PID
      fi
      return 0
    fi

    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "${NODE_PID}" 2>/dev/null; then
      set +e
      wait "${NODE_PID}" 2>/dev/null
      exit_status=$?
      set -e
      NODE_PID=""
      export NODE_PID
      if [[ -s "${log_file}" ]] && grep -Fq "${marker}" "${log_file}"; then
        return 0
      fi
      nym_fail action "nyxd exited before the configured halt marker appeared (exit status ${exit_status})"
      return 1
    fi

    if (( SECONDS - started >= timeout )); then
      nym_fail action "timed out waiting for configured halt at block ${halt_height}"
      return 1
    fi
    sleep 0.1
  done
}

verify_live_validator_minimum() {
  local status_json
  local height
  local network

  _require_validator
  [[ "${INITIAL_CHAIN_HEIGHT:-}" == 200 ]] \
    || { nym_fail action "INITIAL_CHAIN_HEIGHT must be 200"; return 1; }

  wait_for_http "${NYXD_RPC_HTTP}/status" 90
  status_json="$(curl -fsS --max-time 5 "${NYXD_RPC_HTTP}/status")"
  height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"${status_json}")"
  network="$(jq -r '.result.node_info.network // empty' <<<"${status_json}")"

  [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= INITIAL_CHAIN_HEIGHT )) \
    || { nym_fail action "validator height must be at least ${INITIAL_CHAIN_HEIGHT}, got ${height}"; return 1; }
  [[ "${network}" == "${CHAIN_ID}" ]] \
    || { nym_fail action "chain ID mismatch: expected ${CHAIN_ID}, got ${network}"; return 1; }
  curl -fsS --max-time 5 "${NYXD_RPC_HTTP}/block?height=${INITIAL_CHAIN_HEIGHT}" | \
    jq -e --arg height "${INITIAL_CHAIN_HEIGHT}" '.result.block.header.height == $height' >/dev/null
}

coordinate_live_chain_ready() {
  local timeout="${1:-${CHAIN_READY_TIMEOUT:-600}}"
  local max_lag="${VALIDATOR_SYNC_MAX_LAG:-2}"
  local required_confirmations="${VALIDATOR_SYNC_CONFIRMATIONS:-3}"
  local poll_interval="${VALIDATOR_SYNC_POLL_INTERVAL:-0.5}"
  local ready="${NYM_SHARED_DIR:?}/chain-ready.json"
  local temporary="${ready}.tmp.$$"
  local started="${SECONDS}"
  local confirmations=0
  local validator
  local status_json
  local block_json
  local height
  local network
  local block_hash
  local app_hash
  local reference_hash
  local reference_app_hash
  local minimum_height
  local maximum_height
  local lag
  local valid
  local last_summary="unavailable"
  local -a heights

  [[ "${NODE_NAME:-}" == node01 ]] \
    || { nym_fail action "only node01 may publish live-chain readiness"; return 1; }
  [[ "${max_lag}" =~ ^[0-9]+$ ]] \
    || { nym_fail action "VALIDATOR_SYNC_MAX_LAG must be an integer"; return 1; }
  [[ "${required_confirmations}" =~ ^[1-9][0-9]*$ ]] \
    || { nym_fail action "VALIDATOR_SYNC_CONFIRMATIONS must be positive"; return 1; }

  while true; do
    heights=()
    valid=true

    for validator in node01 node02 node03; do
      status_json="$(curl -fsS --max-time 2 "http://${validator}:26657/status" 2>/dev/null || true)"
      if [[ -z "${status_json}" ]]; then
        valid=false
        break
      fi

      height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"${status_json}" 2>/dev/null || echo 0)"
      network="$(jq -r '.result.node_info.network // empty' <<<"${status_json}" 2>/dev/null || true)"
      if [[ ! "${height}" =~ ^[0-9]+$ ]] || [[ "${network}" != "${CHAIN_ID}" ]]; then
        valid=false
        break
      fi
      heights+=("${height}")
    done

    if [[ "${valid}" == true ]] && (( ${#heights[@]} == 3 )); then
      minimum_height="${heights[0]}"
      maximum_height="${heights[0]}"
      for height in "${heights[@]}"; do
        (( height < minimum_height )) && minimum_height="${height}"
        (( height > maximum_height )) && maximum_height="${height}"
      done
      lag=$((maximum_height - minimum_height))
      last_summary="node01=${heights[0]},node02=${heights[1]},node03=${heights[2]},lag=${lag}"

      if (( minimum_height >= INITIAL_CHAIN_HEIGHT && lag <= max_lag )); then
        reference_hash=""
        reference_app_hash=""
        for validator in node01 node02 node03; do
          block_json="$(curl -fsS --max-time 3 \
            "http://${validator}:26657/block?height=${minimum_height}" 2>/dev/null || true)"
          block_hash="$(jq -r '.result.block_id.hash // empty' <<<"${block_json}" 2>/dev/null || true)"
          app_hash="$(jq -r '.result.block.header.app_hash // empty' <<<"${block_json}" 2>/dev/null || true)"
          if [[ -z "${block_hash}" ]]; then
            valid=false
            break
          fi
          if [[ -z "${reference_hash}" ]]; then
            reference_hash="${block_hash}"
            reference_app_hash="${app_hash}"
          elif [[ "${block_hash}" != "${reference_hash}" || "${app_hash}" != "${reference_app_hash}" ]]; then
            valid=false
            break
          fi
        done

        if [[ "${valid}" == true ]]; then
          confirmations=$((confirmations + 1))
          if (( confirmations >= required_confirmations )); then
            jq -n \
              --arg chain_id "${CHAIN_ID}" \
              --arg genesis_sha256 "${GENESIS_SHA256}" \
              --arg block_hash "${reference_hash}" \
              --arg app_hash "${reference_app_hash}" \
              --argjson required_initial_height "${INITIAL_CHAIN_HEIGHT}" \
              --argjson synchronized_height "${minimum_height}" \
              --argjson observed_max_height "${maximum_height}" \
              --argjson height_lag "${lag}" \
              '{
                ready:true,
                source:"configured-generation-live",
                chain_id:$chain_id,
                required_initial_height:$required_initial_height,
                synchronized_height:$synchronized_height,
                observed_max_height:$observed_max_height,
                height_lag:$height_lag,
                genesis_sha256:$genesis_sha256,
                block_hash:$block_hash,
                app_hash:$app_hash,
                validators:["node01","node02","node03"]
              }' > "${temporary}"
            mv "${temporary}" "${ready}"
            return 0
          fi
        else
          confirmations=0
        fi
      else
        confirmations=0
      fi
    else
      confirmations=0
    fi

    if [[ -n "${NODE_PID:-}" ]] && ! kill -0 "${NODE_PID}" 2>/dev/null; then
      nym_fail action "node01 Nyxd exited while coordinating live-chain synchronization"
      return 1
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "validators did not converge within ${timeout}s (${last_summary})"
      return 1
    fi
    sleep "${poll_interval}"
  done
}

wait_for_live_chain_ready() {
  local timeout="${1:-${CHAIN_READY_TIMEOUT:-600}}"
  local ready="${NYM_SHARED_DIR:?}/chain-ready.json"
  local started="${SECONDS}"

  while true; do
    if [[ -s "${ready}" ]] && jq -e \
      --arg chain_id "${CHAIN_ID}" \
      --argjson minimum "${INITIAL_CHAIN_HEIGHT}" \
      '.ready == true and
       .source == "configured-generation-live" and
       .chain_id == $chain_id and
       .required_initial_height == $minimum and
       .synchronized_height >= $minimum and
       (.block_hash | length > 0)' \
      "${ready}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "${NODE_ROLE:-}" == validator ]] &&
       [[ -n "${NODE_PID:-}" ]] &&
       ! kill -0 "${NODE_PID}" 2>/dev/null; then
      nym_fail action "Nyxd exited before live-chain readiness"
      return 1
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "timed out waiting for live-chain readiness"
      return 1
    fi
    sleep 0.25
  done
}

wait_for_block() {
  local target="${1:?target block required}"
  local timeout="${2:-60}"
  local started="${SECONDS}"
  local current
  while true; do
    current="$(_last_block_value 2>/dev/null || echo 0)"
    if [[ "${current}" =~ ^[0-9]+$ ]] && (( current >= target )); then
      return 0
    fi
    if (( SECONDS - started >= timeout )); then
      nym_fail action "block ${target} not reached (current ${current})"
      return 1
    fi
    sleep 0.5
  done
}

wait_for_transaction() {
  local hash="${1:?transaction hash required}"
  local timeout="${2:-60}"
  local started="${SECONDS}"
  local output
  local code
  local codespace
  local raw_log

  _require_validator
  until output="$(nyxd query tx "${hash}" --node "${NYXD_RPC_TCP}" --output json 2>/dev/null)"; do
    if (( SECONDS - started >= timeout )); then
      nym_fail action "transaction ${hash} did not commit"
      return 1
    fi
    sleep 0.5
  done

  code="$(jq -r '.code // 0' <<<"${output}")"
  if [[ ! "${code}" =~ ^[0-9]+$ ]] || (( code != 0 )); then
    codespace="$(jq -r '.codespace // empty' <<<"${output}")"
    raw_log="$(jq -r '.raw_log // .log // empty' <<<"${output}")"
    nym_fail action "transaction ${hash} failed with code ${code} in ${codespace:-unknown}: ${raw_log:-no error details}"
    return 1
  fi
}

send_tokens() {
  local recipient="${1:?recipient required}"
  local amount="${2:-1unym}"
  local memo="${3:-test-${NODE_NAME}-$(date +%s%N)}"
  local from="${4:-validator}"
  local output
  local transaction_hash

  _require_validator
  nym_test_log INF action "sending ${amount} from key '${from}' to ${recipient} (memo: ${memo})"
  output="$(nyxd tx bank send "${from}" "${recipient}" "${amount}" \
    --home "${NYXD_HOME}" \
    --chain-id "${CHAIN_ID}" \
    --keyring-backend test \
    --node "${NYXD_RPC_TCP}" \
    --gas 220000 \
    --fees 1000unym \
    --broadcast-mode sync \
    --yes \
    --memo "${memo}" \
    --output json)"
  transaction_hash="$(jq -r '.txhash // empty' <<<"${output}")"
  if [[ -z "${transaction_hash}" ]]; then
    nym_test_log ERR action "transaction response: ${output}"
    nym_fail action "transaction did not return a hash"
    return 1
  fi
  nym_test_log INF action "transaction accepted with hash ${transaction_hash}"
  printf '%s\n' "${transaction_hash}"
}

create_transaction() {
  send_tokens "$@"
}

produce_block() {
  local before
  local own_address
  local transaction_hash

  _require_validator
  before="$(_last_block_value)"
  own_address="$(nyxd keys show validator -a --home "${NYXD_HOME}" --keyring-backend test)"
  transaction_hash="$(send_tokens \
    "${own_address}" 1unym "produce-block-${NODE_NAME}-$(date +%s%N)")"
  wait_for_block "$((before + 1))" 60
  wait_for_transaction "${transaction_hash}" 60
}

mine_block() {
  produce_block
}

mine_blocks() {
  local count="${1:-1}"
  local index

  nym_test_log INF action "producing ${count} Nyx blocks"
  for ((index = 1; index <= count; index++)); do
    produce_block
  done
}

validate_chain() {
  local ready="${NYM_SHARED_DIR:?}/chain-ready.json"
  local status
  local height
  local network
  local synchronized_height
  local expected_hash
  local local_hash

  _require_validator
  wait_for_live_chain_ready
  status="$(curl -fsS "${NYXD_RPC_HTTP}/status")"
  height="$(jq -r '.result.sync_info.latest_block_height // "0"' <<<"${status}")"
  network="$(jq -r '.result.node_info.network // empty' <<<"${status}")"
  synchronized_height="$(jq -r '.synchronized_height' "${ready}")"
  expected_hash="$(jq -r '.block_hash' "${ready}")"
  local_hash="$(curl -fsS "${NYXD_RPC_HTTP}/block?height=${synchronized_height}" | \
    jq -r '.result.block_id.hash // empty')"

  [[ "${height}" =~ ^[0-9]+$ ]] && (( height >= synchronized_height )) \
    || { nym_fail action "local height ${height} is below synchronized height ${synchronized_height}"; return 1; }
  [[ "${network}" == "${CHAIN_ID}" ]] \
    || { nym_fail action "chain ID mismatch: expected ${CHAIN_ID}, got ${network}"; return 1; }
  [[ -n "${local_hash}" && "${local_hash}" == "${expected_hash}" ]] \
    || { nym_fail action "local chain does not contain the shared synchronization block"; return 1; }
  nym_test_log INF action "chain validation passed at live height ${height}"
}

validate_block() {
  local height="${1:?height required}"

  _require_validator
  nym_test_log INF action "validating block ${height}"
  curl -fsS "${NYXD_RPC_HTTP}/block?height=${height}" | \
    jq -e --arg height "${height}" '.result.block.header.height == $height' >/dev/null
  nym_test_log INF action "block ${height} is available and structurally valid"
}

validate_transaction() {
  local hash="${1:?transaction hash required}"

  _require_validator
  nym_test_log INF action "validating transaction ${hash}"
  nyxd query tx "${hash}" --node "${NYXD_RPC_TCP}" --output json | \
    jq -e '.txhash != null' >/dev/null
  nym_test_log INF action "transaction ${hash} is valid"
}

delegate_tokens() {
  local amount="${1:-1000000unyx}"
  local validator_operator

  _require_validator
  validator_operator="$(nyxd keys show validator --bech val -a \
    --home "${NYXD_HOME}" --keyring-backend test)"
  nym_test_log INF action "delegating ${amount} to ${validator_operator}"
  nyxd tx staking delegate "${validator_operator}" "${amount}" \
    --from validator \
    --home "${NYXD_HOME}" \
    --chain-id "${CHAIN_ID}" \
    --keyring-backend test \
    --node "${NYXD_RPC_TCP}" \
    --gas 300000 \
    --fees 1000unym \
    --yes \
    --broadcast-mode sync >/dev/null
}

unjail_validator() {
  _require_validator
  nym_test_log INF action "submitting validator unjail transaction"
  nyxd tx slashing unjail \
    --from validator \
    --home "${NYXD_HOME}" \
    --chain-id "${CHAIN_ID}" \
    --keyring-backend test \
    --node "${NYXD_RPC_TCP}" \
    --gas 250000 \
    --fees 1000unym \
    --yes \
    --broadcast-mode sync >/dev/null
}

nym_health() {
  _require_nym_node
  nym_test_log INF action "checking nym-node health API on port ${NYM_HTTP_PORT}"
  _nym_http_first /api/v1/health /api/v1/status/health /health >/dev/null
  nym_test_log INF action "nym-node health endpoint responded"
}

nym_port_check() {
  local host="${1:?host required}"
  local port="${2:?port required}"

  _require_nym_node
  nym_test_log INF action "checking Nym service port ${host}:${port}"
  wait_for_tcp "${host}" "${port}" 30
}

nym_write_node_details() {
  local config="${HOME}/.nym/nym-nodes/${NYM_ID}/config/config.toml"
  local target="${NYM_SHARED_DIR}/details/${NODE_NAME}.json"

  _require_nym_node
  mkdir -p "${NYM_SHARED_DIR}/details"
  [[ -f "${config}" ]] || nym_fail action "nym-node config is missing: ${config}"
  nym_test_log INF action "exporting source-built nym-node details to ${target}"
  nym-node node-details --config-file "${config}" --output=json > "${target}.tmp"
  mv "${target}.tmp" "${target}"
}

nym_prepare_topology() {
  local selected="${NYM_SHARED_DIR}/selected-nodes"
  local selected_count
  local started="${SECONDS}"
  local present

  _require_nym_node
  selected_count="$(grep -Ec '^node0[4-8]$' "${selected}" || true)"
  if (( selected_count != 5 )); then
    return 0
  fi
  if [[ "${NODE_NAME}" == node04 ]]; then
    while true; do
      present="$(find "${NYM_SHARED_DIR}/bonding" "${NYM_SHARED_DIR}/details" \
        -maxdepth 1 -type f -name 'node0[4-8].json' 2>/dev/null | wc -l | tr -d ' ')"
      (( present >= 10 )) && break
      if (( SECONDS - started >= 90 )); then
        nym_fail action "topology inputs timed out (${present}/10)"
        return 1
      fi
      sleep 0.5
    done
    /opt/nym/runtime/build-topology.sh "${NYM_SHARED_DIR}"
  fi

  while [[ ! -s "${NYM_SHARED_DIR}/network.json" ]]; do
    if (( SECONDS - started >= 100 )); then
      nym_fail action "network.json timed out"
      return 1
    fi
    sleep 0.5
  done
}

nym_collect_bonding_inventory() {
  local output="${NYM_SHARED_DIR}/bonding/inventory.json"
  local started="${SECONDS}"
  local selected_count
  local present

  _require_nym_node
  mkdir -p "${NYM_SHARED_DIR}/bonding"
  selected_count="$(grep -Ec '^node0[4-8]$' "${NYM_SHARED_DIR}/selected-nodes" || true)"
  nym_test_log INF action "collecting bonding information for ${selected_count} selected nym-node services"

  while true; do
    present="$(find "${NYM_SHARED_DIR}/bonding" -maxdepth 1 \
      -name 'node0[4-8].json' -type f | wc -l | tr -d ' ')"
    (( present >= selected_count )) && break
    if (( SECONDS - started >= 60 )); then
      nym_fail action "bonding information timed out"
      return 1
    fi
    sleep 0.5
  done

  jq -s '{generated_by:"nym-docker-testnet",nodes:.}' \
    "${NYM_SHARED_DIR}"/bonding/node0[4-8].json > "${output}"
  nym_test_log INF action "bonding inventory written to ${output}"
}

assert_internal_only() {
  if nc -z -w 2 1.1.1.1 443 >/dev/null 2>&1; then
    nym_fail action "unexpected external connectivity is available"
    return 1
  fi
}

_socks5_client_has_option() {
  local help_text="${1:-}"
  local option="${2:?option required}"

  grep -Fq -- "${option}" <<<"${help_text}"
}

_mixnet_network_requester_address() {
  local details="${NYM_SHARED_DIR:?}/details/node08.json"
  local address

  wait_for_shared_file "${details}" 120
  address="$(jq -r '.exit_network_requester_address // empty' "${details}")"
  [[ -n "${address}" ]] || {
    nym_fail traffic "node08 network requester address is missing"
    return 1
  }
  printf '%s\n' "${address}"
}

_mixnet_entry_gateway_identity() {
  local details="${NYM_SHARED_DIR:?}/details/node07.json"
  local identity

  wait_for_shared_file "${details}" 120
  identity="$(jq -r '.ed25519_identity_key // .identity_key // empty' "${details}")"
  [[ -n "${identity}" ]] || {
    nym_fail traffic "node07 entry-gateway identity is missing"
    return 1
  }
  printf '%s\n' "${identity}"
}

start_mixnet_traffic_receiver() {
  local port="${1:-${NYM_TRAFFIC_RECEIVER_PORT:-18090}}"
  local record_dir="${NYM_SHARED_DIR:?}/traffic/receipts"
  local log_file="/var/lib/nym/logs/${NODE_NAME}-traffic-receiver.log"

  mkdir -p "${record_dir}" /var/lib/nym/logs
  rm -f "${record_dir}"/*.json "${record_dir}"/requests.log 2>/dev/null || true

  if [[ -n "${NYM_TRAFFIC_RECEIVER_PID:-}" ]] &&
     kill -0 "${NYM_TRAFFIC_RECEIVER_PID}" 2>/dev/null; then
    return 0
  fi

  (
    export NYM_LOCAL_API_BIND_ADDRESS=0.0.0.0
    export NYM_LOCAL_API_PORT="${port}"
    export NYM_TRAFFIC_RECORD_DIR="${record_dir}"
    exec "${CONTROL_ROOT}/runtime/local-nym-api"
  ) > >(nym_application_stream traffic-receiver "${log_file}") 2>&1 &
  NYM_TRAFFIC_RECEIVER_PID=$!
  export NYM_TRAFFIC_RECEIVER_PID

  if ! wait_for_tcp 127.0.0.1 "${port}" 20; then
    nym_fail traffic "traffic receiver failed to listen on port ${port}"
    return 1
  fi

  : > "${NYM_SHARED_DIR}/traffic/receiver-ready"
  nym_test_log INF traffic "receiver listening on node03:${port}"
}

stop_mixnet_traffic_receiver() {
  if [[ -n "${NYM_TRAFFIC_RECEIVER_PID:-}" ]] &&
     kill -0 "${NYM_TRAFFIC_RECEIVER_PID}" 2>/dev/null; then
    kill -TERM "${NYM_TRAFFIC_RECEIVER_PID}" 2>/dev/null || true
    wait "${NYM_TRAFFIC_RECEIVER_PID}" 2>/dev/null || true
  fi
  NYM_TRAFFIC_RECEIVER_PID=""
  export NYM_TRAFFIC_RECEIVER_PID
}

start_mixnet_socks5_client() {
  local port="${1:-${NYM_SOCKS5_CLIENT_PORT:-1080}}"
  local api_port="${NYM_SOCKS5_API_PORT:-18081}"
  local api_url="http://127.0.0.1:${api_port}"
  local client_id="scenario${SCENARIO_NUMBER}-${NODE_NAME}"
  local client_home="/var/lib/nym/socks5-test"
  local provider
  local gateway
  local init_help
  local run_help
  local init_log="/var/lib/nym/logs/${NODE_NAME}-socks5-init.log"
  local run_log="/var/lib/nym/logs/${NODE_NAME}-socks5-runtime.log"
  local started
  local exit_status=0
  local -a init_arguments
  local -a run_arguments

  [[ "${NODE_NAME:-}" == node01 ]] || {
    nym_fail traffic "only node01 may run the scenario SOCKS5 client"
    return 1
  }
  command -v nym-socks5-client >/dev/null 2>&1 || {
    nym_fail traffic "nym-socks5-client is missing from node01 image"
    return 1
  }

  provider="$(_mixnet_network_requester_address)" || return 1
  gateway="$(_mixnet_entry_gateway_identity)" || return 1
  wait_for_shared_file "${NYM_SHARED_DIR}/network.json" 120
  wait_for_shared_file "${NYM_SHARED_DIR}/rewarded-set.json" 120

  rm -rf "${client_home}"
  mkdir -p "${client_home}" "${NYM_SHARED_DIR}/traffic/results" /var/lib/nym/logs

  (
    export NYM_LOCAL_API_BIND_ADDRESS=127.0.0.1
    export NYM_LOCAL_API_PORT="${api_port}"
    unset NYM_TRAFFIC_RECORD_DIR
    exec "${CONTROL_ROOT}/runtime/local-nym-api"
  ) > >(nym_application_stream socks5-local-api "/var/lib/nym/logs/${NODE_NAME}-socks5-local-api.log") 2>&1 &
  NYM_TRAFFIC_CLIENT_API_PID=$!
  export NYM_TRAFFIC_CLIENT_API_PID

  if ! wait_for_tcp 127.0.0.1 "${api_port}" 20; then
    nym_fail traffic "local Nym API for the SOCKS5 client failed to start"
    return 1
  fi

  init_help="$(HOME="${client_home}" nym-socks5-client init --help 2>&1)"
  init_arguments=(
    nym-socks5-client init
    --id "${client_id}"
    --provider "${provider}"
    --port "${port}"
  )

  if _socks5_client_has_option "${init_help}" --gateway; then
    init_arguments+=(--gateway "${gateway}")
  elif _socks5_client_has_option "${init_help}" --gateway-id; then
    init_arguments+=(--gateway-id "${gateway}")
  else
    nym_fail traffic "nym-socks5-client init does not support selecting node07 as gateway"
    return 1
  fi

  if _socks5_client_has_option "${init_help}" --nym-apis; then
    init_arguments+=(--nym-apis "${api_url}")
  elif _socks5_client_has_option "${init_help}" --nym-api-urls; then
    init_arguments+=(--nym-api-urls "${api_url}")
  else
    nym_fail traffic "nym-socks5-client init has no local Nym API option"
    return 1
  fi

  if _socks5_client_has_option "${init_help}" --nyxd-urls; then
    init_arguments+=(--nyxd-urls "${NYXD_RPC_HTTP}")
  elif _socks5_client_has_option "${init_help}" --nyxd-url; then
    init_arguments+=(--nyxd-url "${NYXD_RPC_HTTP}")
  fi

  if _socks5_client_has_option "${init_help}" ; then
    init_arguments+=()
  fi

  nym_test_log INF traffic "initializing SOCKS5 client through node07 for node08 network requester"
  if ! HOME="${client_home}" "${init_arguments[@]}" \
      > >(nym_application_stream socks5-init "${init_log}") 2>&1; then
    nym_fail traffic "nym-socks5-client initialization failed"
    return 1
  fi

  run_help="$(HOME="${client_home}" nym-socks5-client run --help 2>&1)"
  run_arguments=(nym-socks5-client run --id "${client_id}")
  if _socks5_client_has_option "${run_help}" --use-anonymous-replies; then
    run_arguments+=(--use-anonymous-replies true)
  fi

  HOME="${client_home}" "${run_arguments[@]}" \
    > >(nym_application_stream socks5-client "${run_log}") 2>&1 &
  NYM_SOCKS5_CLIENT_PID=$!
  export NYM_SOCKS5_CLIENT_PID

  started="${SECONDS}"
  while ! nc -z -w 1 127.0.0.1 "${port}" >/dev/null 2>&1; do
    if ! kill -0 "${NYM_SOCKS5_CLIENT_PID}" 2>/dev/null; then
      set +e
      wait "${NYM_SOCKS5_CLIENT_PID}" 2>/dev/null
      exit_status=$?
      set -e
      NYM_SOCKS5_CLIENT_PID=""
      export NYM_SOCKS5_CLIENT_PID
      nym_fail traffic "nym-socks5-client exited before its SOCKS5 listener was ready (status ${exit_status})"
      return 1
    fi
    if (( SECONDS - started >= 180 )); then
      nym_fail traffic "timed out waiting for SOCKS5 listener on port ${port}"
      return 1
    fi
    sleep 0.5
  done

  : > "${NYM_SHARED_DIR}/traffic/client-ready"
  nym_test_log INF traffic "SOCKS5 client listening on 127.0.0.1:${port}"
}

stop_mixnet_socks5_client() {
  if [[ -n "${NYM_SOCKS5_CLIENT_PID:-}" ]] &&
     kill -0 "${NYM_SOCKS5_CLIENT_PID}" 2>/dev/null; then
    kill -TERM "${NYM_SOCKS5_CLIENT_PID}" 2>/dev/null || true
    wait "${NYM_SOCKS5_CLIENT_PID}" 2>/dev/null || true
  fi
  NYM_SOCKS5_CLIENT_PID=""
  export NYM_SOCKS5_CLIENT_PID

  if [[ -n "${NYM_TRAFFIC_CLIENT_API_PID:-}" ]] &&
     kill -0 "${NYM_TRAFFIC_CLIENT_API_PID}" 2>/dev/null; then
    kill -TERM "${NYM_TRAFFIC_CLIENT_API_PID}" 2>/dev/null || true
    wait "${NYM_TRAFFIC_CLIENT_API_PID}" 2>/dev/null || true
  fi
  NYM_TRAFFIC_CLIENT_API_PID=""
  export NYM_TRAFFIC_CLIENT_API_PID
}

mixnet_http_request() {
  local token="${1:?traffic token required}"
  local expectation="${2:-success}"
  local timeout="${3:-120}"
  local socks_port="${NYM_SOCKS5_CLIENT_PORT:-1080}"
  local receiver_port="${NYM_TRAFFIC_RECEIVER_PORT:-18090}"
  local expected_source="${MIXNET_EXIT_IP:-172.31.0.25}"
  local result_dir="${NYM_SHARED_DIR:?}/traffic/results"
  local body_file="${result_dir}/${token}.body"
  local error_file="${result_dir}/${token}.error"
  local result_file="${result_dir}/${token}.json"
  local temporary="${result_file}.tmp.$$"
  local metrics=""
  local status=0
  local http_status="000"
  local latency="0"
  local receiver_source=""

  mkdir -p "${result_dir}"
  rm -f "${body_file}" "${error_file}" "${result_file}" "${temporary}"

  set +e
  metrics="$(curl \
    --silent \
    --show-error \
    --fail-with-body \
    --proxy "socks5h://127.0.0.1:${socks_port}" \
    --noproxy "" \
    --connect-timeout "${timeout}" \
    --max-time "${timeout}" \
    --output "${body_file}" \
    --write-out '%{http_code} %{time_total}' \
    "http://node03:${receiver_port}/traffic/${token}" \
    2>"${error_file}")"
  status=$?
  set -e

  if [[ -n "${metrics}" ]]; then
    read -r http_status latency <<<"${metrics}"
  fi

  if [[ "${expectation}" == success ]]; then
    if (( status != 0 )); then
      jq -n \
        --arg token "${token}" \
        --argjson curl_status "${status}" \
        --arg error "$(cat "${error_file}" 2>/dev/null || true)" \
        '{token:$token,expected:"success",success:false,curl_status:$curl_status,error:$error}' \
        > "${temporary}"
      mv "${temporary}" "${result_file}"
      nym_fail traffic "mixnet request '${token}' failed before reaching the receiver"
      return 1
    fi

    jq -e \
      --arg token "${token}" \
      --arg source "${expected_source}" \
      '.received == true and .token == $token and .source == $source' \
      "${body_file}" >/dev/null || {
        nym_fail traffic "receiver response for '${token}' did not prove exit through ${expected_source}"
        return 1
      }
    receiver_source="$(jq -r '.source' "${body_file}")"
    jq -n \
      --arg token "${token}" \
      --arg http_status "${http_status}" \
      --arg latency_seconds "${latency}" \
      --arg receiver_source "${receiver_source}" \
      '{token:$token,expected:"success",success:true,http_status:$http_status,latency_seconds:$latency_seconds,receiver_source:$receiver_source}' \
      > "${temporary}"
    mv "${temporary}" "${result_file}"
    nym_test_log INF traffic \
      "request '${token}' reached node03 through the mixnet and exited from ${receiver_source} in ${latency}s"
    return 0
  fi

  if [[ "${expectation}" != failure ]]; then
    nym_fail traffic "unknown request expectation: ${expectation}"
    return 1
  fi

  if (( status == 0 )); then
    jq -n \
      --arg token "${token}" \
      --arg http_status "${http_status}" \
      --arg latency_seconds "${latency}" \
      '{token:$token,expected:"failure",success:true,http_status:$http_status,latency_seconds:$latency_seconds}' \
      > "${temporary}"
    mv "${temporary}" "${result_file}"
    nym_fail traffic "request '${token}' unexpectedly succeeded during the mixnet partition"
    return 1
  fi

  jq -n \
    --arg token "${token}" \
    --argjson curl_status "${status}" \
    --arg latency_seconds "${latency}" \
    --arg error "$(cat "${error_file}" 2>/dev/null || true)" \
    '{token:$token,expected:"failure",success:false,curl_status:$curl_status,latency_seconds:$latency_seconds,error:$error}' \
    > "${temporary}"
  mv "${temporary}" "${result_file}"
  nym_test_log INF traffic "request '${token}' was interrupted while the mixnet path was partitioned"
}

wait_for_mixnet_traffic_result() {
  local token="${1:?traffic token required}"
  local timeout="${2:-180}"

  wait_for_shared_file "${NYM_SHARED_DIR:?}/traffic/results/${token}.json" "${timeout}"
}

wait_for_mixnet_traffic_receipt() {
  local token="${1:?traffic token required}"
  local timeout="${2:-180}"

  wait_for_shared_file "${NYM_SHARED_DIR:?}/traffic/receipts/${token}.json" "${timeout}"
}

assert_mixnet_traffic_exit_source() {
  local token="${1:?traffic token required}"
  local expected="${2:-${MIXNET_EXIT_IP:-172.31.0.25}}"
  local receipt="${NYM_SHARED_DIR:?}/traffic/receipts/${token}.json"
  local source

  wait_for_mixnet_traffic_receipt "${token}" 180
  source="$(jq -r '.source // empty' "${receipt}")"
  [[ "${source}" == "${expected}" ]] || {
    nym_fail traffic "receiver saw source ${source:-missing} for '${token}', expected exit gateway ${expected}"
    return 1
  }
  nym_test_log INF traffic "receiver accepted '${token}' from exit gateway ${source}"
}

assert_no_mixnet_traffic_receipt() {
  local token="${1:?traffic token required}"
  local receipt="${NYM_SHARED_DIR:?}/traffic/receipts/${token}.json"

  [[ ! -e "${receipt}" ]] || {
    nym_fail traffic "receiver unexpectedly obtained '${token}' while the path was partitioned"
    return 1
  }
  nym_test_log INF traffic "receiver did not obtain '${token}' during the partition"
}

mixnet_contract_state_file() {
  printf '%s/contracts/mixnet.json\n' "${NYM_SHARED_DIR:?}"
}

mixnet_contract_address() {
  local state_file

  state_file="$(mixnet_contract_state_file)"
  [[ -s "${state_file}" ]] || return 1
  jq -r '.address // .mixnet_address // empty' "${state_file}"
}

node_families_contract_address() {
  local state_file

  state_file="$(mixnet_contract_state_file)"
  [[ -s "${state_file}" ]] || return 1
  jq -r '.node_families_address // empty' "${state_file}"
}

wait_for_local_mixnet_contract() {
  local timeout="${1:-300}"
  local started="${SECONDS}"
  local state_file
  local address
  local node_families_address

  state_file="$(mixnet_contract_state_file)"
  while true; do
    if [[ -s "${state_file}" ]]; then
      address="$(jq -r '.address // .mixnet_address // empty' "${state_file}" 2>/dev/null || true)"
      node_families_address="$(jq -r '.node_families_address // empty' "${state_file}" 2>/dev/null || true)"
      if [[ -n "${address}" && -n "${node_families_address}" ]] \
         && nyxd query wasm contract "${address}" --node "${NYXD_RPC_TCP}" --output json >/dev/null 2>&1 \
         && nyxd query wasm contract "${node_families_address}" --node "${NYXD_RPC_TCP}" --output json >/dev/null 2>&1; then
        return 0
      fi
    fi

    if [[ "${NODE_ROLE:-}" == validator ]] \
       && [[ -n "${NODE_PID:-}" ]] \
       && ! kill -0 "${NODE_PID}" 2>/dev/null; then
      nym_fail contract 'Nyxd exited while waiting for the local Nym contracts'
      return 1
    fi

    if (( SECONDS - started >= timeout )); then
      nym_fail contract "timed out waiting for local Nym contracts after ${timeout}s"
      return 1
    fi

    sleep 0.5
  done
}

load_local_mixnet_contract_environment() {
  local state_file
  local address
  local node_families_address
  local vesting_address
  local names_file="${MIXNET_CONTRACT_ENV_NAMES_FILE:-/opt/nym/contracts/mixnet_contract_env_names}"
  local name
  local value

  state_file="$(mixnet_contract_state_file)"
  [[ -s "${state_file}" ]] \
    || { nym_fail contract "local Nym contract state is missing: ${state_file}"; return 1; }

  address="$(jq -r '.address // .mixnet_address // empty' "${state_file}")"
  node_families_address="$(jq -r '.node_families_address // empty' "${state_file}")"
  vesting_address="$(jq -r '.vesting_address // .owner // empty' "${state_file}")"
  [[ -n "${address}" ]] || { nym_fail contract 'local mixnet contract address is empty'; return 1; }
  [[ -n "${node_families_address}" ]] || { nym_fail contract 'local node-families contract address is empty'; return 1; }
  [[ -n "${vesting_address}" ]] || vesting_address="${address}"

  export NYM_MIXNET_CONTRACT_ADDRESS="${address}"
  export MIXNET_CONTRACT_ADDRESS="${address}"
  export NYM_NETWORK_DEFAULTS__MIXNET_CONTRACT_ADDRESS="${address}"
  export NYM_NODE_FAMILIES_CONTRACT_ADDRESS="${node_families_address}"
  export NODE_FAMILIES_CONTRACT_ADDRESS="${node_families_address}"
  export NYM_NETWORK_DEFAULTS__NODE_FAMILIES_CONTRACT_ADDRESS="${node_families_address}"
  export NYM_VESTING_CONTRACT_ADDRESS="${vesting_address}"
  export VESTING_CONTRACT_ADDRESS="${vesting_address}"
  export NYM_NETWORK_DEFAULTS__VESTING_CONTRACT_ADDRESS="${vesting_address}"

  if [[ -s "${names_file}" ]]; then
    while IFS= read -r name; do
      [[ "${name}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
      case "${name}" in
        *NODE*FAMIL*CONTRACT*ADDRESS*) value="${node_families_address}" ;;
        *VESTING*CONTRACT*ADDRESS*) value="${vesting_address}" ;;
        *MIXNET*CONTRACT*ADDRESS*) value="${address}" ;;
        *) continue ;;
      esac
      printf -v "${name}" '%s' "${value}"
      export "${name}"
    done < "${names_file}"
  fi
}

patch_nym_node_contract_config() {
  local address="${NYM_MIXNET_CONTRACT_ADDRESS:?}"
  local node_families="${NYM_NODE_FAMILIES_CONTRACT_ADDRESS:?}"
  local vesting="${NYM_VESTING_CONTRACT_ADDRESS:-${address}}"
  local root="${HOME}/.nym/nym-nodes/${NYM_ID:?}"
  local config
  local temporary

  while IFS= read -r -d '' config; do
    temporary="${config}.contract.tmp.$$"
    awk -v mixnet="${address}" -v families="${node_families}" -v vesting="${vesting}" '
      /^[[:space:]]*(mixnet_contract_address|mixnet_contract)[[:space:]]*=/ {
        prefix = $0; sub(/=.*/, "= ", prefix); print prefix "\"" mixnet "\""; next
      }
      /^[[:space:]]*(node_families_contract_address|node_families_contract)[[:space:]]*=/ {
        prefix = $0; sub(/=.*/, "= ", prefix); print prefix "\"" families "\""; next
      }
      /^[[:space:]]*vesting_contract_address[[:space:]]*=/ {
        prefix = $0; sub(/=.*/, "= ", prefix); print prefix "\"" vesting "\""; next
      }
      { print }
    ' "${config}" > "${temporary}"
    mv "${temporary}" "${config}"
  done < <(find "${root}" -type f -name '*.toml' -print0 2>/dev/null)
}

verify_local_mixnet_contract() {
  local address
  local families

  load_local_mixnet_contract_environment
  address="${NYM_MIXNET_CONTRACT_ADDRESS}"
  families="${NYM_NODE_FAMILIES_CONTRACT_ADDRESS}"

  if command -v nyxd >/dev/null 2>&1; then
    nyxd query wasm contract "${address}" --node "${NYXD_RPC_TCP}" --output json >/dev/null
    nyxd query wasm contract "${families}" --node "${NYXD_RPC_TCP}" --output json >/dev/null
  else
    curl -fsS --max-time 5 "${NYXD_RPC_HTTP}/status" >/dev/null
  fi
}

contract_tx_attribute() {
  local hash="${1:?transaction hash required}"
  local event_type="${2:?event type required}"
  local key="${3:?attribute key required}"

  nyxd query tx "${hash}" --node "${NYXD_RPC_TCP}" --output json 2>/dev/null | \
    jq -r --arg event "${event_type}" --arg key "${key}" '
      [.. | objects
       | select(.type? == $event)
       | .attributes[]?
       | select(.key? == $key)
       | .value?] | last // empty
    '
}

store_local_wasm_contract() {
  local wasm="${1:?Wasm file required}"
  local name="${2:?contract name required}"
  local output
  local hash
  local code_id

  if ! output="$(nyxd tx wasm store "${wasm}" \
      --from validator --home "${NYXD_HOME}" --chain-id "${CHAIN_ID}" \
      --keyring-backend test --node "${NYXD_RPC_TCP}" \
      --gas "${MIXNET_CONTRACT_STORE_GAS:-200000000}" \
      --fees "${MIXNET_CONTRACT_STORE_FEES:-200000000unym}" \
      --broadcast-mode sync --yes --output json 2>&1)"; then
    nym_test_log ERR contract "${output}"
    nym_fail contract "${name} store transaction failed"
    return 1
  fi

  hash="$(jq -r '.txhash // empty' <<<"${output}" 2>/dev/null || true)"
  [[ -n "${hash}" ]] || { nym_fail contract "${name} store transaction returned no hash"; return 1; }
  wait_for_transaction "${hash}" "${MIXNET_CONTRACT_TX_TIMEOUT:-300}"
  code_id="$(contract_tx_attribute "${hash}" store_code code_id)"
  if [[ -z "${code_id}" ]]; then
    code_id="$(nyxd query wasm list-code --node "${NYXD_RPC_TCP}" --output json | \
      jq -r '[.code_infos[]?.code_id | tonumber] | max // empty')"
  fi
  [[ "${code_id}" =~ ^[0-9]+$ ]] || { nym_fail contract "could not determine ${name} code ID"; return 1; }
  printf '%s\t%s\n' "${code_id}" "${hash}"
}

wasm_code_hash() {
  local code_id="${1:?code ID required}"

  nyxd query wasm code-info "${code_id}" --node "${NYXD_RPC_TCP}" --output json | \
    jq -r '.data_hash // .checksum // .code_info.data_hash // .code_info.checksum // empty'
}

instantiated_contract_address() {
  local hash="${1:?transaction hash required}"
  local code_id="${2:?code ID required}"
  local address

  address="$(contract_tx_attribute "${hash}" instantiate _contract_address)"
  [[ -n "${address}" ]] || address="$(contract_tx_attribute "${hash}" instantiate contract_address)"
  if [[ -z "${address}" ]]; then
    address="$(nyxd query wasm list-contract-by-code "${code_id}" --node "${NYXD_RPC_TCP}" --output json | jq -r '.contracts[-1] // empty')"
  fi
  printf '%s\n' "${address}"
}

deploy_local_mixnet_contract() {
  local mixnet_wasm="${MIXNET_CONTRACT_WASM:-/opt/nym/contracts/mixnet_contract.wasm}"
  local mixnet_template="${MIXNET_CONTRACT_TEMPLATE:-/opt/nym/contracts/mixnet_instantiate_template.json}"
  local families_wasm="${NODE_FAMILIES_CONTRACT_WASM:-/opt/nym/contracts/node_families_contract.wasm}"
  local families_template="${NODE_FAMILIES_CONTRACT_TEMPLATE:-/opt/nym/contracts/node_families_instantiate_template.json}"
  local state_file
  local directory
  local temporary
  local owner
  local mixnet_store
  local families_store
  local mixnet_code_id
  local families_code_id
  local mixnet_store_hash
  local families_store_hash
  local mixnet_hash
  local salt_hex
  local predicted_output
  local predicted_address
  local prefix
  local families_message
  local families_output
  local families_tx
  local families_address
  local mixnet_message
  local mixnet_output
  local mixnet_tx
  local mixnet_address

  _require_validator
  [[ "${NODE_NAME:-}" == node01 ]] || { nym_fail contract 'only node01 may deploy local Nym contracts'; return 1; }

  state_file="$(mixnet_contract_state_file)"
  directory="$(dirname "${state_file}")"
  mkdir -p "${directory}"
  if [[ -s "${state_file}" ]] && wait_for_local_mixnet_contract 5; then
    load_local_mixnet_contract_environment
    return 0
  fi
  rm -f "${state_file}"

  for file in "${mixnet_wasm}" "${mixnet_template}" "${families_wasm}" "${families_template}"; do
    [[ -s "${file}" ]] || { nym_fail contract "required local contract artifact is missing: ${file}"; return 1; }
  done

  owner="$(nyxd keys show validator -a --home "${NYXD_HOME}" --keyring-backend test)"
  [[ -n "${owner}" ]] || { nym_fail contract 'could not resolve node01 validator account'; return 1; }

  nym_test_log INF contract 'storing source-built node-families and mixnet contracts on local Nyx'
  families_store="$(store_local_wasm_contract "${families_wasm}" node-families)" || return 1
  IFS=$'\t' read -r families_code_id families_store_hash <<<"${families_store}"
  mixnet_store="$(store_local_wasm_contract "${mixnet_wasm}" mixnet)" || return 1
  IFS=$'\t' read -r mixnet_code_id mixnet_store_hash <<<"${mixnet_store}"

  mixnet_hash="$(wasm_code_hash "${mixnet_code_id}")"
  [[ -n "${mixnet_hash}" ]] || { nym_fail contract 'could not determine mixnet Wasm code hash'; return 1; }
  salt_hex="$(printf 'nym-local-mixnet' | od -An -tx1 | tr -d ' \n')"

  predicted_output="$(nyxd query wasm build-address "${mixnet_hash}" "${owner}" "${salt_hex}" \
    --node "${NYXD_RPC_TCP}" 2>&1)" || {
      nym_test_log ERR contract "${predicted_output}"
      nym_fail contract 'could not precompute the mixnet instantiate2 address'
      return 1
    }
  prefix="${owner%%1*}"
  predicted_address="$(grep -Eo "${prefix}1[0-9a-z]+" <<<"${predicted_output}" | head -n1 || true)"
  [[ -n "${predicted_address}" ]] || { nym_test_log ERR contract "${predicted_output}"; nym_fail contract 'build-address returned no contract address'; return 1; }

  families_message="$(jq -c --arg mixnet "${predicted_address}" --arg owner "${owner}" '
    walk(if type == "string" and . == "__MIXNET_CONTRACT_ADDRESS__" then $mixnet
         elif type == "string" and . == "__OWNER_ADDRESS__" then $owner
         else . end)
  ' "${families_template}")"

  nym_test_log INF contract "instantiating node-families contract for predicted mixnet address ${predicted_address}"
  if ! families_output="$(nyxd tx wasm instantiate "${families_code_id}" "${families_message}" \
      --label nym-local-node-families --admin "${owner}" \
      --from validator --home "${NYXD_HOME}" --chain-id "${CHAIN_ID}" \
      --keyring-backend test --node "${NYXD_RPC_TCP}" \
      --gas "${MIXNET_CONTRACT_INSTANTIATE_GAS:-50000000}" \
      --fees "${MIXNET_CONTRACT_INSTANTIATE_FEES:-50000000unym}" \
      --broadcast-mode sync --yes --output json 2>&1)"; then
    nym_test_log ERR contract "${families_output}"
    nym_fail contract 'node-families contract instantiate transaction failed'
    return 1
  fi
  families_tx="$(jq -r '.txhash // empty' <<<"${families_output}")"
  [[ -n "${families_tx}" ]] || { nym_fail contract 'node-families instantiate returned no tx hash'; return 1; }
  wait_for_transaction "${families_tx}" "${MIXNET_CONTRACT_TX_TIMEOUT:-300}"
  families_address="$(instantiated_contract_address "${families_tx}" "${families_code_id}")"
  [[ -n "${families_address}" ]] || { nym_fail contract 'could not determine node-families contract address'; return 1; }

  mixnet_message="$(jq -c \
    --arg rewarding "${owner}" \
    --arg vesting "${owner}" \
    --arg families "${families_address}" '
      .rewarding_validator_address = $rewarding
      | if has("vesting_contract_address") then .vesting_contract_address = $vesting else . end
      | if has("node_families_contract_address") then .node_families_contract_address = $families else . end
    ' "${mixnet_template}")"

  nym_test_log INF contract "instantiating mixnet contract at predictable address ${predicted_address}"
  if ! mixnet_output="$(nyxd tx wasm instantiate2 "${mixnet_code_id}" "${mixnet_message}" "${salt_hex}" \
      --label nym-local-mixnet --admin "${owner}" \
      --from validator --home "${NYXD_HOME}" --chain-id "${CHAIN_ID}" \
      --keyring-backend test --node "${NYXD_RPC_TCP}" \
      --gas "${MIXNET_CONTRACT_INSTANTIATE_GAS:-50000000}" \
      --fees "${MIXNET_CONTRACT_INSTANTIATE_FEES:-50000000unym}" \
      --broadcast-mode sync --yes --output json 2>&1)"; then
    nym_test_log ERR contract "${mixnet_output}"
    nym_fail contract 'mixnet contract instantiate2 transaction failed'
    return 1
  fi
  mixnet_tx="$(jq -r '.txhash // empty' <<<"${mixnet_output}")"
  [[ -n "${mixnet_tx}" ]] || { nym_fail contract 'mixnet instantiate2 returned no tx hash'; return 1; }
  wait_for_transaction "${mixnet_tx}" "${MIXNET_CONTRACT_TX_TIMEOUT:-300}"
  mixnet_address="$(instantiated_contract_address "${mixnet_tx}" "${mixnet_code_id}")"
  [[ -n "${mixnet_address}" ]] || mixnet_address="${predicted_address}"
  [[ "${mixnet_address}" == "${predicted_address}" ]] || {
    nym_fail contract "instantiate2 address mismatch: predicted ${predicted_address}, got ${mixnet_address}"
    return 1
  }

  nyxd query wasm contract "${families_address}" --node "${NYXD_RPC_TCP}" --output json >/dev/null
  nyxd query wasm contract "${mixnet_address}" --node "${NYXD_RPC_TCP}" --output json >/dev/null

  temporary="${state_file}.tmp.$$"
  jq -n \
    --arg address "${mixnet_address}" \
    --arg node_families_address "${families_address}" \
    --arg owner "${owner}" \
    --arg vesting_address "${owner}" \
    --arg mixnet_code_id "${mixnet_code_id}" \
    --arg node_families_code_id "${families_code_id}" \
    --arg mixnet_store_tx "${mixnet_store_hash}" \
    --arg node_families_store_tx "${families_store_hash}" \
    --arg mixnet_instantiate_tx "${mixnet_tx}" \
    --arg node_families_instantiate_tx "${families_tx}" '
      {
        ready:true,
        address:$address,
        mixnet_address:$address,
        node_families_address:$node_families_address,
        owner:$owner,
        vesting_address:$vesting_address,
        mixnet_code_id:($mixnet_code_id|tonumber),
        node_families_code_id:($node_families_code_id|tonumber),
        mixnet_store_tx:$mixnet_store_tx,
        node_families_store_tx:$node_families_store_tx,
        mixnet_instantiate_tx:$mixnet_instantiate_tx,
        node_families_instantiate_tx:$node_families_instantiate_tx
      }
    ' > "${temporary}"
  mv "${temporary}" "${state_file}"

  load_local_mixnet_contract_environment
  nym_test_log INF contract "local Nym contracts are ready: mixnet=${mixnet_address} node-families=${families_address}"
}

configure_mixnet_contract_transaction_limits() {
  local config="${NYXD_HOME:?}/config/config.toml"
  local temporary="${config}.limits.tmp.$$"

  [[ -f "${config}" ]] \
    || { nym_fail contract "Nyxd config is missing: ${config}"; return 1; }

  awk '
    /^[[:space:]]*max_tx_bytes[[:space:]]*=/ {
      print "max_tx_bytes = 10485760"
      next
    }
    /^[[:space:]]*max_txs_bytes[[:space:]]*=/ {
      print "max_txs_bytes = 1073741824"
      next
    }
    /^[[:space:]]*max_body_bytes[[:space:]]*=/ {
      print "max_body_bytes = 25165824"
      next
    }
    { print }
  ' "${config}" > "${temporary}"
  mv "${temporary}" "${config}"
}
