#!/usr/bin/env bash

CONTROL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${CONTROL_ROOT}/controls/info.sh"

_network_iface() {
  printf '%s\n' "${NYM_NETWORK_INTERFACE:-eth0}"
}

_network_require_admin() {
  tc qdisc show dev "$(_network_iface)" >/dev/null 2>&1 || {
    nym_fail network "NET_ADMIN is unavailable"
    return 1
  }
}

_network_fault_chains() {
  iptables -N NYM_TEST_IN 2>/dev/null || true
  iptables -N NYM_TEST_OUT 2>/dev/null || true
  iptables -C INPUT -j NYM_TEST_IN 2>/dev/null || iptables -I INPUT 1 -j NYM_TEST_IN
  iptables -C OUTPUT -j NYM_TEST_OUT 2>/dev/null || iptables -I OUTPUT 1 -j NYM_TEST_OUT
}

network_delay() {
  local delay="${1:-100}"
  local jitter="${2:-0}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding ${delay}ms latency with ${jitter}ms jitter on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  if [[ "${jitter}" == 0 ]]; then
    tc qdisc replace dev "${interface}" root netem delay "${delay}ms"
  else
    tc qdisc replace dev "${interface}" root netem \
      delay "${delay}ms" "${jitter}ms" distribution normal
  fi
}

network_isolate() {
  local interface="$(_network_iface)"

  _network_require_admin
  _network_fault_chains
  nym_test_log INF network "isolating this node from all ${interface} traffic"
  NYM_NETWORK_FAULT_ACTIVE=1
  iptables -C NYM_TEST_OUT -o "${interface}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_OUT -o "${interface}" -j DROP
  iptables -C NYM_TEST_IN -i "${interface}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_IN -i "${interface}" -j DROP
}

network_heal() {
  local interface="$(_network_iface)"

  if [[ "${NYM_NETWORK_FAULT_ACTIVE:-0}" == 1 ]]; then
    nym_test_log INF network "removing all injected delay and isolation rules"
  fi
  tc qdisc del dev "${interface}" root 2>/dev/null || true
  iptables -D INPUT -j NYM_TEST_IN 2>/dev/null || true
  iptables -D OUTPUT -j NYM_TEST_OUT 2>/dev/null || true
  iptables -F NYM_TEST_IN 2>/dev/null || true
  iptables -F NYM_TEST_OUT 2>/dev/null || true
  iptables -X NYM_TEST_IN 2>/dev/null || true
  iptables -X NYM_TEST_OUT 2>/dev/null || true
  NYM_NETWORK_FAULT_ACTIVE=0
}
