
#!/usr/bin/env bash
set -euo pipefail

echo "[host-prep] Loading kernel modules"
modprobe openvswitch || true
modprobe geneve || true
modprobe bonding || true

BOND_NAME="${BOND_NAME:-mlnx-bond}"
IF1="${IF1:-enp132s0}"
IF2="${IF2:-enp132s0d1}"

if ! ip link show "$BOND_NAME" &>/dev/null; then
  echo "[host-prep] Creating LACP bond $BOND_NAME using $IF1,$IF2"
  ip link add "$BOND_NAME" type bond mode 802.3ad
  ip link set "$IF1" down || true
  ip link set "$IF2" down || true
  ip link set "$IF1" master "$BOND_NAME"
  ip link set "$IF2" master "$BOND_NAME"
  echo 1   > /sys/class/net/$BOND_NAME/bonding/lacp_rate
  echo 100 > /sys/class/net/$BOND_NAME/bonding/miimon
  ip link set "$BOND_NAME" up
fi

for NIC in "$IF1" "$IF2"; do
  echo "[host-prep] Tuning $NIC"
  ethtool -K "$NIC" gro on gso on tso on rx on tx on sg on tx-nocache-copy off || true
  ethtool -G "$NIC" rx 4096 tx 4096 || true
done

echo "[host-prep] OK"
