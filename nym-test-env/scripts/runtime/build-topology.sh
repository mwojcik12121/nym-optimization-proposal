#!/usr/bin/env bash
set -Eeuo pipefail

SHARED_DIR="${1:-}"
: "${SHARED_DIR:?usage: build-topology.sh SHARED_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source /opt/nym/controls/info.sh

read_public_key() {
  local details="${1:?details file required}"
  local kind="${2:?key kind required}"
  local value=""

  case "${kind}" in
    identity)
      value="$(jq -r '.ed25519_identity_key // .identity_key // empty' "${details}")"
      ;;
    sphinx)
      value="$(jq -r '.x25519_primary_sphinx_key.public_key // .x25519_primary_sphinx_key // .sphinx_key // empty' "${details}")"
      ;;
    *)
      nym_abort topology "unknown key kind: ${kind}"
      ;;
  esac

  [[ -n "${value}" && "${value}" != null ]] \
    || nym_abort topology "missing ${kind} key in ${details}"
  printf '%s\n' "${value}"
}

build_node_json() {
  local node="${1:?node required}"
  local node_id="${2:?node ID required}"
  local host="${3:?host required}"
  local mix_port="${4:?mix port required}"
  local entry_port="${5:?entry port required}"
  local role="${6:?role required}"
  local layer="${7:?layer required}"
  local supports_entry="${8:?entry flag required}"
  local supports_exit_nr="${9:?network requester flag required}"
  local supports_exit_ipr="${10:?IP packet router flag required}"
  local details="${SHARED_DIR}/details/${node}.json"
  local identity_key
  local sphinx_key
  local epoch_role
  local entry_json=null

  [[ -s "${details}" ]] || nym_abort topology "missing details file: ${details}"

  identity_key="$(read_public_key "${details}" identity)"
  sphinx_key="$(read_public_key "${details}" sphinx)"

  case "${role}" in
    mixnode)
      epoch_role="$(jq -cn --argjson layer "${layer}" '{Mixnode:{layer:$layer}}')"
      ;;
    entry)
      epoch_role='"EntryGateway"'
      ;;
    exit)
      epoch_role='"ExitGateway"'
      ;;
    *)
      nym_abort topology "unsupported epoch role: ${role}"
      ;;
  esac

  if [[ "${supports_entry}" == true ]]; then
    entry_json="$(jq -cn \
      --argjson ws_port "${entry_port}" \
      '{hostname:null,ws_port:$ws_port,wss_port:null}')"
  fi

  jq -cn \
    --argjson node_id "${node_id}" \
    --arg host "${host}" \
    --argjson mix_port "${mix_port}" \
    --arg identity_key "${identity_key}" \
    --arg sphinx_key "${sphinx_key}" \
    --argjson epoch_role "${epoch_role}" \
    --argjson supports_entry "${supports_entry}" \
    --argjson supports_exit_nr "${supports_exit_nr}" \
    --argjson supports_exit_ipr "${supports_exit_ipr}" \
    --argjson entry "${entry_json}" \
    '{
      basic:{
        node_id:$node_id,
        ed25519_identity_pubkey:$identity_key,
        ip_addresses:[$host],
        mix_port:$mix_port,
        x25519_sphinx_pubkey:$sphinx_key,
        epoch_role:$epoch_role,
        supported_roles:{
          mixnode:($epoch_role | type == "object"),
          entry:$supports_entry,
          exit_nr:$supports_exit_nr,
          exit_ipr:$supports_exit_ipr
        },
        entry:$entry,
        performance:"1"
      },
      entry:$entry
    }'
}

node04="$(build_node_json node04 1 172.31.0.21 10004 null mixnode 1 false false false)"
node05="$(build_node_json node05 2 172.31.0.22 10005 null mixnode 2 false false false)"
node06="$(build_node_json node06 3 172.31.0.23 10006 null mixnode 3 false false false)"
node07="$(build_node_json node07 4 172.31.0.24 10007 9007 entry 0 true false false)"
node08="$(build_node_json node08 5 172.31.0.25 10008 9008 exit 0 true true true)"

target="${SHARED_DIR}/network.json"
temporary="${target}.tmp.$$"

jq -n \
  --arg refreshed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson node04 "${node04}" \
  --argjson node05 "${node05}" \
  --argjson node06 "${node06}" \
  --argjson node07 "${node07}" \
  --argjson node08 "${node08}" \
  '{
    metadata:{absolute_epoch_id:0,rotation_id:0,refreshed_at:$refreshed_at},
    nodes:{
      pagination:{total:5,page:0,size:5},
      data:[$node04,$node05,$node06,$node07,$node08]
    },
    rewarded_set:{
      epoch_id:0,
      entry_gateways:[4,5],
      exit_gateways:[5],
      layer1:[1],
      layer2:[2],
      layer3:[3],
      standby:[]
    }
  }' > "${temporary}"

rewarded_target="${SHARED_DIR}/rewarded-set.json"
rewarded_temporary="${rewarded_target}.tmp.$$"
jq -c '.rewarded_set' "${temporary}" > "${rewarded_temporary}"

mv "${temporary}" "${target}"
mv "${rewarded_temporary}" "${rewarded_target}"
