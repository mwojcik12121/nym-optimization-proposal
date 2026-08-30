#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_NUMBER="${1:-${SCENARIO_NUMBER:-}}"
: "${SCENARIO_NUMBER:?scenario number required}"
: "${NODE_NAME:?NODE_NAME required}"
: "${NYM_SHARED_DIR:?NYM_SHARED_DIR required}"

export NODE_ROLE=validator
export NYXD_HOME=/var/lib/nym/nyxd
export NYXD_RPC_HTTP=http://127.0.0.1:26657
export NYXD_RPC_TCP=tcp://127.0.0.1:26657

mkdir -p "${NYM_SHARED_DIR}/ready" /var/lib/nym/logs
rm -rf "${NYXD_HOME}"
mkdir -p "${NYXD_HOME}"
export NYM_NODE_LOG_FILE="/var/lib/nym/logs/${NODE_NAME}.log"
: > "${NYM_NODE_LOG_FILE}"

source /opt/nym/cluster.env

source /opt/nym/bootstrap/toml.sh

source /opt/nym/controls/actions.sh

source /opt/nym/controls/info.sh

source /opt/nym/controls/network.sh

initialize_selected_nodes

[[ "${INITIAL_CHAIN_HEIGHT}" == 200 ]] || {
  nym_fail runtime "configured initial height must be 200"
  exit 1
}
[[ "${BOOTSTRAP_HALT_HEIGHT:-}" == 201 ]] || {
  nym_fail runtime "bootstrap halt height must be 201 so block 200 is committed"
  exit 1
}

export NODE_START_COMMAND="nyxd start --home '${NYXD_HOME}' --wasm.skip_wasmvm_version_check"
NODE_PID=""
NYM_TRAFFIC_RECEIVER_PID=""
NYM_SOCKS5_CLIENT_PID=""
NYM_TRAFFIC_CLIENT_API_PID=""

validator_cleanup() {
  set +e
  network_heal
  stop_mixnet_socks5_client
  stop_mixnet_traffic_receiver
  node_stop
}
trap validator_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp -a /opt/nym/node-seed/. "${NYXD_HOME}/"
actual_genesis_sha256="$(sha256sum "${NYXD_HOME}/config/genesis.json" | awk '{print $1}')"
[[ "${actual_genesis_sha256}" == "${GENESIS_SHA256}" ]] || {
  nym_fail runtime "configured genesis checksum does not match the image seed"
  exit 1
}

nym_test_log INF startup "validating Nyxd genesis"
if ! nyxd genesis validate-genesis --home "${NYXD_HOME}" > "/var/lib/nym/logs/${NODE_NAME}-genesis-check.log" 2>&1; then
  cat "/var/lib/nym/logs/${NODE_NAME}-genesis-check.log" >> "${NYM_NODE_LOG_FILE}" 2>/dev/null || true
  nym_fail runtime "runtime genesis validation failed before Nyxd start"
  exit 1
fi
cat "/var/lib/nym/logs/${NODE_NAME}-genesis-check.log" >> "${NYM_NODE_LOG_FILE}" 2>/dev/null || true
nym_test_log INF startup "Nyxd genesis is valid"

export NYM_PROCESS_LOG="/var/lib/nym/logs/${NODE_NAME}-bootstrap.log"
configure_mixnet_contract_transaction_limits
node_start
wait_for_committed_height "${INITIAL_CHAIN_HEIGHT}" "${CHAIN_READY_TIMEOUT:-600}"
wait_for_configured_halt_and_stop "${BOOTSTRAP_HALT_HEIGHT}" 60

if ! nyxd_prepare_live_restart "${NYXD_HOME}"; then
  nym_test_log ERR runtime "failed to discard the uncommitted block-${BOOTSTRAP_HALT_HEIGHT} attempt"
  if [[ -s "${NYXD_HOME}/data/bootstrap-rollback.log" ]]; then
    cat "${NYXD_HOME}/data/bootstrap-rollback.log" >&2
  fi
  exit 1
fi

export NYM_PROCESS_LOG="/var/lib/nym/logs/${NODE_NAME}-runtime.log"
node_start
verify_live_validator_minimum

if [[ "${NODE_NAME:-}" == node01 ]]; then
  deploy_local_mixnet_contract
else
  wait_for_local_mixnet_contract "${MIXNET_CONTRACT_READY_TIMEOUT:-600}"
fi
load_local_mixnet_contract_environment

if [[ "${NODE_NAME}" == node01 ]]; then
  coordinate_live_chain_ready "${CHAIN_READY_TIMEOUT:-600}"
fi
wait_for_live_chain_ready "${CHAIN_READY_TIMEOUT:-600}"
: > "${NYM_SHARED_DIR}/ready/${NODE_NAME}"
wait_for_scenario_release "${SCENARIO_RELEASE_TIMEOUT:-600}"

scenario="/opt/nym/scenarios/${NODE_NAME}_scenario${SCENARIO_NUMBER}.sh"
[[ -x "${scenario}" ]] || {
  nym_fail runtime "scenario file is absent or not executable: ${scenario}"
  exit 1
}


nym_test_log INF runtime "executing ${NODE_NAME}_scenario${SCENARIO_NUMBER}.sh"
source "${scenario}"
