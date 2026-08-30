#!/usr/bin/env bash
set -Eeuo pipefail

CHAIN_ID="${CHAIN_ID:-nym-local-200}"
INITIAL_CHAIN_HEIGHT="${INITIAL_CHAIN_HEIGHT:-200}"
BOOTSTRAP_HALT_HEIGHT=$((INITIAL_CHAIN_HEIGHT + 1))
SEED_ROOT="${SEED_ROOT:-/opt/seed}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENOM="unym"
STAKE_DENOM="unyx"

[[ "${INITIAL_CHAIN_HEIGHT}" == 200 ]] || {
  echo "INITIAL_CHAIN_HEIGHT must remain hardcoded to 200" >&2
  exit 1
}

source "${SCRIPT_DIR}/mnemonics.env"

source "${SCRIPT_DIR}/static-node-ids.env"

source "${SCRIPT_DIR}/toml.sh"

recover_validator_key() {
  local node="${1:?node required}"
  local mnemonic_variable="${2:?mnemonic variable required}"
  local home="${SEED_ROOT}/${node}"
  local mnemonic="${!mnemonic_variable}"

  printf '%s\n' "${mnemonic}" | nyxd keys add validator \
    --recover \
    --keyring-backend test \
    --home "${home}" >/dev/null
}

rm -rf "${SEED_ROOT}" /tmp/gentxs
mkdir -p "${SEED_ROOT}" /tmp/gentxs

for number in 1 2 3; do
  node="node0${number}"
  home="${SEED_ROOT}/${node}"
  printf '[nyxd-seed] initialising %s\n' "${node}" >&2
  nyxd init "${node}" --chain-id "${CHAIN_ID}" --home "${home}" >/dev/null
  mkdir -p "${home}/data"
  install -m 600 "${SCRIPT_DIR}/validator-keys/${node}/priv_validator_key.json" \
    "${home}/config/priv_validator_key.json"
  install -m 600 "${SCRIPT_DIR}/validator-keys/${node}/node_key.json" \
    "${home}/config/node_key.json"
  install -m 600 "${SCRIPT_DIR}/validator-keys/${node}/priv_validator_state.json" \
    "${home}/data/priv_validator_state.json"
done

recover_validator_key node01 NODE01_MNEMONIC
recover_validator_key node02 NODE02_MNEMONIC
recover_validator_key node03 NODE03_MNEMONIC

MASTER_HOME="${SEED_ROOT}/node01"
sed -i 's/"stake"/"unyx"/g' "${MASTER_HOME}/config/genesis.json"
jq --arg chain_id "${CHAIN_ID}" '.genesis_time = "2026-01-01T00:00:00Z" | .chain_id = $chain_id' \
  "${MASTER_HOME}/config/genesis.json" > "${MASTER_HOME}/config/genesis.json.tmp"
mv "${MASTER_HOME}/config/genesis.json.tmp" "${MASTER_HOME}/config/genesis.json"

: > "${SEED_ROOT}/cluster.env"
printf 'CHAIN_ID=%s\nINITIAL_CHAIN_HEIGHT=%s\nBOOTSTRAP_HALT_HEIGHT=%s\nDENOM=%s\nSTAKE_DENOM=%s\n' \
  "${CHAIN_ID}" "${INITIAL_CHAIN_HEIGHT}" "${BOOTSTRAP_HALT_HEIGHT}" "${DENOM}" "${STAKE_DENOM}" \
  >> "${SEED_ROOT}/cluster.env"

for number in 1 2 3; do
  node="node0${number}"
  home="${SEED_ROOT}/${node}"
  address="$(nyxd keys show validator -a --keyring-backend test --home "${home}")"
  upper_name="${node^^}"
  printf '%s_ADDRESS=%s\n' "${upper_name}" "${address}" >> "${SEED_ROOT}/cluster.env"
  nyxd genesis add-genesis-account "${address}" \
    "1000000000000000${DENOM},1000000000000000${STAKE_DENOM}" \
    --home "${MASTER_HOME}" >/dev/null
done

for number in 1 2 3; do
  node="node0${number}"
  home="${SEED_ROOT}/${node}"
  if [[ "${home}" != "${MASTER_HOME}" ]]; then
    cp "${MASTER_HOME}/config/genesis.json" "${home}/config/genesis.json"
  fi
  rm -rf "${home}/config/gentx"
  mkdir -p "${home}/config/gentx"
  nyxd genesis gentx validator "100000000000${STAKE_DENOM}" \
    --chain-id "${CHAIN_ID}" \
    --keyring-backend test \
    --home "${home}" >/dev/null
  gentx="$(find "${home}/config/gentx" -maxdepth 1 -type f -name '*.json' -print -quit)"
  test -n "${gentx}"
  cp "${gentx}" "/tmp/gentxs/${node}.json"
done

rm -rf "${MASTER_HOME}/config/gentx"
mkdir -p "${MASTER_HOME}/config/gentx"
cp /tmp/gentxs/*.json "${MASTER_HOME}/config/gentx/"
nyxd genesis collect-gentxs --home "${MASTER_HOME}" >/dev/null
nyxd genesis validate-genesis --home "${MASTER_HOME}" >/dev/null

for number in 1 2 3; do
  node="node0${number}"
  home="${SEED_ROOT}/${node}"
  if [[ "${home}" != "${MASTER_HOME}" ]]; then
    cp "${MASTER_HOME}/config/genesis.json" "${home}/config/genesis.json"
  fi

  case "${node}" in
    node01) peers="${NODE02_NODE_ID}@node02:26656,${NODE03_NODE_ID}@node03:26656" ;;
    node02) peers="${NODE01_NODE_ID}@node01:26656,${NODE03_NODE_ID}@node03:26656" ;;
    node03) peers="${NODE01_NODE_ID}@node01:26656,${NODE02_NODE_ID}@node02:26656" ;;
  esac

  config="${home}/config/config.toml"
  app="${home}/config/app.toml"
  toml_set "${config}" rpc laddr '"tcp://0.0.0.0:26657"'
  toml_set "${config}" rpc cors_allowed_origins '["*"]'
  toml_set "${config}" p2p laddr '"tcp://0.0.0.0:26656"'
  toml_set "${config}" p2p persistent_peers "\"${peers}\""
  toml_set "${config}" p2p pex false
  toml_set "${config}" p2p addr_book_strict false
  toml_set "${config}" consensus timeout_propose '"500ms"'
  toml_set "${config}" consensus timeout_propose_delta '"100ms"'
  toml_set "${config}" consensus timeout_prevote '"100ms"'
  toml_set "${config}" consensus timeout_prevote_delta '"50ms"'
  toml_set "${config}" consensus timeout_precommit '"100ms"'
  toml_set "${config}" consensus timeout_precommit_delta '"50ms"'
  toml_set "${config}" consensus timeout_commit '"250ms"'
  toml_set "${config}" consensus create_empty_blocks true
  toml_set "${config}" consensus create_empty_blocks_interval '"0s"'

  toml_set "${app}" "" minimum-gas-prices '"0unym"'
  toml_set "${app}" "" pruning '"nothing"'
  toml_set "${app}" "" halt-height "${BOOTSTRAP_HALT_HEIGHT}"
  toml_set "${app}" "" min-retain-blocks 0
  toml_set "${app}" api enable true
  toml_set "${app}" api address '"tcp://0.0.0.0:1317"'
  toml_set "${app}" grpc enable true
  toml_set "${app}" grpc address '"0.0.0.0:9090"'
done

printf 'NODE01_NODE_ID=%s\nNODE02_NODE_ID=%s\nNODE03_NODE_ID=%s\n' \
  "${NODE01_NODE_ID}" "${NODE02_NODE_ID}" "${NODE03_NODE_ID}" >> "${SEED_ROOT}/cluster.env"
sha256sum "${MASTER_HOME}/config/genesis.json" | \
  awk '{print "GENESIS_SHA256=" $1}' >> "${SEED_ROOT}/cluster.env"
chmod 600 "${SEED_ROOT}/node0"*/config/*key*.json \
  "${SEED_ROOT}/node0"*/data/priv_validator_state.json
chmod 644 "${SEED_ROOT}/cluster.env" "${SEED_ROOT}/node0"*/config/genesis.json
printf '[nyxd-seed] configuration ready for %s; block %s will commit, then configured halt-height %s will reject the next block\n' "${CHAIN_ID}" "${INITIAL_CHAIN_HEIGHT}" "${BOOTSTRAP_HALT_HEIGHT}" >&2
