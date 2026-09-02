#!/usr/bin/env bash
set -Eeuo pipefail

fault_timeout="${SCENARIO_FAULT_MAX_SECONDS:-600}"
_scenario_require_positive_integer "${fault_timeout}" SCENARIO_FAULT_MAX_SECONDS
barrier_timeout=$((fault_timeout + 180))

scenario_barrier scenario1-ready 360
assert_internal_only
(( $(last_block) >= 200 ))

start_mixnet_traffic_receiver "${NYM_TRAFFIC_RECEIVER_PORT:-18090}"
scenario_barrier scenario1-traffic-ready 300
assert_mixnet_traffic_exit_source scenario1-baseline
scenario_barrier scenario1-baseline-complete 300
scenario_barrier scenario1-loop-ready 120

run_validator_transaction_workload "${NODE01_ADDRESS}"

scenario_barrier scenario1-fault-loops-complete "${barrier_timeout}"
assert_mixnet_traffic_exit_source scenario1-recovered
scenario_barrier scenario1-recovery-complete 300

validate_chain
stop_mixnet_traffic_receiver
scenario_barrier scenario1-checks-complete 180
