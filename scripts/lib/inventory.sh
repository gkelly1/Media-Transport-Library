#!/usr/bin/env bash
# Per-node SSH inventory from config/nodes.env (source that file first).
#
# Each node has an address, <NODE>_HOST, and optionally its own login,
# <NODE>_USER. A node without one uses LAB_SSH_USER, so a lab where every host
# shares an account needs nothing beyond LAB_SSH_USER. <NODE> is the Kubernetes
# node name upper-cased with '-' as '_' (worker-1 -> WORKER_1).

lab_node_key() { local k="${1^^}"; printf '%s' "${k//-/_}"; }

lab_host_of() { local v; v="$(lab_node_key "$1")_HOST"; printf '%s' "${!v:-}"; }

lab_user_of() { local v; v="$(lab_node_key "$1")_USER"; printf '%s' "${!v:-${LAB_SSH_USER:-}}"; }

# lab_target_of NODE -> user@address, or an error on stderr and a non-zero status.
lab_target_of() {
  local node="$1" key host user
  key="$(lab_node_key "$node")"
  host="$(lab_host_of "$node")"
  user="$(lab_user_of "$node")"
  [[ -n "$host" ]] || { echo "FATAL: no address for $node (${key}_HOST) in config/nodes.env" >&2; return 2; }
  [[ -n "$user" ]] || { echo "FATAL: no login for $node: set ${key}_USER or LAB_SSH_USER in config/nodes.env" >&2; return 2; }
  printf '%s@%s' "$user" "$host"
}

# lab_resolve_node NODE: set NODE, HOST, SSH_USER and TARGET for the node, and
# pick the sudo/SSH mode that node's login needs (needs lib/remote-admin.sh).
# Exits the calling script when the node is not fully configured.
lab_resolve_node() {
  NODE="$1"
  TARGET="$(lab_target_of "$NODE")" || exit 2
  HOST="${TARGET#*@}"
  SSH_USER="${TARGET%%@*}"
  lab_remote_admin_init "$SSH_USER"
}
