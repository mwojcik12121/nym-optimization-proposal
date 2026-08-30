#!/usr/bin/env bash
set -Eeuo pipefail

scenario_barrier scenario1-ready 360
assert_internal_only
height="$(last_block)"
(( height >= 200 ))
before="${height}"
txhash="$(send_tokens "${NODE02_ADDRESS}" 25unym "scenario1-node01-to-node02")"
wait_for_block "$((before + 1))" 60
wait_for_transaction "${txhash}" 60
scenario_barrier scenario1-chain-transaction 120
validate_chain
validate_block 200

wait_for_shared_file "${NYM_SHARED_DIR}/traffic/receiver-ready" 60
start_mixnet_socks5_client "${NYM_SOCKS5_CLIENT_PORT:-1080}"
scenario_barrier scenario1-traffic-ready 300

mixnet_http_request baseline success "${MIXNET_SUCCESS_TIMEOUT:-180}"
scenario_barrier scenario1-baseline-complete 240

scenario_barrier scenario1-delay-ready 120
scenario_barrier scenario1-delay-active 120
mixnet_http_request delayed success "${MIXNET_SUCCESS_TIMEOUT:-180}"
scenario_barrier scenario1-delay-observed 240
scenario_barrier scenario1-delay-healed 120

scenario_barrier scenario1-partition-ready 120
scenario_barrier scenario1-partition-active 120
mixnet_http_request partitioned failure "${MIXNET_PARTITION_TIMEOUT:-20}"
scenario_barrier scenario1-partition-observed 120
scenario_barrier scenario1-partition-healed 120

mixnet_http_request recovered success "${MIXNET_SUCCESS_TIMEOUT:-180}"
scenario_barrier scenario1-recovery-complete 240

validate_chain
stop_mixnet_socks5_client
scenario_barrier scenario1-checks-complete 120
