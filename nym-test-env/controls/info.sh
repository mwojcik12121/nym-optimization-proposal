#!/usr/bin/env bash

nym_strip_ansi() {
  LC_ALL=C sed -u -E \
    -e $'s/\033\[[0-?]*[ -\/]*[@-~]//g' \
    -e $'s/\033\][^\a\033]*(\a|\033\\\\)//g' \
    -e $'s/\033[@-_]//g'
}

nym_timestamp() {
  date '+%Y-%m-%dT%H:%M:%S.%3N'
}

nym_log_released() {
  [[ -z "${NYM_SHARED_DIR:-}" ]] || [[ -f "${NYM_SHARED_DIR}/scenario-release" ]]
}

nym_test_log() {
  local severity="${1:-INF}"
  local component="${2:-runtime}"
  local message
  local line
  local rendered
  local rendered_severity

  shift 2 || true
  message="$(printf '%s' "$*" | nym_strip_ansi)"
  case "${severity}" in
    ERR) rendered_severity=ERROR ;;
    INF) rendered_severity=INFO ;;
    *) rendered_severity="${severity}" ;;
  esac
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf -v rendered '%s %-8s [%s][%s] %s' \
      "$(nym_timestamp)" \
      "${rendered_severity}" \
      "${NODE_NAME:-runner}" \
      "${component}" \
      "${line}"

    if [[ -n "${NYM_NODE_LOG_FILE:-}" ]]; then
      mkdir -p "$(dirname "${NYM_NODE_LOG_FILE}")"
      printf '%s\n' "${rendered}" >> "${NYM_NODE_LOG_FILE}"
    fi

    if [[ "${severity}" == ERR ]] || nym_log_released; then
      printf '%s\n' "${rendered}" >&2
    fi
  done <<< "${message}"
}

nym_fail() {
  local component="${1:-runtime}"
  shift || true
  nym_test_log ERR "${component}" "$*"
  return 1
}

nym_abort() {
  local component="${1:-runtime}"
  shift || true
  nym_test_log ERR "${component}" "$*"
  exit 1
}

nym_application_severity() {
  local line="${1:-}"

  case "${line}" in
    *" ERR "*|ERR\ *|*" ERRO "*|ERRO\ *|*" ERROR "*|ERROR\ *|*" FATAL "*|FATAL\ *|*"panic"*|*"CONSENSUS FAILURE"*)
      printf 'ERR\n'
      ;;
    *)
      printf 'INF\n'
      ;;
  esac
}

nym_is_expected_bootstrap_halt_line() {
  local line="${1:-}"
  local halt_height="${BOOTSTRAP_HALT_HEIGHT:-201}"

  [[ "${line}" == *"halt per configuration height ${halt_height}"* ]]
}

nym_is_expected_bootstrap_shutdown_line() {
  local line="${1:-}"

  case "${line}" in
    *"already stopped"*|*"use of closed network connection"*|*"Stopped accept routine"*|*"Error serving server"*|*"Error stopping pool"*|*"Stopping peer for error"*|*"connection refused"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

nym_emit_initial_chain_line() {
  local line="${1:-}"
  local target="${INITIAL_CHAIN_HEIGHT:-200}"
  local height

  [[ "${NODE_NAME:-}" == node01 ]] || return 1
  [[ "${NODE_ROLE:-}" == validator ]] || return 1
  if [[ "${line}" =~ committed[[:space:]]+state.*height=([0-9]+) ]]; then
    height="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  (( height >= 1 && height <= target )) || return 1
  if (( height <= ${NYM_STREAM_LAST_INITIAL_HEIGHT:-0} )); then
    return 1
  fi

  NYM_STREAM_LAST_INITIAL_HEIGHT="${height}"
  printf '%s\n' "${line}"
}

nym_relay_application_line() {
  local line="${1:-}"
  local mode="${NYM_APPLICATION_LOG_MODE:-all}"
  local severity

  nym_is_expected_bootstrap_halt_line "${line}" && return 0
  severity="$(nym_application_severity "${line}")"

  case "${mode}" in
    off)
      return 0
      ;;
    errors)
      [[ "${severity}" == ERR ]] || return 0
      ;;
    all)
      ;;
    *)
      [[ "${severity}" == ERR ]] || return 0
      ;;
  esac

  if [[ "${severity}" == ERR ]]; then
    printf '%s\n' "${line}" >&2
  else
    printf '%s\n' "${line}"
  fi
}

nym_application_stream() {
  local component="${1:-application}"
  local log_file="${2:-/tmp/nym-application.log}"
  local line
  local severity
  local expected_halt_seen=0

  : "${component}"
  NYM_STREAM_LAST_INITIAL_HEIGHT=0
  mkdir -p "$(dirname "${log_file}")"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >> "${log_file}"
    if [[ -n "${NYM_NODE_LOG_FILE:-}" && "${NYM_NODE_LOG_FILE}" != "${log_file}" ]]; then
      printf '%s\n' "${line}" >> "${NYM_NODE_LOG_FILE}"
    fi

    if nym_is_expected_bootstrap_halt_line "${line}"; then
      expected_halt_seen=1
      continue
    fi

    if nym_log_released; then
      nym_relay_application_line "${line}"
      continue
    fi

    if nym_emit_initial_chain_line "${line}"; then
      continue
    fi

    severity="$(nym_application_severity "${line}")"
    if [[ "${severity}" == ERR ]]; then
      if (( expected_halt_seen )) && nym_is_expected_bootstrap_shutdown_line "${line}"; then
        continue
      fi
      printf '%s\n' "${line}" >&2
    fi
  done < <(nym_strip_ansi)
}

wait_for_scenario_release() {
  local timeout="${1:-600}"
  local started="${SECONDS}"
  local marker="${NYM_SHARED_DIR:?}/scenario-release"

  while [[ ! -f "${marker}" ]]; do
    if (( SECONDS - started >= timeout )); then
      nym_fail runtime "timed out waiting for scenario release"
      return 1
    fi
    sleep 0.25
  done
  return 0
}

_last_block_value() {
  curl -fsS --max-time 3 \
    "${NYXD_RPC_HTTP:-http://127.0.0.1:26657}/status" | \
    jq -r '.result.sync_info.latest_block_height'
}

last_block() {
  local height

  height="$(_last_block_value)"
  printf '%s\n' "${height}"
}

_nym_http_first() {
  local path
  local response

  for path in "$@"; do
    if response="$(curl -fsS --max-time 3 \
      -H "Authorization: Bearer ${NYM_HTTP_TOKEN:-local-test-token}" \
      "http://127.0.0.1:${NYM_HTTP_PORT}${path}" 2>/dev/null)"; then
      printf '%s\n' "${response}"
      return 0
    fi
  done
  return 1
}
