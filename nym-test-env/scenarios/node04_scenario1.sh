#!/usr/bin/env bash
set -Eeuo pipefail

fault_timeout="${SCENARIO_FAULT_MAX_SECONDS:-600}"
_scenario_require_positive_integer "${fault_timeout}" SCENARIO_FAULT_MAX_SECONDS
barrier_timeout=$((fault_timeout + 180))

scenario_barrier scenario1-ready 360
assert_internal_only
(( $(last_block) >= 200 ))
scenario_barrier scenario1-traffic-ready 300
scenario_barrier scenario1-baseline-complete 300
scenario_barrier scenario1-loop-ready 120

run_nym_health_chain_workload

scenario_barrier scenario1-fault-loops-complete "${barrier_timeout}"
scenario_barrier scenario1-recovery-complete 300
nym_health || true
(( $(last_block) >= 200 ))
scenario_barrier scenario1-checks-complete 180
