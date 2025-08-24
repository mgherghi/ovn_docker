
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(date +'%F %T')] $*"; }
: "${NODE_NAME:?}"; : "${ROLE:?}"; : "${PHYS_BR:?}"; : "${BOND_PORT:?}"
: "${MGMT_IFACE:?}"; : "${MGMT_CIDR:?}"; : "${MGMT_IP:?}"
: "${LINSTOR_IFACE:?}"; : "${LINSTOR_CIDR:?}"
: "${NB_REMOTES:?}"; : "${SB_REMOTES:?}"; : "${ENCAP_TYPE:?}"; : "${ENCAP_IP:?}"
: "${PHYSNET_NAME:?}"; : "${ALLOWED_VLANS:?}"
OVS_DB_DIR="/var/lib/openvswitch"
OVN_DB_DIR="/var/lib/ovn"
mkdir -p "$OVS_DB_DIR" "$OVN_DB_DIR" /var/log/openvswitch /var/log/ovn /var/run/openvswitch /var/run/ovn /etc/openvswitch

has_flag_cluster_local_addr(){ ovsdb-tool --help 2>&1 | grep -q -- "--cluster-local-addr"; }
syntax_requires_local_addr(){ ovsdb-tool --help 2>&1 | grep -q "join-cluster DB SCHEMA .* LOCAL_ADDR"; }
db_is_clustered(){
  if ovsdb-tool db-is-clustered "$1" >/dev/null 2>&1; then return 0; fi
  strings "$1" 2>/dev/null | grep -qi "cluster" && return 0 || return 1
}
create_cluster(){
  local db="$1" schema="$2" addr="$3" local_ip="$4"
  if has_flag_cluster_local_addr; then
    ovsdb-tool create-cluster "$db" "$schema" "$addr" --cluster-local-addr="${local_ip}"
  elif syntax_requires_local_addr; then
    ovsdb-tool create-cluster "$db" "$schema" "$addr" "tcp:${local_ip}:${addr##*:}"
  else
    ovsdb-tool create-cluster "$db" "$schema" "$addr"
  fi
}
join_cluster(){
  local db="$1" schema="$2" remote="$3" local_ip="$4"
  if has_flag_cluster_local_addr; then
    ovsdb-tool join-cluster "$db" "$schema" "$remote" --cluster-local-addr="${local_ip}"
  elif syntax_requires_local_addr; then
    ovsdb-tool join-cluster "$db" "$schema" "$remote" "tcp:${local_ip}:${remote##*:}"
  else
    ovsdb-tool join-cluster "$db" "$schema" "$remote"
  fi
}

for d in /var/run/openvswitch /var/run/ovn; do
  find "$d" -maxdepth 1 -type f -name "*.pid" -delete || true
  find "$d" -maxdepth 1 -type f -name "*.lock" -delete || true
done

if [[ ! -d /sys/module/openvswitch ]]; then
  log "ERROR: host openvswitch module not loaded. Run scripts/host-prep.sh"
  exit 1
fi
if [[ ! -d /sys/module/geneve ]]; then
  log "WARN: host geneve module not loaded; encapsulation may fail."
fi

SYS_ID_FILE_VAR="/var/lib/openvswitch/system-id.conf"
SYS_ID_FILE_ETC="/etc/openvswitch/system-id.conf"
if [[ -s "$SYS_ID_FILE_VAR" ]]; then
  SYSTEM_ID="$(cat "$SYS_ID_FILE_VAR")"
elif [[ -s "$SYS_ID_FILE_ETC" ]]; then
  SYSTEM_ID="$(cat "$SYS_ID_FILE_ETC")"
else
  SYSTEM_ID="$(uuidgen)"
  echo "$SYSTEM_ID" > "$SYS_ID_FILE_VAR"
  echo "$SYSTEM_ID" > "$SYS_ID_FILE_ETC"
fi

if [[ ! -f /etc/openvswitch/conf.db ]]; then
  log "Initializing /etc/openvswitch/conf.db"
  ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi
log "Starting ovsdb-server + ovs-vswitchd"
OVS_CTL_OPTS="--system-id=$SYSTEM_ID"
ovs-ctl $OVS_CTL_OPTS --no-mlockall start
ovs-ctl status || (log "ovs-ctl failed to start" && exit 1)

log "Configuring ${PHYS_BR} with trunk ${BOND_PORT} (VLANs ${ALLOWED_VLANS})"
ovs-vsctl --may-exist add-br "${PHYS_BR}" -- set Bridge "${PHYS_BR}" datapath_type=system fail-mode=standalone
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${BOND_PORT}" -- set Port "${BOND_PORT}" vlan_mode=trunk trunks="[${ALLOWED_VLANS}]"
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${MGMT_IFACE}" -- set Interface "${MGMT_IFACE}" type=internal -- set Port "${MGMT_IFACE}" tag="${MGMT_VLAN:-10}"
ovs-vsctl --may-exist add-port "${PHYS_BR}" "${LINSTOR_IFACE}" -- set Interface "${LINSTOR_IFACE}" type=internal -- set Port "${LINSTOR_IFACE}" tag="${LINSTOR_VLAN:-20}"

ip link set "${MGMT_IFACE}" up
ip addr flush dev "${MGMT_IFACE}" || true
ip addr add "${MGMT_CIDR}" dev "${MGMT_IFACE}"
[[ -n "${MTU:-}" ]] && ip link set dev "${MGMT_IFACE}" mtu "${MTU}" || true

ip link set "${LINSTOR_IFACE}" up
ip addr flush dev "${LINSTOR_IFACE}" || true
ip addr add "${LINSTOR_CIDR}" dev "${LINSTOR_IFACE}"
[[ -n "${MTU:-}" ]] && ip link set dev "${LINSTOR_IFACE}" mtu "${MTU}" || true

if [[ -n "${MGMT_GW:-}" ]]; then
  ip route replace "${MGMT_GW}/32" dev "${MGMT_IFACE}" || true
fi

ovs-vsctl set Open_vSwitch . external_ids:system-id="${SYSTEM_ID}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-bridge-mappings="${PHYSNET_NAME}:${PHYS_BR}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-encap-type="${ENCAP_TYPE}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-encap-ip="${ENCAP_IP}"
ovs-vsctl set Open_vSwitch . external_ids:ovn-remote="${SB_REMOTES}"

NB_DB="${OVN_DB_DIR}/ovnnb_db.db"
SB_DB="${OVN_DB_DIR}/ovnsb_db.db"

if [[ "${ROLE}" == "bootstrap" ]]; then
  if [[ -f "$NB_DB" ]] && db_is_clustered "$NB_DB"; then
    log "NB DB already clustered; skipping create-cluster."
  elif [[ ! -f "$NB_DB" ]]; then
    log "Creating NB RAFT cluster (bootstrap @ ${ENCAP_IP}:6641)"
    create_cluster "$NB_DB" /usr/share/ovn/ovn-nb.ovsschema "tcp:${ENCAP_IP}:6641" "${ENCAP_IP}"
  fi
  if [[ -f "$SB_DB" ]] && db_is_clustered "$SB_DB"; then
    log "SB DB already clustered; skipping create-cluster."
  elif [[ ! -f "$SB_DB" ]]; then
    log "Creating SB RAFT cluster (bootstrap @ ${ENCAP_IP}:6642)"
    create_cluster "$SB_DB" /usr/share/ovn/ovn-sb.ovsschema "tcp:${ENCAP_IP}:6642" "${ENCAP_IP}"
  fi
else
  : "${BOOTSTRAP_IP:?BOOTSTRAP_IP required for join role}"
  if [[ -f "$NB_DB" ]] && db_is_clustered "$NB_DB"; then
    log "NB DB already clustered; skipping join-cluster."
  elif [[ ! -f "$NB_DB" ]]; then
    log "Joining NB RAFT cluster @ ${BOOTSTRAP_IP}:6641"
    join_cluster "$NB_DB" /usr/share/ovn/ovn-nb.ovsschema "tcp:${BOOTSTRAP_IP}:6641" "${ENCAP_IP}"
  fi
  if [[ -f "$SB_DB" ]] && db_is_clustered "$SB_DB"; then
    log "SB DB already clustered; skipping join-cluster."
  elif [[ ! -f "$SB_DB" ]]; then
    log "Joining SB RAFT cluster @ ${BOOTSTRAP_IP}:6642"
    join_cluster "$SB_DB" /usr/share/ovn/ovn-sb.ovsschema "tcp:${BOOTSTRAP_IP}:6642" "${ENCAP_IP}"
  fi
fi

log "Starting NB/SB ovsdb-servers"
ovn-ctl run_nb_ovsdb --db-nb-addr="${ENCAP_IP}"
ovn-ctl run_sb_ovsdb --db-sb-addr="${ENCAP_IP}"

for i in {1..30}; do
  if ovsdb-client list-dbs "tcp:${ENCAP_IP}:6641" >/dev/null 2>&1 && \
     ovsdb-client list-dbs "tcp:${ENCAP_IP}:6642" >/dev/null 2>&1; then
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
