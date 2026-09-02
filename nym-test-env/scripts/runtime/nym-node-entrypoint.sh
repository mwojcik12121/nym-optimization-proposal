#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO_NUMBER="${1:-${SCENARIO_NUMBER:-}}"
: "${SCENARIO_NUMBER:?scenario number required}"
: "${NODE_NAME:?NODE_NAME required}"
: "${NODE_ROLE:?NODE_ROLE required}"
: "${NODE_IP:?NODE_IP required}"
: "${NYM_SHARED_DIR:?NYM_SHARED_DIR required}"
: "${NYXD_RPC_HTTP:?NYXD_RPC_HTTP required}"

export HOME=/var/lib/nym
export NYM_HTTP_TOKEN="${NYM_HTTP_TOKEN:-local-test-token}"
export NYM_LOCAL_API_PORT="${NYM_LOCAL_API_PORT:-18080}"
export NYM_LOCAL_API_URL="http://127.0.0.1:${NYM_LOCAL_API_PORT}"
export NYXD_RPC_WEBSOCKET="${NYXD_RPC_WEBSOCKET:-${NYXD_RPC_HTTP/http:\/\//ws:\/\/}/websocket}"

mkdir -p \
  "${HOME}" \
  "${NYM_SHARED_DIR}/ready" \
  "${NYM_SHARED_DIR}/bonding" \
  "${NYM_SHARED_DIR}/details" \
  /var/lib/nym/logs
rm -rf "${HOME}/.nym"
export NYM_NODE_LOG_FILE="/var/lib/nym/logs/${NODE_NAME}.log"
: > "${NYM_NODE_LOG_FILE}"

source /opt/nym/controls/actions.sh
source /opt/nym/controls/info.sh
source /opt/nym/controls/network.sh
source /opt/nym/bootstrap/toml.sh

initialize_selected_nodes

NODE_PID=""
NYM_LOCAL_API_PID=""

nym_node_cleanup() {
  set +e
  network_heal
  node_stop
  if [[ -n "${NYM_LOCAL_API_PID}" ]] && kill -0 "${NYM_LOCAL_API_PID}" 2>/dev/null; then
    kill -TERM "${NYM_LOCAL_API_PID}" 2>/dev/null || true
    wait "${NYM_LOCAL_API_PID}" 2>/dev/null || true
  fi
}
trap nym_node_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

nym_test_log INF startup "waiting for live Nyx chain readiness"
wait_for_live_chain_ready
load_local_mixnet_contract_environment
verify_local_mixnet_contract
nym_test_log INF startup "live Nyx chain is ready"

/opt/nym/runtime/local-nym-api \
  >> "${NYM_NODE_LOG_FILE}" 2>&1 &
NYM_LOCAL_API_PID=$!

if ! wait_for_tcp 127.0.0.1 "${NYM_LOCAL_API_PORT}" 15; then
  nym_fail startup "local Nym API did not become ready"
  exit 1
fi

mode_arguments=()
IFS=',' read -r -a modes <<<"${NYM_MODES}"
for mode in "${modes[@]}"; do
  mode_arguments+=(--mode "${mode}")
done

initialization_arguments=(
  nym-node run
  --id "${NYM_ID}"
  --init-only
  --accept-operator-terms-and-conditions
  --unsafe-disable-replay-protection
  --nym-api-urls "${NYM_LOCAL_API_URL}"
  --nyxd-urls "${NYXD_RPC_HTTP}"
  --nyxd-websocket-url "${NYXD_RPC_WEBSOCKET}"
  "${mode_arguments[@]}"
  --mixnet-bind-address "0.0.0.0:${NYM_MIX_PORT}"
  --verloc-bind-address "0.0.0.0:${NYM_VERLOC_PORT}"
  --http-bind-address "0.0.0.0:${NYM_HTTP_PORT}"
  --http-access-token "${NYM_HTTP_TOKEN}"
  --public-ips "${NODE_IP}"
  --output=json
  --bonding-information-output "${NYM_SHARED_DIR}/bonding/${NODE_NAME}.json"
)

runtime_arguments=(
  nym-node run
  --id "${NYM_ID}"
  --accept-operator-terms-and-conditions
  --unsafe-disable-replay-protection
  --nym-api-urls "${NYM_LOCAL_API_URL}"
  --nyxd-urls "${NYXD_RPC_HTTP}"
  --nyxd-websocket-url "${NYXD_RPC_WEBSOCKET}"
)

if [[ "${NYM_MODES}" == *gateway* ]]; then
  initialization_arguments+=(
    --entry-bind-address "0.0.0.0:${NYM_ENTRY_PORT}"
    --enforce-zk-nyms false
  )
  runtime_arguments+=(--enforce-zk-nyms false)
fi

if [[ "${NYM_MODES}" == *exit-gateway* ]]; then
  initialization_arguments+=(
    --lp-use-mock-ecash true
    --wireguard-enabled true
    --wireguard-userspace true
    --upstream-exit-policy-url "${NYM_LOCAL_API_URL}/exit-policy"
    --open-proxy true
    --nr-allow-local-ips true
    --ipr-allow-local-ips true
  )
  runtime_arguments+=(
    --lp-use-mock-ecash true
    --wireguard-enabled true
    --wireguard-userspace true
    --upstream-exit-policy-url "${NYM_LOCAL_API_URL}/exit-policy"
    --open-proxy true
    --nr-allow-local-ips true
    --ipr-allow-local-ips true
  )
fi

nym_test_log INF startup "running nym-node initialization"
if ! "${initialization_arguments[@]}" \
  > >(nym_application_stream "${NODE_ROLE}-init" "/var/lib/nym/logs/${NODE_NAME}-init.log") 2>&1; then
  nym_fail startup "nym-node initialization failed"
  exit 1
fi
nym_test_log INF startup "nym-node initialization completed"
patch_nym_node_contract_config

config_file="${HOME}/.nym/nym-nodes/${NYM_ID}/config/config.toml"
[[ -s "${config_file}" ]] || {
  nym_fail startup "nym-node config is missing after initialization: ${config_file}"
  exit 1
}

if [[ "${NYM_MODES}" == *gateway* ]]; then
  toml_set "${config_file}" "gateway_tasks.upgrade_mode" "enabled" "false"
  toml_set "${config_file}" "gateway_tasks.upgrade_mode" "attestation_url" "\"${NYM_LOCAL_API_URL}/upgrade-mode-attestation\""
fi

if [[ "${NYM_MODES}" == *exit-gateway* ]]; then
  toml_set "${config_file}" "service_providers" "upstream_exit_policy_url" "\"${NYM_LOCAL_API_URL}/exit-policy\""
  toml_set "${config_file}" "service_providers" "open_proxy" "true"
fi

if ! nym_write_node_details; then
  nym_fail startup "nym-node details export failed"
  exit 1
fi

nym_test_log INF startup "preparing local Nym topology"
if ! nym_prepare_topology; then
  nym_fail startup "local Nym topology preparation failed"
  exit 1
fi
nym_test_log INF startup "local Nym topology is ready"

printf -v NODE_START_COMMAND '%q ' "${runtime_arguments[@]}"
export NODE_START_COMMAND

nym_test_log INF startup "starting nym-node runtime"
if ! node_start; then
  nym_fail startup "nym-node runtime failed to start"
  exit 1
fi

nym_test_log INF startup "waiting for nym-node HTTP port ${NYM_HTTP_PORT}"
if ! wait_for_tcp 127.0.0.1 "${NYM_HTTP_PORT}" 90; then
  nym_fail startup "nym-node HTTP port ${NYM_HTTP_PORT} did not become ready"
  exit 1
fi
nym_test_log INF startup "nym-node HTTP port ${NYM_HTTP_PORT} is ready"

if ! nym_health; then
  nym_test_log INF startup "nym-node health endpoint did not answer; TCP readiness succeeded"
fi

: > "${NYM_SHARED_DIR}/ready/${NODE_NAME}"
nym_test_log INF startup "node readiness marker published"
wait_for_scenario_release "${SCENARIO_RELEASE_TIMEOUT:-600}"
nym_test_log INF runtime "scenario release received"

scenario="/opt/nym/scenarios/${NODE_NAME}_scenario${SCENARIO_NUMBER}.sh"
[[ -x "${scenario}" ]] || {
  nym_fail runtime "scenario file is absent or not executable: ${scenario}"
  exit 1
}

nym_test_log INF runtime "executing ${NODE_NAME}_scenario${SCENARIO_NUMBER}.sh"
source "${scenario}"
