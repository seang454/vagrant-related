You install the HA components on the servers that are going to run NFS. You don't normally create a separate "HA server."

For example, with 2 NFS servers:

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
     │           │        │           │
     │ NFS       │        │ NFS       │
     │ DRBD      │        │ DRBD      │
     │ Pacemaker │        │ Pacemaker │
     │ Corosync  │        │ Corosync  │
     └────┬──────┘        └────┬──────┘
          │                    │
          └────── DRBD ────────┘
             data replication
```

So, install what where?

| Component | NFS-01 | NFS-02 |
| :--- | :---: | :---: |
| NFS server | ✅ | ✅ |
| DRBD | ✅ | ✅ |
| Corosync | ✅ | ✅ |
| Pacemaker | ✅ | ✅ |
| NFS export configuration | ✅ | ✅ |
| Floating VIP management | ✅ | ✅ |

You do not need:
```text
NFS-01
NFS-02
    │
    ▼
HA Server ❌
```

The two NFS servers form the HA cluster themselves.

### Example

Suppose:

NFS-01 = `192.168.1.10`
NFS-02 = `192.168.1.11`
VIP    = `192.168.1.50`

Normally:

```text
192.168.1.50
      │
      ▼
NFS-01 (ACTIVE)
      │
      ▼
/data
```

If NFS-01 fails:

```text
NFS-01 ❌

192.168.1.50
      │
      ▼
NFS-02 (ACTIVE)
      │
      ▼
/data
```

Your Kubernetes nodes continue using:

`192.168.1.50:/data`

They don't need to know which physical NFS server is currently active.

One important correction: if you use Pacemaker + Corosync, you don't necessarily need Keepalived. Pacemaker can manage the floating IP as a cluster resource. For a first HA NFS setup, I'd keep the architecture simpler rather than installing everything.

Possible technologies include:

*   **DRBD** — replicate storage between two Linux servers
*   **Pacemaker + Corosync** — manage failover
*   **Keepalived** — provide a floating Virtual IP
*   **Ceph** — distributed, highly available storage
*   **SAN/shared storage** — both NFS servers access the same storage

---

## Can you explain what this tech is used for?

Yes. The easiest way to understand them is to separate storage, failover, and network access.

Think of your HA NFS system as needing to solve 3 problems:

1.  Where is my data?
2.  Which NFS server is active?
3.  How do clients find the active NFS server?

Each technology solves a different problem.

### 1. DRBD — Replicate the data

DRBD = Distributed Replicated Block Device

Its job is to copy/replicate block-level data from one server to another.

Example:

```text
NFS-01                         NFS-02
┌─────────────┐               ┌─────────────┐
│ /dev/sdb    │               │ /dev/sdb    │
│             │◄──── DRBD ───►│             │
│ NFS data    │               │ NFS data    │
└─────────────┘               └─────────────┘
```

If NFS-01 writes:

`/data/file.txt`

DRBD replicates the underlying disk blocks to NFS-02.

So both servers have a copy of the data.

Why use it?

If:

`NFS-01 ❌`

NFS-02 can take over with the replicated data.

DRBD solves:

**"How do I keep the data available if one NFS server dies?"**

### 2. Pacemaker — Decide who is active

Pacemaker is a cluster resource manager.

It decides things like:

NFS-01 = ACTIVE
NFS-02 = STANDBY

If Pacemaker detects that NFS-01 has failed:

```text
NFS-01 ❌
     │
     ▼
Pacemaker detects failure
     │
     ▼
Start resources on NFS-02
     │
     ▼
NFS-02 = ACTIVE
```

It can manage resources such as:

*   NFS service
*   filesystem
*   DRBD resource
*   IP address
*   mount points

So Pacemaker solves:

**"Which server should provide the NFS service?"**

### 3. Corosync — Let the cluster servers communicate

Corosync is the communication layer between cluster nodes.

For example:

```text
NFS-01 ◄──── Corosync ────► NFS-02
```

They use it to exchange information such as:

"Are you alive?"
"I'm alive."
"Are you still part of the cluster?"
"Yes."

If NFS-01 stops responding:

```text
NFS-01 ❌
   │
   ▼
Corosync notices
   │
   ▼
Pacemaker
   │
   ▼
NFS-02 becomes active
```

So:

*   **Corosync** = communication
*   **Pacemaker** = decision/control

They are commonly used together.

### 4. Keepalived — Provide a floating Virtual IP

Your clients don't want to care about:

NFS-01 = `192.168.1.10`
NFS-02 = `192.168.1.11`

Instead, they can use:

`192.168.1.50`

This is a Virtual IP (VIP).

Example:

```text
                NFS Client
                    │
                    │
             192.168.1.50
                Virtual IP
                    │
          ┌─────────┴─────────┐
          │                   │
     NFS-01                NFS-02
   192.168.1.10          192.168.1.11
     ACTIVE                STANDBY
```

If NFS-01 fails:

```text
                    │
             192.168.1.50
                    │
                    ▼
                 NFS-02
                  ACTIVE
```

The VIP moves to NFS-02.

Keepalived solves:

**"How can clients always connect to the currently active server using the same IP?"**

**Important**

If you're already using Pacemaker, Pacemaker can manage the VIP itself. Therefore, you don't necessarily need Keepalived.

### 5. Ceph — Provide distributed storage

Ceph is much bigger than DRBD.

Instead of:

```text
NFS-01 ◄────► NFS-02
```

you might have:

```text
       Ceph Storage Cluster

       ┌───────────────┐
       │    Ceph 01    │
       └───────────────┘
          │        │
          │        │
       ┌──▼────────▼──┐
       │              │
┌──────▼─────┐  ┌─────▼──────┐
│   Ceph 02  │  │   Ceph 03  │
└────────────┘  └────────────┘
```

Ceph distributes and replicates storage across multiple machines.

For example:

```text
             Ceph
              │
       ┌──────┼──────┐
       │      │      │
      Disk   Disk   Disk
       │      │      │
      Node   Node   Node
```

If one storage node fails, Ceph can continue providing the data from the remaining nodes.

Ceph solves:

**"How can I build a distributed, scalable, highly available storage system?"**

It's powerful, but much more complex than you need for a basic 2-node HA NFS lab.

### 6. SAN / Shared Storage — One storage system accessible by both servers

A SAN provides storage that multiple servers can access.

For example:

```text
              SAN
               │
       ┌───────┴───────┐
       │               │
    NFS-01           NFS-02
```

Both NFS servers can access the same storage.

For example:

```text
NFS-01 ──────┐
             │
             ▼
          SAN / Storage
             ▲
             │
NFS-02 ──────┘
```

So you don't necessarily need DRBD because the data is already on shared storage.

SAN/shared storage solves:

**"How can multiple servers access the same storage?"**

---

## Putting everything together

Now you can see the difference:

```text
┌────────────────────────────────────────────┐
│              HA NFS SYSTEM                 │
│                                            │
│  DRBD       → Replicate the data           │
│                                            │
│  Corosync   → Cluster communication        │
│                                            │
│  Pacemaker  → Manage failover/resources    │
│                                            │
│  Keepalived → Floating Virtual IP          │
│                                            │
│  Ceph       → Distributed storage          │
│                                            │
│  SAN        → Shared storage               │
└────────────────────────────────────────────┘
```

But you don't install all of these together.

There are different designs.

### Design A — DRBD-based HA NFS

Good for your learning lab:

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

### Design B — SAN-based HA NFS

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

### Design C — Ceph-based

```text
             Kubernetes
                 │
              NFS
                 │
              Ceph
         ┌───────┼───────┐
       Node1   Node2   Node3
```

For your k3s + NFS learning project, I'd start with NFS + DRBD + Pacemaker + Corosync + a VIP. It's a good way to learn what each HA component actually does without introducing the much larger complexity of Ceph.

---

## Can you explain this

Absolutely. The main difference between these 3 designs is where the data lives and how the data stays available when an NFS server fails.

Think of HA NFS as having two separate problems:

1.  NFS server failover — if NFS-01 dies, NFS-02 takes over.
2.  Data availability — NFS-02 must still be able to access the data.

The three designs solve #2 differently.

### 1. Design A — DRBD-based HA NFS

```text
                 Kubernetes
                     │
                     │
              192.168.1.50
                 Virtual IP
                     │
             ┌───────┴───────┐
             │               │
          NFS-01           NFS-02
          ACTIVE            STANDBY
             │               │
             └────── DRBD ───┘
                    │
              Replicated data

         Pacemaker + Corosync
             manage cluster
```

What happens here?

You have two normal Linux servers, each with its own disk.

For example:

```text
NFS-01
192.168.1.10
/dev/sdb
    │
    │ DRBD replication
    ▼
NFS-02
192.168.1.11
/dev/sdb
```

Suppose you create:

`/data`

on NFS-01.

The data is replicated by DRBD to NFS-02.

So conceptually:

```text
NFS-01                         NFS-02
┌─────────────┐               ┌─────────────┐
│ /data       │               │ /data       │
│             │               │             │
│ file1.txt   │◄─── DRBD ───►│ file1.txt   │
│ file2.txt   │               │ file2.txt   │
└─────────────┘               └─────────────┘
```

But both servers are not normally serving the filesystem simultaneously in a simple active/passive design.

Normally:

NFS-01 = ACTIVE
NFS-02 = STANDBY

If NFS-01 fails:

```text
NFS-01 ❌
   │
   ▼
Pacemaker detects failure
   │
   ▼
NFS-02 becomes ACTIVE
   │
   ▼
NFS service starts
   │
   ▼
VIP moves to NFS-02
```

The Kubernetes nodes continue using:

`192.168.1.50:/data`

They don't need to know that NFS-01 died.

Who does what?
*   **DRBD** ↓ Keeps the data replicated
*   **Corosync** ↓ Lets NFS-01 and NFS-02 communicate
*   **Pacemaker** ↓ Controls which node is active and starts/stops resources
*   **Virtual IP** ↓ Gives clients one stable address

The important idea:
The two NFS servers have their own disks, but DRBD keeps the data synchronized.

### 2. Design B — SAN-based HA NFS

```text
                 Kubernetes
                     │
               Virtual IP
                     │
             ┌───────┴───────┐
             │               │
          NFS-01           NFS-02
          ACTIVE            STANDBY
             │               │
             └───────┬───────┘
                     │
                    SAN
```

This is different.

Instead of each NFS server having its own copy of the data:

*   NFS-01 → local disk
*   NFS-02 → local disk

you have a separate shared storage system.

```text
              SAN
               │
       ┌───────┴───────┐
       │               │
    NFS-01           NFS-02
```

The SAN stores the actual data.

For example:

```text
SAN
└── /storage
    ├── file1.txt
    ├── file2.txt
    └── file3.txt
```

Both NFS servers can access that storage.

If NFS-01 fails:
Before:

```text
        SAN
       /   \
      /     \
 NFS-01    NFS-02
 ACTIVE    STANDBY
```

NFS-01 dies:

```text
             SAN
              │
              │
           NFS-02
           ACTIVE
```

NFS-02 accesses the same storage.

Why don't we need DRBD?
Because the SAN is already providing the shared storage.

With DRBD:

```text
NFS-01 disk
     │
     ▼
   DRBD
     │
     ▼
NFS-02 disk
```

With SAN:

```text
NFS-01 ──┐
         │
         ▼
        SAN
         ▲
         │
NFS-02 ──┘
```

So you generally choose DRBD OR shared storage, not both for the same data path.

Important:
A SAN itself must be highly available if you want the whole system to be HA.

If your SAN is just one physical storage device and it dies:

```text
SAN ❌

NFS-01 ❌ data access
NFS-02 ❌ data access
```

So enterprise SAN environments often have redundant controllers, disks, paths, etc.

### 3. Design C — Ceph-based

This is a completely different approach.

Instead of having:

NFS-01
NFS-02

with replicated/shared storage, you build a distributed storage cluster.

For example:

```text
              Ceph Cluster

        ┌────────┬────────┐
        │        │        │
     Ceph-01  Ceph-02  Ceph-03
```

Each Ceph node contributes storage.

For example:

*   Ceph-01 → disks
*   Ceph-02 → disks
*   Ceph-03 → disks

Ceph distributes and replicates data across the cluster.

Conceptually:

```text
                Ceph
                  │
       ┌──────────┼──────────┐
       │          │          │
     Node 1     Node 2     Node 3
       │          │          │
      Disk       Disk       Disk
```

Suppose you write:

`file.txt`

Ceph can store replicas of the data across different nodes.

So if one node dies:

```text
Ceph-01 ❌

Ceph-02
Ceph-03
    ↓
Data can still be available
```

But where does NFS come in?
Ceph is not simply an NFS server. Ceph provides storage.

You can then put an NFS service/gateway in front of that storage.

Conceptually:

```text
              Kubernetes
                  │
                  │
                 NFS
                  │
                  ▼
             Ceph Storage
          ┌───────┼───────┐
          │       │       │
       Ceph-01 Ceph-02 Ceph-03
```

So:

*   **NFS** ↓ provides the file-sharing protocol
*   **Ceph** ↓ provides the highly available distributed storage

---

## The biggest difference

Here's the easiest comparison:

| Design | Where is the data? | How is data protected? | Complexity |
| :--- | :--- | :--- | :--- |
| **A — DRBD** | Local disks on NFS servers | DRBD replication | 🟡 Medium |
| **B — SAN** | Shared SAN | SAN redundancy | 🟡 Medium/High |
| **C — Ceph** | Distributed across Ceph nodes | Ceph replication | 🔴 High |

Think of them as three different storage strategies:

**A — "Copy my disk to another server"**
```text
NFS-01
  │
  │ DRBD
  ▼
NFS-02

Data is replicated
```

**B — "Both servers use the same storage"**
```text
NFS-01 ──┐
         │
         ▼
        SAN
         ▲
         │
NFS-02 ──┘

Data is in shared storage
```

**C — "Build a distributed storage system"**
```text
       Ceph
     /   |   \
   Node Node Node

Data is distributed/replicated
across the storage cluster
```

---

## What I would choose for your k3s lab

Since you're learning k3s + NFS + Ansible, I'd recommend starting with Design A:

```text
                  k3s
                   │
                   │
             192.168.1.50
                 NFS VIP
                   │
          ┌────────┴────────┐
          │                 │
       NFS-01             NFS-02
       ACTIVE             STANDBY
          │                 │
          └────── DRBD ─────┘
                 │
          replicated data

       Pacemaker + Corosync
```

That lets you learn several important HA concepts at once:

*   **DRBD** → storage replication
*   **Corosync** → cluster communication
*   **Pacemaker** → failover management
*   **VIP** → stable client endpoint
*   **NFS** → file sharing
*   **k3s** → consumes the HA NFS storage

Then later, if you want to learn enterprise distributed storage, you can build a Ceph cluster separately.

One thing to be careful about: a 2-node DRBD/Pacemaker cluster needs proper quorum/fencing (STONITH) design in production. Otherwise, a network partition can create split-brain and potentially corrupt data. For a lab, you can simplify it, but it's important to understand before calling it production-ready.

---

## Additional Concepts (Added Notes)

### What is Split-Brain?
In a 2-node cluster (like Design A), if the network cable connecting `NFS-01` and `NFS-02` breaks, both nodes might think the other one died. 
* `NFS-01` thinks: "Node 2 is dead, I must become ACTIVE!"
* `NFS-02` thinks: "Node 1 is dead, I must become ACTIVE!"
Suddenly, both nodes start writing data to their own disks at the same time independently. When the network is reconnected, the data is corrupted because the two disks no longer match. This is called a **Split-Brain** scenario.

### What is STONITH / Fencing?
To prevent Split-Brain, enterprise clusters use a concept called **STONITH** (Shoot The Other Node In The Head), also known as Fencing. 
If `NFS-01` loses communication with `NFS-02`, before it takes over, it sends a command to a smart power strip or server management interface (like iDRAC/iLO) to literally cut the power to `NFS-02`. 
This guarantees `NFS-02` is dead and cannot write conflicting data, keeping your storage safe!
