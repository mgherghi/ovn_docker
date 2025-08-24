#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date +'%F %T')] $*"; }

# ---------- Required env ----------
: "${NODE_NAME:?}"; : "${ROLE:?}"; : "${PHYS_BR:?}"; : "${BOND_PORT:?}"
: "${MGMT_IFACE:?}"; : "${MGMT_CIDR:?}"; : "${MGMT_IP:?}"
: "${LINSTOR_IFACE:?}"; : "${LINSTOR_CIDR:?}"
: "${NB_REMOTES:?}"; : "${SB_REMOTES:?}"; : "${ENCAP_TYPE:?}"; : "${ENCAP_IP:?}"
: "${PHYSNET_NAME:?}"; : "${ALLOWED_VLANS:?}"

SYS_ID_FILE="/var/lib/openvswitch/system-id.conf"
OVS_DB_DIR="/var/lib/openvswitch"
OVN_DB_DIR="/var/lib/ovn"

mkdir -p "$OVS_DB_DIR" "$OVN_DB_DIR" /var/log/openvswitch /var/log/ovn /var/run/openvswitch /var/run/ovn

# ---------- Clean stale PIDs/locks ----------
for d in /var/run/openvswitch /var/run/ovn; do
  find "$d" -maxdepth 1 -type f -name "*.pid" -delete || true
  find "$d" -maxdepth 1 -type f -name "*.lock" -delete || true
done

# ---------- Host module sanity ----------
if [[ ! -d /sys/module/openvswitch ]]; then
  log "ERROR: host openvswitch module not loaded. Run scripts/host-prep.sh"
  exit 1
fi
if [[ ! -d /sys/module/geneve ]]; then
  log "WARN: host geneve module not loaded; encapsulation may fail."
fi

# ---------- Start OVS ----------
if [[ ! -f /etc/openvswitch/conf.db ]]; then
  log "Initializing /etc/openvswitch/conf.db"
  mkdir -p /etc/openvswitch
  ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi
log "Starting ovsdb-server + ovs-vswitchd"
ovs-ctl --no-mlockall start
ovs-ctl status || (log "ovs-ctl failed to start" && exit 1)

# ---------- Stable system-id ----------
if [[ ! -s "$SYS_ID_FILE" ]]; then uuidgen > "$SYS_ID_FILE"; fi
SYSTEM_ID="$(cat "$SYS_ID_FILE")"

# ---------- OVS fabric ----------
log "Configuring ${PHYS_BR} with trunk ${BOND_PORT} (VLANs ${ALLOWED_VLANS})"
ovs-vsctl --may-exist add-br "${PHYS_BR}" -- set Bridge "${PHYS_BR}" datapath_type=system fail-mode=standalone
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${BOND_PORT}"   -- set Port "${BOND_PORT}" vlan_mode=trunk trunks="[${ALLOWED_VLANS}]"

# Internal access ports (VLAN10/20)
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${MGMT_IFACE}" -- set Interface "${MGMT_IFACE}" type=internal tag="${MGMT_VLAN:-10}"
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${LINSTOR_IFACE}" -- set Interface "${LINSTOR_IFACE}" type=internal tag="${LINSTOR_VLAN:-20}"

# Bring up + assign IPs (avoid altering default route)
ip link set "${MGMT_IFACE}" up
ip addr flush dev "${MGMT_IFACE}" || true
ip addr add "${MGMT_CIDR}" dev "${MGMT_IFACE}"
[[ -n "${MTU:-}" ]] && ip link set dev "${MGMT_IFACE}" mtu "${MTU}" || true

ip link set "${LINSTOR_IFACE}" up
ip addr flush dev "${LINSTOR_IFACE}" || true
ip addr add "${LINSTOR_CIDR}" dev "${LINSTOR_IFACE}"
[[ -n "${MTU:-}" ]] && ip link set dev "${LINSTOR_IFACE}" mtu "${MTU}" || true

if [[ -n "${MGMT_GW:-}" ]]; then
  # add a /32 on-link route so ARP works for the GW without becoming default
  ip route replace "${MGMT_GW}/32" dev "${MGMT_IFACE}" || true
fi

# ---------- External IDs for OVN ----------
ovs-vsctl set Open_vSwitch . external_ids:system-id="${SYSTEM_ID}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings="${PHYSNET_NAME}:${PHYS_BR}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-encap-type="${ENCAP_TYPE}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-encap-ip="${ENCAP_IP}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-remote="${SB_REMOTES}"

# ---------- NB/SB RAFT clustered DBs ----------
NB_DB="${OVN_DB_DIR}/ovnnb_db.db"
SB_DB="${OVN_DB_DIR}/ovnsb_db.db"

if [[ "${ROLE}" == "bootstrap" ]]; then
  if [[ ! -f "$NB_DB" ]]; then
    log "Creating NB RAFT cluster (bootstrap @ ${ENCAP_IP}:6641)"
    ovsdb-tool create-cluster "$NB_DB" /usr/share/ovn/ovn-nb.ovsschema "tcp:${ENCAP_IP}:6641" --cluster-local-addr="${ENCAP_IP}"
  fi
  if [[ ! -f "$SB_DB" ]]; then
    log "Creating SB RAFT cluster (bootstrap @ ${ENCAP_IP}:6642)"
    ovsdb-tool create-cluster "$SB_DB" /usr/share/ovn/ovn-sb.ovsschema "tcp:${ENCAP_IP}:6642" --cluster-local-addr="${ENCAP_IP}"
  fi
else
  : "${BOOTSTRAP_IP:?BOOTSTRAP_IP required for join role}"
  if [[ ! -f "$NB_DB" ]]; then
    log "Joining NB RAFT cluster @ ${BOOTSTRAP_IP}:6641"
    ovsdb-tool join-cluster "$NB_DB" /usr/share/ovn/ovn-nb.ovsschema "tcp:${BOOTSTRAP_IP}:6641" --cluster-local-addr="${ENCAP_IP}"
  fi
  if [[ ! -f "$SB_DB" ]]; then
    log "Joining SB RAFT cluster @ ${BOOTSTRAP_IP}:6642"
    ovsdb-tool join-cluster "$SB_DB" /usr/share/ovn/ovn-sb.ovsschema "tcp:${BOOTSTRAP_IP}:6642" --cluster-local-addr="${ENCAP_IP}"
  fi
fi

log "Starting NB/SB ovsdb-servers"
ovn-ctl run_nb_ovsdb --db-nb-addr="${ENCAP_IP}"
ovn-ctl run_sb_ovsdb --db-sb-addr="${ENCAP_IP}"

# Wait for TCP listeners briefly
for i in {1..30}; do
  if ovsdb-client list-dbs "tcp:${ENCAP_IP}:6641" >/dev/null 2>&1 &&      ovsdb-client list-dbs "tcp:${ENCAP_IP}:6642" >/dev/null 2>&1; then
    break
  fi
  log "Waiting NB/SB to be reachable (attempt $i)"
  sleep 1
done

log "Starting ovn-northd"
ovn-ctl start_northd

log "Starting ovn-controller"
ovn-ctl start_controller

log "All services launched; entering keepalive loop"
exec bash -c 'trap "exit 0" TERM INT; while true; do sleep 3600; done'
