#!/usr/bin/env bash
set -Eeuo pipefail

fault_timeout="${SCENARIO_FAULT_MAX_SECONDS:-600}"
_scenario_require_positive_integer "${fault_timeout}" SCENARIO_FAULT_MAX_SECONDS
barrier_timeout=$((fault_timeout + 180))

scenario_barrier scenario1-ready 360
assert_internal_only
(( $(last_block) >= 200 ))

wait_for_shared_file "${NYM_SHARED_DIR}/traffic/receiver-ready" 60
start_mixnet_socks5_client "${NYM_SOCKS5_CLIENT_PORT:-1080}"
scenario_barrier scenario1-traffic-ready 300

mixnet_http_request scenario1-baseline success "${MIXNET_SUCCESS_TIMEOUT:-180}"
scenario_barrier scenario1-baseline-complete 300
scenario_barrier scenario1-loop-ready 120

validator_workload_pid=""
validator_workload_status=0
mixnet_workload_status=0
run_validator_transaction_workload "${NODE02_ADDRESS}" &
validator_workload_pid=$!
run_mixnet_observation_workload || mixnet_workload_status=$?
wait "${validator_workload_pid}" || validator_workload_status=$?

if (( validator_workload_status != 0 || mixnet_workload_status != 0 )); then
  nym_fail scenario \
    "node01 workload failed (transactions=${validator_workload_status}, mixnet=${mixnet_workload_status})"
  exit 1
fi

scenario_barrier scenario1-fault-loops-complete "${barrier_timeout}"
mixnet_http_request scenario1-recovered success "${MIXNET_SUCCESS_TIMEOUT:-180}"
scenario_barrier scenario1-recovery-complete 300

validate_chain
stop_mixnet_socks5_client
scenario_barrier scenario1-checks-complete 180
