#!/usr/bin/env bash
set -Eeuo pipefail

scenario_barrier scenario1-ready 360
assert_internal_only
(( $(last_block) >= 200 ))
scenario_barrier scenario1-chain-transaction 120
height="$(last_block)"
validate_block "${height}"
peer_info

start_mixnet_traffic_receiver "${NYM_TRAFFIC_RECEIVER_PORT:-18090}"
scenario_barrier scenario1-traffic-ready 300

assert_mixnet_traffic_exit_source baseline
scenario_barrier scenario1-baseline-complete 240

scenario_barrier scenario1-delay-ready 120
scenario_barrier scenario1-delay-active 120
assert_mixnet_traffic_exit_source delayed
scenario_barrier scenario1-delay-observed 240
scenario_barrier scenario1-delay-healed 120

scenario_barrier scenario1-partition-ready 120
scenario_barrier scenario1-partition-active 120
wait_for_mixnet_traffic_result partitioned 60
assert_no_mixnet_traffic_receipt partitioned
scenario_barrier scenario1-partition-observed 120
scenario_barrier scenario1-partition-healed 120

assert_mixnet_traffic_exit_source recovered
scenario_barrier scenario1-recovery-complete 240

validate_chain
stop_mixnet_traffic_receiver
scenario_barrier scenario1-checks-complete 120
