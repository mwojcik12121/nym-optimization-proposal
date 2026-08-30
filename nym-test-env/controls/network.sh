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

_network_resolve_ipv4() {
  getent ahostsv4 "${1:?host required}" 2>/dev/null | \
    awk 'NR == 1 {print $1}' || true
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

network_latency() {
  network_delay "$@"
}

network_loss() {
  local percent="${1:-5}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding ${percent}% packet loss on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root netem loss "${percent}%"
}

network_corrupt() {
  local percent="${1:-1}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding ${percent}% packet corruption on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root netem corrupt "${percent}%"
}

network_duplicate() {
  local percent="${1:-1}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding ${percent}% packet duplication on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root netem duplicate "${percent}%"
}

network_reorder() {
  local percent="${1:-20}"
  local correlation="${2:-50}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding ${percent}% reordering (${correlation}% correlation) on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root netem \
    delay 50ms reorder "${percent}%" "${correlation}%"
}

network_rate() {
  local rate="${1:-5mbit}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "limiting egress to ${rate} on ${interface}"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root tbf \
    rate "${rate}" burst 64kb latency 400ms
}

network_profile() {
  local delay="${1:-100}"
  local jitter="${2:-10}"
  local loss="${3:-1}"
  local interface="$(_network_iface)"

  _network_require_admin
  nym_test_log INF network "adding profile: ${delay}ms delay, ${jitter}ms jitter, ${loss}% loss"
  NYM_NETWORK_FAULT_ACTIVE=1
  tc qdisc replace dev "${interface}" root netem \
    delay "${delay}ms" "${jitter}ms" loss "${loss}%"
}

network_partition_peer() {
  local peer="${1:?peer host/IP required}"
  local address

  _network_require_admin
  address="$(_network_resolve_ipv4 "${peer}")"
  if [[ -z "${address}" ]]; then
    nym_fail network "cannot resolve ${peer}"
    return 1
  fi
  _network_fault_chains
  nym_test_log INF network "partitioning peer ${peer} (${address}) in both directions"
  NYM_NETWORK_FAULT_ACTIVE=1
  iptables -C NYM_TEST_OUT -d "${address}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_OUT -d "${address}" -j DROP
  iptables -C NYM_TEST_IN -s "${address}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_IN -s "${address}" -j DROP
}

network_blackhole_port() {
  local port="${1:?port required}"
  local protocol="${2:-tcp}"

  _network_require_admin
  _network_fault_chains
  nym_test_log INF network "blackholing ${protocol} port ${port} in both directions"
  NYM_NETWORK_FAULT_ACTIVE=1
  iptables -C NYM_TEST_OUT -p "${protocol}" --dport "${port}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_OUT -p "${protocol}" --dport "${port}" -j DROP
  iptables -C NYM_TEST_IN -p "${protocol}" --sport "${port}" -j DROP 2>/dev/null \
    || iptables -A NYM_TEST_IN -p "${protocol}" --sport "${port}" -j DROP
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
    nym_test_log INF network "removing all test latency, loss, rate and partition rules"
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

network_state() {
  local interface="$(_network_iface)"

  nym_test_log INF network "showing active network fault state"
  tc -s qdisc show dev "${interface}" || true
  iptables -S NYM_TEST_IN 2>/dev/null || true
  iptables -S NYM_TEST_OUT 2>/dev/null || true
}
