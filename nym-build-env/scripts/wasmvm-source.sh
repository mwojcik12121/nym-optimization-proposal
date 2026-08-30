#!/usr/bin/env bash

wasmvm_make_target_exists() {
  local file="${1:?wasmvm Makefile path required}"
  local target="${2:?make target required}"
  local root
  local database

  root="$(cd "$(dirname "${file}")" && pwd)"
  database="$(make -C "${root}" -qp 2>/dev/null || true)"
  awk -F: -v target="${target}" '$1 == target { found=1; exit } END { exit !found }' <<<"${database}"
}

wasmvm_build_target() {
  local file="${1:?wasmvm Makefile path required}"

  if wasmvm_make_target_exists "${file}" build-libwasmvm; then
    printf 'build-libwasmvm\n'
    return 0
  fi

  if wasmvm_make_target_exists "${file}" build-rust; then
    printf 'build-rust\n'
    return 0
  fi

  return 1
}

wasmvm_normalize_outputs() {
  local root="${1:?wasmvm source directory required}"
  local destination="${root}/internal/api"
  local library=""
  local bindings=""

  library="$(find "${root}" -type f -name 'libwasmvm.x86_64.so' -print -quit)"
  bindings="$(find "${root}" -type f -name 'bindings.h' -print -quit)"

  [[ -n "${library}" && -s "${library}" ]] || {
    printf 'libwasmvm.x86_64.so was not produced by the selected wasmvm build target\n' >&2
    return 1
  }
  [[ -n "${bindings}" && -s "${bindings}" ]] || {
    printf 'bindings.h was not found after the wasmvm build\n' >&2
    return 1
  }

  mkdir -p "${destination}"
  if [[ "${library}" != "${destination}/libwasmvm.x86_64.so" ]]; then
    cp "${library}" "${destination}/libwasmvm.x86_64.so"
  fi
  if [[ "${bindings}" != "${destination}/bindings.h" ]]; then
    cp "${bindings}" "${destination}/bindings.h"
  fi
}

go_module_path() {
  local file="${1:?go.mod path required}"
  awk '$1 == "module" && NF >= 2 { print $2; found=1; exit } END { if (!found) exit 1 }' "${file}"
}

nyxd_wasmvm_module() {
  local file="${1:?Nyxd go.mod path required}"

  awk '
    $1 == "require" && $2 == "(" { in_require=1; next }
    in_require && $1 == ")" { in_require=0; next }
    $1 == "require" && $2 ~ /(^|\/)wasmvm(\/v[0-9]+)?$/ { print $2; found=1; exit }
    in_require && $1 ~ /(^|\/)wasmvm(\/v[0-9]+)?$/ { print $1; found=1; exit }
    END { if (!found) exit 1 }
  ' "${file}"
}

sed_pattern_escape() {
  local text="${1:?text required}"
  text="${text//\\/\\\\}"
  text="${text//./\\.}"
  text="${text//[/\\[}"
  text="${text//]/\\]}"
  text="${text//\*/\\*}"
  text="${text//^/\\^}"
  text="${text//\$/\\$}"
  text="${text//|/\\|}"
  printf '%s\n' "${text}"
}

sed_replacement_escape() {
  local text="${1:?text required}"
  text="${text//\\/\\\\}"
  text="${text//&/\\&}"
  text="${text//|/\\|}"
  printf '%s\n' "${text}"
}

adapt_wasmvm_module() {
  local root="${1:?wasmvm source directory required}"
  local declared="${2:?declared wasmvm module required}"
  local target="${3:?target wasmvm module required}"
  local pattern
  local replacement
  local file

  [[ "${declared}" != "${target}" ]] || return 0
  command -v go >/dev/null 2>&1 || {
    printf 'go is required to adapt wasmvm module identity\n' >&2
    return 1
  }

  pattern="$(sed_pattern_escape "${declared}")"
  replacement="$(sed_replacement_escape "${target}")"

  (
    cd "${root}"
    go mod edit -module="${target}"
  )

  while IFS= read -r -d '' file; do
    grep -Fq -- "${declared}" "${file}" || continue
    sed -i "s|${pattern}|${replacement}|g" "${file}"
  done < <(find "${root}" -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.work' \) -print0)
}
