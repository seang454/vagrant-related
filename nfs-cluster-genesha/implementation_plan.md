# Implement Highly Available Ceph + NFS-Ganesha Architecture

This plan outlines the steps required to build out the complex HA storage architecture requested, transforming the 3 Load Balancer nodes into a fully distributed Ceph storage cluster with HA NFS-Ganesha gateways.

> [!WARNING]
> **CRITICAL HARDWARE LIMITATIONS DETECTED**
> Deploying Ceph and HA NFS is extremely resource-intensive. Your current `Vagrantfile` configures the `loadbalancer` nodes with **1GB of RAM** and **1 CPU**, and only a single OS disk.
> 1. **RAM**: Ceph MONs, MGRs, OSDs, Pacemaker, Corosync, HAProxy, and Keepalived running on the same machine will immediately crash a 1GB VM due to out-of-memory errors. We must increase this to at least **3GB or 4GB of RAM** per load balancer node.
> 2. **Disks**: Ceph OSDs strictly require raw, unformatted, secondary hard drives. We must modify your Vagrantfile to attach a second virtual hard disk (e.g., 20GB) to each loadbalancer VM.

---

## Hardware Requirements Per Load Balancer Node

| Service | Minimum RAM Needed |
| :--- | :--- |
| HAProxy + Keepalived (already running) | ~100MB |
| Docker (required by cephadm) | ~200MB |
| Ceph MON | ~500MB |
| Ceph MGR | ~500MB |
| Ceph OSD | ~1GB per OSD |
| Ceph MDS | ~500MB |
| NFS-Ganesha | ~200MB |
| Pacemaker + Corosync | ~100MB |
| **Total** | **~3GB minimum** |

| Requirement | Current | Needed |
| :--- | :---: | :---: |
| RAM per loadbalancer | 1GB ❌ | 4GB ✅ |
| CPUs per loadbalancer | 1 | 2 (recommended) |
| Secondary disk | None ❌ | 20GB raw disk ✅ |

---

## Architecture Diagram

```text
                         k3s Cluster
                              │
                         nfs-common
                              │
                              │ NFS
                              ▼
                     192.168.127.50
                       Floating VIP
                              │
                              ▼
                    NFS-Ganesha HA
                              │
                    Pacemaker + Corosync
                              │
             ┌────────────────┼────────────────┐
             │                │                │
          ceph-01          ceph-02          ceph-03
        (haproxy-1)      (haproxy-2)      (haproxy-3)
       192.168.127.9    192.168.127.15   192.168.127.16
             │                │                │
        NFS-Ganesha      NFS-Ganesha      NFS-Ganesha
        Pacemaker        Pacemaker        Pacemaker
        Corosync         Corosync         Corosync
             │                │                │
             └────────────────┼────────────────┘
                              │
                            CephFS
                              │
             ┌────────────────┼────────────────┐
             │                │                │
          Ceph MON         Ceph MON         Ceph MON
          Ceph MGR         Ceph MGR         Ceph MGR
          Ceph OSD         Ceph OSD         Ceph OSD
```

---

## Data Flow: How NFS Clients Write Data

```text
You write a file on any K3s node:
  echo "hello" > /mnt/nfs/myapp/config.txt

Step 1: Linux Kernel intercepts the write
         │
         │  Kernel sees /mnt/nfs is a mounted NFS share
         │
         ▼
Step 2: NFS Client (nfs-common) creates NFS "WRITE" message
         │
         ▼
Step 3: TCP/IP Network
         │  Source:      192.168.127.10 (master-1)
         │  Destination: 192.168.127.50 (NFS VIP)
         │  Port:        2049 (NFS)
         │  Protocol:    TCP
         ▼
Step 4: NFS-Ganesha Server receives the request
         │
         ▼
Step 5: NFS-Ganesha writes to CephFS
         │  Data is distributed and replicated across 3 Ceph nodes
         ▼
Step 6: Ceph confirms "Write successful"
         │
         ▼
Step 7: NFS-Ganesha sends confirmation back to client
         │
         ▼
Step 8: File is available on ALL nodes with NFS mounted
```

---

## Kubernetes Integration

To connect a Kubernetes Deployment to NFS, you need 3 YAML resources:

### PersistentVolume (PV) — "Tell Kubernetes where NFS is"
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: 192.168.127.50    # NFS Floating VIP
    path: /data               # Export path from NFS-Ganesha
```

### PersistentVolumeClaim (PVC) — "Request the storage"
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: ""
```

### Deployment — "Mount it into your app"
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: nginx
          volumeMounts:
            - name: nfs-storage
              mountPath: /usr/share/nginx/html
      volumes:
        - name: nfs-storage
          persistentVolumeClaim:
            claimName: nfs-pvc
```

This works **identically** on both K3s and K8s — the YAML files are exactly the same.

---

## User Review Required

1. **Vagrant Updates**: Do you approve of modifying your `Vagrantfile` to increase the RAM to 4GB and add a secondary virtual disk to the loadbalancer VMs? You will need to destroy and recreate the load balancer VMs (`vagrant destroy loadbalancer-X` then `vagrant up`) for these hardware changes to take effect.
2. **Ceph Deployment Strategy**: Deploying Ceph manually via raw Ansible tasks is highly prone to failure due to its complexity. Our `ceph` Ansible role uses **`cephadm`**, the official Ceph deployment tool, to bootstrap the cluster.
3. **VIP Conflict**: Your current HAProxy/Keepalived setup already manages a Virtual IP for Kubernetes. This architecture adds a **new** Floating VIP (`192.168.127.50`) for NFS, managed by Pacemaker. Keepalived continues to manage the Kubernetes API VIP separately.

---

## Proposed Changes

We have created a structured Ansible project with dedicated roles for each technology layer.

### 1. Update Infrastructure

#### [MODIFY] Vagrantfile
- Increase `memsize` for `loadbalancer` nodes to `4096` (4GB).
- Increase `numvcpus` for `loadbalancer` nodes to `2`.
- Add VMware configuration to create and attach a secondary `20GB` `.vmdk` disk to each loadbalancer node for Ceph OSDs.

#### [MODIFY] inventory/hosts.ini
- `[ceph_nodes]` group containing the 3 loadbalancer nodes.
- `[nfs_clients]` group containing master and worker nodes.

### 2. Ansible Roles

#### [NEW] roles/common
**Purpose**: Runs on ALL nodes first. Prepares the environment.
- Configures `/etc/hosts` so all nodes can resolve each other by hostname (using Jinja2 template).
- Installs and enables `chrony` for time synchronization (Ceph requires clocks within 0.05s).
- Disables `ufw` firewall for lab environment.
- Installs basic prerequisites (curl, wget, gnupg, apt-transport-https).

#### [NEW] roles/ceph
**Purpose**: Deploys the full Ceph storage cluster using `cephadm`.
- Installs dependencies and Docker on ALL nodes.
- Downloads `cephadm` binary and adds Ceph repo on ALL nodes.
- Bootstraps the initial Ceph MON on `haproxy-1` (first node only).
- Distributes `/etc/ceph/ceph.conf` and admin keyring to all other nodes (using slurp + copy).
- Adds SSH keys and joins `haproxy-2` and `haproxy-3` to the cluster.
- Provisions OSDs on the secondary raw disks (`/dev/sdb`) attached to the VMs.
- Creates CephFS pools and filesystem.
- Deploys MDS (Metadata Server) required for CephFS.
- Waits for `ceph health` to return `HEALTH_OK` before continuing.

#### [NEW] roles/nfs_ganesha
**Purpose**: Installs and configures NFS-Ganesha gateways on all 3 nodes.
- Installs `nfs-ganesha` and `nfs-ganesha-ceph` packages.
- Creates a **dedicated** `client.ganesha` Ceph user (NOT admin) with limited permissions.
- Distributes the ganesha keyring to all nodes.
- Generates `ganesha.conf` from a Jinja2 template to export CephFS.
- **Disables** NFS-Ganesha from systemd (Pacemaker will manage it to avoid conflicts).

#### [NEW] roles/pacemaker_corosync
**Purpose**: Creates the HA cluster and manages resources.
- Installs `pacemaker`, `corosync`, and `pcs`.
- Opens firewall ports for Corosync (UDP 5404-5405), PCS (TCP 2224), and NFS (TCP 2049).
- Sets `hacluster` password identically on all nodes.
- Authenticates and creates the Pacemaker cluster.
- Configures the NFS Floating VIP (`192.168.127.50`) as a Pacemaker resource.
- Configures the NFS-Ganesha service as a Pacemaker resource.
- Sets **ordering constraint**: VIP must start BEFORE NFS-Ganesha.
- Sets **colocation constraint**: VIP and NFS-Ganesha must run on the SAME node.
- Disables STONITH for lab (with warning that production MUST enable it).

#### [NEW] roles/nfs_client
**Purpose**: Configures K3s master and worker nodes as NFS clients.
- Installs `nfs-common`.
- Creates mount point directory (`/mnt/nfs`).
- **Waits** for the NFS VIP to be reachable on port 2049 before attempting mount.
- Mounts the NFS share and adds to `/etc/fstab` for persistence across reboots.
- Verifies the mount is active.

### 3. Orchestration

#### site.yml (Main Playbook)
Executes all roles in the correct order:
1. `common` → ALL nodes
2. `ceph` → ceph_nodes (haproxy-1/2/3)
3. `nfs_ganesha` → ceph_nodes
4. `pacemaker_corosync` → ceph_nodes
5. `nfs_client` → nfs_clients (master-1/2/3, worker-1/2)

### 4. Centralized Variables

#### group_vars/all.yml
All configuration is centralized in one file with risk markers:
- 🔴 Variables that cause **immediate failure** if changed incorrectly (VIP subnet, disk device, interface name)
- ⚠️ Variables that must **NOT change after initial deployment** (Ceph release, pool names, cluster name)
- 🟡 Variables that are **safe but must match your environment** (mount options, hacluster password)
- 🟢 Variables that are **safe to change anytime** (mount point path)

---

## Project Structure

```text
nfs-cluster-genesha/
├── ansible.cfg
├── site.yml                              ← Main playbook (5 plays in order)
├── group_vars/
│   └── all.yml                           ← ALL variables in ONE place (with risk markers)
├── inventory/
│   └── hosts.ini                         ← Node definitions
└── roles/
    ├── common/                           ← Runs FIRST on ALL nodes
    │   ├── defaults/main.yml
    │   ├── templates/hosts.j2            ← /etc/hosts template
    │   └── tasks/main.yml                ← hosts, chrony, firewall, prerequisites
    ├── ceph/                             ← 17-step Ceph deployment
    │   ├── defaults/main.yml
    │   └── tasks/main.yml                ← bootstrap, keys, OSD, CephFS, health check
    ├── nfs_ganesha/                      ← NFS-Ganesha with dedicated Ceph user
    │   ├── defaults/main.yml
    │   ├── templates/ganesha.conf.j2     ← Dynamic NFS export config
    │   ├── handlers/main.yml             ← Auto-restart on config change
    │   └── tasks/main.yml                ← install, auth, config, disable systemd
    ├── pacemaker_corosync/               ← HA cluster with VIP + NFS resource
    │   ├── defaults/main.yml
    │   └── tasks/main.yml                ← auth, cluster, VIP, NFS, ordering, colocation
    └── nfs_client/                       ← NFS client with pre-check
        ├── defaults/main.yml
        └── tasks/main.yml                ← install, wait_for VIP, mount, verify
```

---

## Verification Plan

### Automated (Built into Ansible roles)
- Ceph role waits for `ceph health` to return `HEALTH_OK` before proceeding.
- NFS client role uses `wait_for` to confirm VIP is reachable on port 2049.
- NFS client role runs `df -h` to verify mount is active.
- Pacemaker role displays `pcs status` to show all resources are running.

### Manual Verification
1. **Ensure secondary disks are recognized**: SSH into any loadbalancer and run `lsblk`. You should see `/dev/sdb` (20GB raw disk).
2. **Verify Ceph cluster health**: Run `sudo ceph -s` on any loadbalancer. Status should show `HEALTH_OK`.
3. **Verify Pacemaker cluster**: Run `sudo pcs status` on any loadbalancer. VIP and NFS-Ganesha resources should show as `Started`.
4. **Verify NFS mount from K3s node**: SSH into any master/worker and run `df -h /mnt/nfs`. It should show the NFS share mounted.
5. **Test data write**: Create a file on one node and verify it appears on all others:
   ```bash
   # On master-1
   echo "hello" > /mnt/nfs/test.txt

   # On master-2
   cat /mnt/nfs/test.txt    # Should output "hello"
   ```
6. **Test failover**: Stop NFS-Ganesha on the active node and verify Pacemaker moves the VIP and service to another node automatically.
