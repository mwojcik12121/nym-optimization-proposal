#!/usr/bin/env bash
set -Eeuo pipefail

NYM_ROOT="${1:?Nym source root required}"
OUTPUT_DIR="${2:?output directory required}"
BUILD_JOBS="${3:-1}"

contract_die() {
  printf '[mixnet-contract] ERROR: %s\n' "$*" >&2
  exit 1
}

cargo_package_name() {
  local manifest="${1:?Cargo manifest required}"

  awk '
    /^\[package\][[:space:]]*$/ { in_package = 1; next }
    /^\[/ && in_package { exit }
    in_package && /^[[:space:]]*name[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      gsub(/^"|"[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "${manifest}"
}


cargo_lib_name() {
  local manifest="${1:?Cargo manifest required}"
  local lib_name
  local package

  lib_name="$(awk '
    /^\[lib\][[:space:]]*$/ { in_lib = 1; next }
    /^\[/ && in_lib { exit }
    in_lib && /^[[:space:]]*name[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      gsub(/^"|"[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "${manifest}")"

  if [[ -n "${lib_name}" ]]; then
    printf '%s\n' "${lib_name}"
    return 0
  fi

  package="$(cargo_package_name "${manifest}")"
  printf '%s\n' "${package//-/_}"
}

manifest_is_deployable_contract() {
  local manifest="${1:?Cargo manifest required}"
  local directory

  directory="$(dirname "${manifest}")"

  if awk '
      /^\[lib\][[:space:]]*$/ { in_lib = 1; next }
      /^\[/ && in_lib { exit }
      in_lib && /crate-type[[:space:]]*=/ && /cdylib/ { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "${manifest}"; then
    return 0
  fi

  grep -RqsE '#\[[[:space:]]*entry_point[[:space:]]*\]|cosmwasm_std::entry_point|entry_point[[:space:]]*\(' \
    "${directory}/src" 2>/dev/null
}

find_mixnet_manifest() {
  local candidate
  local package

  for candidate in \
    "${NYM_ROOT}/contracts/mixnet/Cargo.toml" \
    "${NYM_ROOT}/contracts/mixnet-contract/Cargo.toml"; do
    if [[ -f "${candidate}" ]]; then
      package="$(cargo_package_name "${candidate}")"
      if [[ "${package}" == *mixnet*contract* ]] && manifest_is_deployable_contract "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  while IFS= read -r -d '' candidate; do
    package="$(cargo_package_name "${candidate}")"
    if [[ "${package}" == *mixnet*contract* ]] && manifest_is_deployable_contract "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name Cargo.toml -type f -print0
  )

  return 1
}

rust_struct_body() {
  local source="${1:?Rust source required}"
  local name="${2:?struct name required}"

  awk -v wanted="${name}" '
    $0 ~ "pub[[:space:]]+struct[[:space:]]+" wanted "[[:space:]]*\\{" {
      active = 1
    }
    active {
      print
      if ($0 ~ /^[[:space:]]*}[[:space:]]*$/) {
        exit
      }
    }
  ' "${source}"
}

find_instantiate_source() {
  local source
  local body

  while IFS= read -r -d '' source; do
    grep -Eq 'pub[[:space:]]+struct[[:space:]]+InstantiateMsg' "${source}" \
      || continue
    body="$(rust_struct_body "${source}" InstantiateMsg)"
    if [[ "${body}" == *rewarding_validator_address* \
       && "${body}" == *initial_rewarding_params* ]]; then
      printf '%s\n' "${source}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name '*.rs' -type f -print0
  )

  return 1
}

find_rewarding_source() {
  local source
  local body

  while IFS= read -r -d '' source; do
    grep -Eq 'pub[[:space:]]+struct[[:space:]]+InitialRewardingParams' "${source}" \
      || continue
    body="$(rust_struct_body "${source}" InitialRewardingParams)"
    if [[ "${body}" == *initial_reward_pool* \
       && "${body}" == *initial_staking_supply* ]]; then
      printf '%s\n' "${source}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name '*.rs' -type f -print0
  )

  return 1
}

rust_field_type() {
  local body="${1:?struct body required}"
  local field="${2:?field name required}"

  sed -nE \
    "s/^[[:space:]]*pub[[:space:]]+${field}[[:space:]]*:[[:space:]]*([^,]+),?.*$/\\1/p" \
    <<<"${body}" | head -n 1
}

find_struct_source() {
  local name="${1:?struct name required}"
  local source

  while IFS= read -r -d '' source; do
    if grep -Eq "pub[[:space:]]+struct[[:space:]]+${name}[[:space:]]*\\{" "${source}"; then
      printf '%s\n' "${source}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name '*.rs' -type f -print0
  )

  return 1
}

rust_public_fields() {
  local body="${1:?struct body required}"

  sed -nE \
    's/^[[:space:]]*pub[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*$/\1/p' \
    <<<"${body}"
}

rust_field_has_serde_default() {
  local body="${1:?struct body required}"
  local field="${2:?field name required}"

  awk -v wanted="${field}" '
    /^[[:space:]]*#\[serde/ {
      in_serde = 1
      if ($0 ~ /default/) {
        defaulted = 1
      }
      if ($0 ~ /\]/) {
        in_serde = 0
      }
      next
    }
    in_serde {
      if ($0 ~ /default/) {
        defaulted = 1
      }
      if ($0 ~ /\]/) {
        in_serde = 0
      }
      next
    }
    /^[[:space:]]*#\[/ {
      next
    }
    /^[[:space:]]*pub[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      name = $0
      sub(/^[[:space:]]*pub[[:space:]]+/, "", name)
      sub(/[[:space:]]*:.*$/, "", name)
      if (name == wanted) {
        found = defaulted
        exit
      }
      defaulted = 0
      next
    }
    /^[[:space:]]*$/ {
      next
    }
    {
      defaulted = 0
      in_serde = 0
    }
    END {
      exit(found ? 0 : 1)
    }
  ' <<<"${body}"
}

write_rewarded_set_json() {
  local rewarding_body="${1:?rewarding struct body required}"
  local destination="${2:?destination required}"
  local type
  local name
  local source
  local body
  local field
  local value
  local separator=""

  type="$(rust_field_type "${rewarding_body}" rewarded_set_params)"
  type="${type##*::}"
  type="${type//[[:space:]]/}"
  type="${type#Option<}"
  type="${type%>}"
  [[ -n "${type}" ]] || contract_die 'could not determine rewarded_set_params type'

  source="$(find_struct_source "${type}" || true)"
  [[ -n "${source}" ]] \
    || contract_die "could not locate Rust definition for ${type}"
  body="$(rust_struct_body "${source}" "${type}")"

  printf '{' > "${destination}"
  while IFS= read -r field; do
    case "${field}" in
      mixnodes|active_mixnodes)
        value=3
        ;;
      entry_gateways|entry_gateways_count)
        value=1
        ;;
      exit_gateways|exit_gateways_count)
        value=1
        ;;
      gateways)
        value=2
        ;;
      standby|standby_nodes)
        value=0
        ;;
      active_set_size)
        value=5
        ;;
      rewarded_set_size)
        value=5
        ;;
      *)
        contract_die "unsupported ${type} field: ${field}"
        ;;
    esac
    printf '%s"%s":%s' "${separator}" "${field}" "${value}" >> "${destination}"
    separator=","
  done < <(rust_public_fields "${body}")
  printf '}\n' >> "${destination}"
}

write_instantiate_template() {
  local destination="${1:?destination required}"
  local instantiate_source
  local rewarding_source
  local instantiate_body
  local rewarding_body
  local duration_json
  local version_line=""
  local rewarding_tail
  local rewarded_file
  local field
  local type

  instantiate_source="$(find_instantiate_source || true)"
  rewarding_source="$(find_rewarding_source || true)"
  [[ -n "${instantiate_source}" ]] \
    || contract_die 'could not locate the mixnet InstantiateMsg definition'
  [[ -n "${rewarding_source}" ]] \
    || contract_die 'could not locate InitialRewardingParams'

  instantiate_body="$(rust_struct_body "${instantiate_source}" InstantiateMsg)"
  rewarding_body="$(rust_struct_body "${rewarding_source}" InitialRewardingParams)"

  for field in rewarding_validator_address vesting_contract_address rewarding_denom epochs_in_interval epoch_duration initial_rewarding_params; do
    [[ "${instantiate_body}" == *"pub ${field}"* ]] \
      || contract_die "unsupported InstantiateMsg: missing ${field}"
  done

  while IFS= read -r field; do
    case "${field}" in
      rewarding_validator_address|vesting_contract_address|node_families_contract_address|rewarding_denom|epochs_in_interval|epoch_duration|initial_rewarding_params|current_nym_node_version)
        ;;
      *)
        type="$(rust_field_type "${instantiate_body}" "${field}")"
        if [[ "${type}" != *Option* ]] \
          && ! rust_field_has_serde_default "${instantiate_body}" "${field}"; then
          contract_die "unsupported required InstantiateMsg field: ${field}"
        fi
        ;;
    esac
  done < <(rust_public_fields "${instantiate_body}")

  if grep -Eq 'std::time::Duration|time::Duration' "${instantiate_source}"; then
    duration_json='{"secs":60,"nanos":0}'
  else
    duration_json='{"time":60}'
  fi

  if [[ "${instantiate_body}" == *"pub current_nym_node_version"* ]]; then
    version_line=',"current_nym_node_version":"1.0.0"'
  fi

  if [[ "${rewarding_body}" == *"pub rewarded_set_params"* ]]; then
    rewarded_file="$(mktemp)"
    write_rewarded_set_json "${rewarding_body}" "${rewarded_file}"
    rewarding_tail="\"rewarded_set_params\":$(cat "${rewarded_file}")"
    rm -f "${rewarded_file}"
  elif [[ "${rewarding_body}" == *"pub rewarded_set_size"* \
      && "${rewarding_body}" == *"pub active_set_size"* ]]; then
    rewarding_tail='"rewarded_set_size":5,"active_set_size":5'
  else
    contract_die 'unsupported InitialRewardingParams rewarded-set layout'
  fi

  for field in initial_reward_pool initial_staking_supply staking_supply_scale_factor sybil_resistance active_set_work_factor interval_pool_emission; do
    [[ "${rewarding_body}" == *"pub ${field}"* ]] \
      || contract_die "unsupported InitialRewardingParams: missing ${field}"
  done

  cat > "${destination}" <<EOF
{
  "rewarding_validator_address": "__REWARDING_VALIDATOR_ADDRESS__",
  "vesting_contract_address": "__VESTING_CONTRACT_ADDRESS__",
  "node_families_contract_address": "__NODE_FAMILIES_CONTRACT_ADDRESS__",
  "rewarding_denom": "unym",
  "epochs_in_interval": 720,
  "epoch_duration": ${duration_json},
  "initial_rewarding_params": {
    "initial_reward_pool": "1000000000000000",
    "initial_staking_supply": "1000000000000000",
    "staking_supply_scale_factor": "0.5",
    "sybil_resistance": "0.3",
    "active_set_work_factor": "10",
    "interval_pool_emission": "0.02",
    ${rewarding_tail}
  }${version_line}
}
EOF
}

write_contract_environment_names() {
  local destination="${1:?destination required}"
  local temporary="${destination}.tmp"

  {
    printf '%s\n' \
      NYM_MIXNET_CONTRACT_ADDRESS \
      MIXNET_CONTRACT_ADDRESS
    grep -RhoE \
      '(NYM_)?[A-Z][A-Z0-9_]*MIXNET[A-Z0-9_]*CONTRACT[A-Z0-9_]*ADDRESS' \
      "${NYM_ROOT}" \
      --include='*.rs' --include='*.sh' --include='*.toml' \
      2>/dev/null || true
  } | LC_ALL=C sort -u > "${temporary}"

  mv "${temporary}" "${destination}"
}

export_contract_schema() {
  local manifest="${1:?Cargo manifest required}"
  local destination="${2:?schema destination required}"
  local contract_dir
  local example_source=""
  local example_name=""
  local candidate
  local generated=""

  contract_dir="$(dirname "${manifest}")"

  if [[ -f "${contract_dir}/examples/schema.rs" ]]; then
    example_source="${contract_dir}/examples/schema.rs"
  else
    while IFS= read -r -d '' candidate; do
      if grep -Eq 'write_api|export_schema|schema_for' "${candidate}" \
         && grep -Eq 'InstantiateMsg|instantiate' "${candidate}"; then
        example_source="${candidate}"
        break
      fi
    done < <(
      find "${contract_dir}/examples" \
        -maxdepth 1 -type f -name '*.rs' -print0 2>/dev/null
    )
  fi

  [[ -n "${example_source}" ]] \
    || contract_die 'mixnet contract does not provide a schema example'

  example_name="$(basename "${example_source}" .rs)"
  rm -rf "${contract_dir}/schema"

  (
    cd "${contract_dir}"
    CARGO_TARGET_DIR="${NYM_ROOT}/target" \
      cargo run \
        --release \
        --locked \
        --jobs "${BUILD_JOBS}" \
        --example "${example_name}"
  )

  generated="$(
    find "${contract_dir}/schema" \
      -type f -name '*.json' -size +0c -print -quit 2>/dev/null
  )"
  [[ -n "${generated}" ]] \
    || contract_die 'schema example produced no JSON schema files'

  mkdir -p "${destination}"
  cp -a "${contract_dir}/schema/." "${destination}/"
  find "${destination}" -type f -name '*.json' \
    -printf '%P\n' | LC_ALL=C sort > "${destination}/manifest.txt"
}

find_node_families_manifest() {
  local candidate
  local package

  for candidate in \
    "${NYM_ROOT}/contracts/node-families/Cargo.toml" \
    "${NYM_ROOT}/contracts/node-families-contract/Cargo.toml"; do
    if [[ -f "${candidate}" ]]; then
      package="$(cargo_package_name "${candidate}")"
      if [[ "${package}" == *node*famil* ]] && manifest_is_deployable_contract "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  while IFS= read -r -d '' candidate; do
    package="$(cargo_package_name "${candidate}")"
    if [[ "${package}" == *node*famil* ]] && manifest_is_deployable_contract "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name Cargo.toml -type f -print0
  )

  return 1
}

find_scoped_struct_source() {
  local name="${1:?struct name required}"
  local anchor="${2:?anchor source required}"
  local scope
  local source

  scope="$(dirname "${anchor}")"
  while [[ "${scope}" != "${NYM_ROOT}" && "${scope}" != / ]]; do
    if [[ -f "${scope}/Cargo.toml" ]]; then
      break
    fi
    scope="$(dirname "${scope}")"
  done

  if [[ -d "${scope}" ]]; then
    while IFS= read -r -d '' source; do
      if grep -Eq "pub[[:space:]]+struct[[:space:]]+${name}[[:space:]]*\\{" "${source}"; then
        printf '%s\n' "${source}"
        return 0
      fi
    done < <(
      find "${scope}" \
        -path '*/target' -prune -o \
        -name '*.rs' -type f -print0
    )
  fi

  find_struct_source "${name}"
}

node_families_message_has_mixnet_address() {
  local body="${1:?struct body required}"
  local source="${2:?source required}"
  local config_type
  local config_name
  local config_source
  local config_body

  [[ "${body}" == *mixnet_contract_address* ]] && return 0

  config_type="$(rust_field_type "${body}" config)"
  [[ -n "${config_type}" ]] || return 1
  config_name="${config_type//[[:space:]]/}"
  config_name="${config_name##*::}"
  config_name="${config_name#&}"

  config_source="$(find_scoped_struct_source "${config_name}" "${source}" || true)"
  [[ -n "${config_source}" ]] || return 1
  config_body="$(rust_struct_body "${config_source}" "${config_name}")"
  [[ "${config_body}" == *mixnet_contract_address* ]]
}

find_node_families_instantiate_source() {
  local source
  local body

  while IFS= read -r -d '' source; do
    grep -Eq 'pub[[:space:]]+struct[[:space:]]+InstantiateMsg' "${source}" || continue
    body="$(rust_struct_body "${source}" InstantiateMsg)"
    [[ "${body}" == *initial_rewarding_params* ]] && continue
    if node_families_message_has_mixnet_address "${body}" "${source}"; then
      printf '%s\n' "${source}"
      return 0
    fi
  done < <(
    find "${NYM_ROOT}" \
      -path '*/target' -prune -o \
      -path '*/.git' -prune -o \
      -name '*.rs' -type f -print0
  )

  return 1
}

node_families_struct_json() {
  local struct_name="${1:?struct name required}"
  local source="${2:?source required}"
  local depth="${3:-0}"
  local struct_source
  local body
  local field
  local type
  local value
  local separator=""

  (( depth <= 8 )) || return 1
  struct_source="$(find_scoped_struct_source "${struct_name}" "${source}" || true)"
  [[ -n "${struct_source}" ]] || return 1
  body="$(rust_struct_body "${struct_source}" "${struct_name}")"
  [[ -n "${body}" ]] || return 1

  printf '{'
  while IFS= read -r field; do
    type="$(rust_field_type "${body}" "${field}")"
    if ! value="$(node_families_field_json "${field}" "${type}" "${struct_source}" "$((depth + 1))")"; then
      return 1
    fi
    printf '%s"%s":%s' "${separator}" "${field}" "${value}"
    separator=","
  done < <(rust_public_fields "${body}")
  printf '}'
}

node_families_field_json() {
  local field="${1:?field required}"
  local type="${2:?type required}"
  local source="${3:?source required}"
  local depth="${4:-0}"
  local compact="${type//[[:space:]]/}"
  local named_type

  case "${field}" in
    mixnet_contract_address)
      printf '"__MIXNET_CONTRACT_ADDRESS__"\n'
      return 0
      ;;
    admin|contract_admin|owner|owner_address|admin_address)
      printf '"__OWNER_ADDRESS__"\n'
      return 0
      ;;
    *denom*)
      printf '"unym"\n'
      return 0
      ;;
  esac

  if [[ "${compact}" == Option\<* ]]; then
    printf 'null\n'
  elif [[ "${compact}" == *Coin* || "${field}" == *fee* || "${field}" == *deposit* ]]; then
    printf '{"denom":"unym","amount":"1"}\n'
  elif [[ "${compact}" == *Duration* ]]; then
    printf '{"time":60}\n'
  elif [[ "${compact}" == *Decimal* || "${compact}" == *Percent* ]]; then
    printf '"0.01"\n'
  elif [[ "${compact}" == Vec\<* || "${compact}" == \[* ]]; then
    printf '[]\n'
  elif [[ "${compact}" == bool ]]; then
    printf 'false\n'
  elif [[ "${compact}" =~ ^(u|i)(8|16|32|64|128|size)$ || "${compact}" == *Uint64* || "${compact}" == *Uint128* ]]; then
    printf '1\n'
  elif [[ "${field}" == *max* || "${field}" == *min* || "${field}" == *limit* || "${field}" == *size* || "${field}" == *length* ]]; then
    printf '1\n'
  elif [[ "${compact}" == String || "${compact}" == *Addr* ]]; then
    if [[ "${field}" == *address* || "${field}" == *admin* || "${field}" == *owner* ]]; then
      printf '"__OWNER_ADDRESS__"\n'
    else
      printf '"local"\n'
    fi
  else
    named_type="${compact##*::}"
    named_type="${named_type#&}"
    node_families_struct_json "${named_type}" "${source}" "${depth}"
  fi
}

write_node_families_template() {
  local destination="${1:?destination required}"
  local source
  local body
  local field
  local type
  local value
  local separator=""

  source="$(find_node_families_instantiate_source || true)"
  [[ -n "${source}" ]] || contract_die 'could not locate node-families InstantiateMsg'
  body="$(rust_struct_body "${source}" InstantiateMsg)"
  node_families_message_has_mixnet_address "${body}" "${source}" \
    || contract_die 'node-families InstantiateMsg does not expose mixnet_contract_address directly or through nested config'

  printf '{' > "${destination}"
  while IFS= read -r field; do
    type="$(rust_field_type "${body}" "${field}")"
    if ! value="$(node_families_field_json "${field}" "${type}" "${source}" 0)"; then
      contract_die "unsupported required node-families InstantiateMsg field: ${field} (${type})"
    fi
    printf '%s"%s":%s' "${separator}" "${field}" "${value}" >> "${destination}"
    separator=","
  done < <(rust_public_fields "${body}")
  printf '}\n' >> "${destination}"
}

compile_contract_wasm() {
  local manifest="${1:?manifest required}"
  local destination="${2:?destination required}"
  local package
  local lib_name
  local artifact_name
  local artifact

  package="$(cargo_package_name "${manifest}")"
  [[ -n "${package}" ]] || contract_die "could not read package name from ${manifest}"
  manifest_is_deployable_contract "${manifest}" \
    || contract_die "${package} is not a deployable CosmWasm contract crate"
  lib_name="$(cargo_lib_name "${manifest}")"
  [[ -n "${lib_name}" ]] || contract_die "could not determine library name for ${package}"

  CARGO_TARGET_DIR="${NYM_ROOT}/target" \
    RUSTFLAGS='-C link-arg=-s' \
    cargo build \
      --release \
      --locked \
      --target wasm32-unknown-unknown \
      --jobs "${BUILD_JOBS}" \
      --manifest-path "${manifest}"

  artifact_name="${lib_name}.wasm"
  artifact="${NYM_ROOT}/target/wasm32-unknown-unknown/release/${artifact_name}"
  [[ -s "${artifact}" ]] || contract_die "${package} build did not produce deployable artifact ${artifact_name}"

  command -v wasm-opt >/dev/null 2>&1 \
    || contract_die 'wasm-opt is required to produce deployable contracts'
  wasm-opt --signext-lowering -Os "${artifact}" -o "${destination}"

  [[ "$(od -An -tx1 -N4 "${destination}" | tr -d ' \n')" == 0061736d ]] \
    || contract_die "${package} output does not contain a WebAssembly header"
}

main() {
  local mixnet_manifest
  local node_families_manifest
  local mixnet_package
  local node_families_package

  [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] \
    || contract_die 'build jobs must be a positive integer'

  mixnet_manifest="$(find_mixnet_manifest || true)"
  node_families_manifest="$(find_node_families_manifest || true)"
  [[ -n "${mixnet_manifest}" ]] || contract_die 'could not locate the Nym mixnet contract Cargo package'
  [[ -n "${node_families_manifest}" ]] || contract_die 'could not locate the Nym node-families contract Cargo package'

  mixnet_package="$(cargo_package_name "${mixnet_manifest}")"
  node_families_package="$(cargo_package_name "${node_families_manifest}")"
  printf '[nym-contracts] mixnet=%s node-families=%s\n' "${mixnet_package}" "${node_families_package}" >&2

  rustup target add wasm32-unknown-unknown
  mkdir -p "${OUTPUT_DIR}"
  compile_contract_wasm "${node_families_manifest}" "${OUTPUT_DIR}/node_families_contract.wasm"
  compile_contract_wasm "${mixnet_manifest}" "${OUTPUT_DIR}/mixnet_contract.wasm"

  write_node_families_template "${OUTPUT_DIR}/node_families_instantiate_template.json"
  write_instantiate_template "${OUTPUT_DIR}/mixnet_instantiate_template.json"
  write_contract_environment_names "${OUTPUT_DIR}/mixnet_contract_env_names"
  printf '%s\n' \
    NYM_NODE_FAMILIES_CONTRACT_ADDRESS \
    NODE_FAMILIES_CONTRACT_ADDRESS \
    NYM_NETWORK_DEFAULTS__NODE_FAMILIES_CONTRACT_ADDRESS \
    >> "${OUTPUT_DIR}/mixnet_contract_env_names"
  LC_ALL=C sort -u -o "${OUTPUT_DIR}/mixnet_contract_env_names" "${OUTPUT_DIR}/mixnet_contract_env_names"

  printf 'mixnet_package=%s\nnode_families_package=%s\n' \
    "${mixnet_package}" "${node_families_package}" \
    > "${OUTPUT_DIR}/mixnet_contract.env"

  printf '[nym-contracts] exported mixnet and node-families Wasm artifacts\n' >&2
}

main "$@"
