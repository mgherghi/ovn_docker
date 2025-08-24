
#!/usr/bin/env bash
set -euo pipefail
echo "=== OVS ==="
ovs-vsctl show
echo "=== External IDs ==="
ovs-vsctl list Open_vSwitch | sed -n '/external_ids/,$p' | sed -n '1,12p'
echo "=== Encapsulation ==="
echo -n "ovn-encap-type: "; ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-type
echo -n "ovn-encap-ip:   ";  ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-ip
echo "=== NB/SB Cluster Status ==="
ovn-appctl -t nbdb/ovsdb-server cluster/status OVN_Northbound || true
ovn-appctl -t sbdb/ovsdb-server cluster/status OVN_Southbound || true
echo "=== SB Chassis ==="
ovn-sbctl show || true
