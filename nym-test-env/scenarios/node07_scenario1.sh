#!/usr/bin/env bash
set -Eeuo pipefail

scenario_barrier scenario1-ready 360
assert_internal_only
scenario_barrier scenario1-chain-transaction 120
(( $(last_block) >= 201 ))
nym_health || true
nym_port_check node04 10004
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
nym_health || true
nym_port_check node04 10004
nym_port_check node08 10008
nym_bonding_info
scenario_barrier scenario1-checks-complete 120
