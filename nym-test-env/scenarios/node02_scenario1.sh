#!/usr/bin/env bash
set -Eeuo pipefail

scenario_barrier scenario1-ready 360
assert_internal_only
(( $(last_block) >= 200 ))
scenario_barrier scenario1-chain-transaction 120
account_balance "${NODE02_ADDRESS}"
validate_chain
scenario_barrier scenario1-traffic-ready 300
scenario_barrier scenario1-baseline-complete 240
scenario_barrier scenario1-delay-ready 120
scenario_barrier scenario1-delay-active 120
scenario_barrier scenario1-delay-observed 240
scenario_barrier scenario1-delay-healed 120
scenario_barrier scenario1-partition-ready 120
scenario_barrier scenario1-partition-active 120
scenario_barrier scenario1-partition-observed 120
scenario_barrier scenario1-partition-healed 120
scenario_barrier scenario1-recovery-complete 240
validate_chain
scenario_barrier scenario1-checks-complete 120
