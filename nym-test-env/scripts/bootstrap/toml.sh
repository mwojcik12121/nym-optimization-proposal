#!/usr/bin/env bash

toml_set() {
  local file="${1:?TOML file required}"
  local section="${2-}"
  local key="${3:?TOML key required}"
  local value="${4:?TOML value required}"
  local temporary="${file}.tmp.$$"

  awk -v wanted_section="${section}" -v wanted_key="${key}" -v wanted_value="${value}" '
    BEGIN {
      current_section = ""
      section_seen = (wanted_section == "")
      key_written = 0
    }

    {
      line = $0
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)

      if (trimmed ~ /^\[[^][]+\][[:space:]]*$/) {
        if (current_section == wanted_section && section_seen && !key_written) {
          print wanted_key " = " wanted_value
          key_written = 1
        }

        current_section = trimmed
        sub(/^\[/, "", current_section)
        sub(/\][[:space:]]*$/, "", current_section)
        if (current_section == wanted_section) {
          section_seen = 1
        }
      }

      if (current_section == wanted_section && !key_written) {
        candidate = trimmed
        equals = index(candidate, "=")
        if (equals > 0) {
          candidate = substr(candidate, 1, equals - 1)
          gsub(/[[:space:]]/, "", candidate)
          if (candidate == wanted_key) {
            print wanted_key " = " wanted_value
            key_written = 1
            next
          }
        }
      }

      print line
    }

    END {
      if (!key_written) {
        if (!section_seen) {
          print ""
          print "[" wanted_section "]"
        }
        print wanted_key " = " wanted_value
      }
    }
  ' "${file}" > "${temporary}"

  mv "${temporary}" "${file}"
}

nyxd_prepare_live_restart() {
  local home="${1:?Nyxd home required}"
  local target="${INITIAL_CHAIN_HEIGHT:-200}"
  local signer_state="${home}/data/priv_validator_state.json"
  local rollback_log="${home}/data/bootstrap-rollback.log"
  local nyxd_bin="${NYXD_BIN:-nyxd}"

  [[ "${target}" == 200 ]] || return 1

  if ! "${nyxd_bin}" rollback --hard --home "${home}" >"${rollback_log}" 2>&1; then
    return 1
  fi

  toml_set "${home}/config/app.toml" "" "halt-height" "0"
  toml_set "${home}/config/config.toml" "consensus" "create_empty_blocks" "true"
  toml_set "${home}/config/config.toml" "consensus" "create_empty_blocks_interval" '"0s"'
  
  rm -rf "${home}/data/cs.wal"
  printf '{"height":"%s","round":0,"step":0}\n' "${target}" > "${signer_state}"
  chmod 600 "${signer_state}"
}
