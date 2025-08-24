# OVN/OVS HA on Debian 13 (Docker Compose)

This bundle deploys a **three-node OVN + OVS cluster** (NB/SB RAFT, `ovn-northd`, `ovn-controller`) using a **single container per node**, built from `debian:trixie-slim`. It assumes Mellanox ConnectX‑3 Pro NICs bonded (LACP) as `mlnx-bond`, with VLAN **10** for management (`ovs-mgmt`) and VLAN **20** for storage mgmt (`linstor-mgmt`).

## Layout
```
/opt/ovn-ha
├─ docker-compose.yml
├─ Dockerfile
├─ Makefile
├─ .gitignore
├─ .env.example
├─ env/
│  ├─ r730xd-1.env   # bootstrap
│  ├─ r730xd-2.env   # join
│  └─ r730xd-3.env   # join
│  └─ current.env -> (symlink created by scripts/make-host-env.sh)
├─ scripts/
│  ├─ host-prep.sh
│  ├─ entrypoint.sh
│  ├─ checks.sh
│  └─ make-host-env.sh
├─ state/
│  ├─ openvswitch/
│  └─ ovn/
└─ logs/
   ├─ openvswitch/
   └─ ovn/
```

## One-time (per host)
```bash
sudo unzip ovn-ha-bundle-prod.zip -d /opt/       # or your downloaded filename
sudo chmod -R +x /opt/ovn-ha/scripts/*.sh
cd /opt/ovn-ha
sudo ./scripts/host-prep.sh                       # loads kernel modules, bond (if needed), tunes NICs
```

## Bring-up (hostname-aware)
The wrapper chooses the right env file based on host **short hostname** (`r730xd-1/2/3`). You can override with `--node` or `NODE_NAME=`.

```bash
make env            # creates env/current.env symlink (auto-detects hostname)
make build          # builds local image (OVS+OVN on Debian 13 slim)
make up             # starts the single ovn container with restart: always
make status         # quick health view
make logs           # tail container logs
make check          # runs helper checks inside container
```

## Verify
```bash
# IPs on OVS internal ports
ip a show ovs-mgmt
ip a show linstor-mgmt

# Peer pings (VLAN 10 and 20)
ping -c2 4.0.0.7; ping -c2 4.0.0.8; ping -c2 4.0.0.9
ping -c2 4.0.1.7; ping -c2 4.0.1.8; ping -c2 4.0.1.9

# OVN cluster state
make nbstatus
make sbstatus
```

## Notes
- **Modules on host**: `openvswitch`, `geneve`, `bonding` must be present/loaded (handled by `host-prep.sh`).
- **MTU**: Default 9000 in env; align with your fabric or unset via `MTU=`.
- **Switch**: LACP active trunk allowing VLANs 10,20 only.
- **No hw-offload**: ConnectX‑3 Pro is too old for OVS TC offload; keep it disabled.
- **Persistence**: Clustered DBs are in `./state/ovn`; OVS DB/state in `./state/openvswitch`.
- **Reset during testing**: `make clean-state` wipes DBs for a fresh RAFT bootstrap/join.
- **TLS later**: Replace `tcp:` with `ssl:` for NB/SB after provisioning certs.

## Per-node envs (summary)
- **r730xd-1.env** → `ROLE=bootstrap`, MGMT 4.0.0.7/24, LINSTOR 4.0.1.7/24
- **r730xd-2.env** → `ROLE=join`, MGMT 4.0.0.8/24, LINSTOR 4.0.1.8/24
- **r730xd-3.env** → `ROLE=join`, MGMT 4.0.0.9/24, LINSTOR 4.0.1.9/24
- All joiners use `BOOTSTRAP_IP=4.0.0.7`

Happy hacking!
