# High Availability (HA) NFS Cluster Designs

When building an HA NFS system for Kubernetes, you install the HA components directly on the servers that are going to run NFS. You don't create a separate "HA server."

For example, with 2 NFS servers forming the cluster themselves:

```text
             Kubernetes / Clients
                    │
             NFS Virtual IP
              192.168.1.50
                    │
          ┌─────────┴─────────┐
          │                   │
     ┌────▼─────┐        ┌────▼─────┐
     │  NFS-01  │        │  NFS-02  │
     │          │        │          │
     │ NFS      │        │ NFS      │
     │ DRBD     │        │ DRBD     │
     │ Pacemaker│        │ Pacemaker│
     │ Corosync │        │ Corosync │
     └────┬─────┘        └────┬─────┘
          │                   │
          └────── DRBD ───────┘
             data replication
```

### Component Breakdown
| Component | NFS-01 | NFS-02 |
| :--- | :---: | :---: |
| NFS server | ✅ | ✅ |
| DRBD | ✅ | ✅ |
| Corosync | ✅ | ✅ |
| Pacemaker | ✅ | ✅ |
| NFS export configuration | ✅ | ✅ |
| Floating VIP management | ✅ | ✅ |

You **do not** need a separate HA Server.

### Example Architecture
Suppose:
* `NFS-01` = 192.168.1.10
* `NFS-02` = 192.168.1.11
* `VIP` = 192.168.1.50

Normally, `NFS-01` is **ACTIVE** and holds the VIP, serving `/data`. If `NFS-01` fails, the VIP automatically moves to `NFS-02`, making it **ACTIVE**. Your Kubernetes nodes continue using `192.168.1.50:/data` without knowing which physical server is active.

*(Note: If you use Pacemaker + Corosync, you don't necessarily need Keepalived because Pacemaker can manage the floating IP as a cluster resource).*

---

## What are these technologies used for?

The easiest way to understand them is to separate storage, failover, and network access. An HA NFS system solves 3 problems:
1. Where is my data?
2. Which NFS server is active?
3. How do clients find the active NFS server?

### 1. DRBD (Distributed Replicated Block Device)
**Solves: "How do I keep the data available if one NFS server dies?"**

Its job is to copy/replicate block-level data from one server to another.
```text
NFS-01                         NFS-02
┌─────────────┐               ┌─────────────┐
│ /dev/sdb    │               │ /dev/sdb    │
│             │◄──── DRBD ───►│             │
│ NFS data    │               │ NFS data    │
└─────────────┘               └─────────────┘
```
If `NFS-01` writes `/data/file.txt`, DRBD replicates the underlying disk blocks to `NFS-02`. If `NFS-01` fails, `NFS-02` can take over with the replicated data.

### 2. Pacemaker (Cluster Resource Manager)
**Solves: "Which server should provide the NFS service?"**

It decides who is ACTIVE and who is STANDBY. It manages resources such as the NFS service, filesystem, DRBD resource, IP address, and mount points.
If Pacemaker detects that `NFS-01` has failed, it starts the resources on `NFS-02` and makes it ACTIVE.

### 3. Corosync (Communication Layer)
**Solves: Cluster Communication**

Corosync allows the cluster servers to communicate and exchange heartbeats ("Are you alive?"). If `NFS-01` stops responding, Corosync notices, tells Pacemaker, and Pacemaker triggers the failover.
* **Corosync** = communication
* **Pacemaker** = decision/control

### 4. Keepalived (Floating Virtual IP)
**Solves: "How can clients always connect to the currently active server using the same IP?"**

Clients don't want to care about individual server IPs. They use a Virtual IP (VIP). Keepalived moves the VIP from the failing node to the standby node instantly. *(Reminder: Pacemaker can also handle this directly).*

### 5. Ceph (Distributed Storage)
**Solves: "How can I build a distributed, scalable, highly available storage system?"**

Instead of basic replication between 2 nodes, Ceph distributes and replicates storage across multiple machines. It is powerful but much more complex than needed for a basic 2-node HA NFS lab.

### 6. SAN / Shared Storage
**Solves: "How can multiple servers access the same storage?"**

Both NFS servers access the same storage array (SAN). You don't need DRBD because the data is already on shared storage. The SAN itself must be highly available (redundant controllers, disks, paths) to prevent a single point of failure.

---

## 3 Different HA Storage Designs

### Design A: DRBD-based HA NFS
* **Where is the data?** Local disks on NFS servers.
* **How is data protected?** DRBD replication.
* **Complexity:** Medium 🟡

```text
             Kubernetes
                 │
            192.168.1.50
                 │
                 ▼
        ┌─────────────────┐
        │   Virtual IP    │
        └────────┬────────┘
                 │
       ┌─────────┴─────────┐
       │                   │
    NFS-01               NFS-02
    ACTIVE               STANDBY
       │                   │
       └─────── DRBD ──────┘
              │
         Replicated data

      Pacemaker + Corosync
          manage cluster
```

### Design B: SAN-based HA NFS
* **Where is the data?** Shared SAN.
* **How is data protected?** SAN redundancy.
* **Complexity:** Medium/High 🟡

```text
             Kubernetes
                 │
            Virtual IP
                 │
       ┌─────────┴─────────┐
       │                   │
    NFS-01               NFS-02
    ACTIVE               STANDBY
       │                   │
       └─────────┬─────────┘
                 │
                SAN
```

### Design C: Ceph-based
* **Where is the data?** Distributed across Ceph nodes.
* **How is data protected?** Ceph replication.
* **Complexity:** High 🔴

```text
             Kubernetes
                 │
                NFS
                 │
                Ceph
         ┌───────┼───────┐
       Node1   Node2   Node3
```

---

## Recommendation for a Learning Lab

For a K3s + NFS learning project, **Design A (DRBD-based HA NFS)** is the best starting point. 

It allows you to learn several important HA concepts at once without introducing the massive complexity of Ceph:
* **DRBD** → storage replication
* **Corosync** → cluster communication
* **Pacemaker** → failover management
* **VIP** → stable client endpoint
* **NFS** → file sharing
* **K3s** → consumes the HA NFS storage

**Important Note for Production:** A 2-node DRBD/Pacemaker cluster needs proper quorum/fencing (STONITH) design in production. Otherwise, a network partition can create a split-brain scenario and potentially corrupt data. For a lab, you can simplify it, but it's critical to understand before deploying to production.
