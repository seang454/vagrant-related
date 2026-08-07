# HA K3s Cluster with HAProxy & Keepalived

This guide walks you through turning your 5 raw Vagrant Virtual Machines into a fully functional, production-grade High Availability Kubernetes cluster.

## Architecture
- **2 Load Balancers**: Running HAProxy and Keepalived (Virtual IP: `192.168.56.8`)
- **3 Control Plane Nodes (Masters)**: Running K3s Server
- **2 Worker Nodes**: Running K3s Agent (IPs: `192.168.56.20`, `192.168.56.21`)

## Prerequisite
Make sure you have run `vagrant up` with the 5-node Vagrantfile and that all 5 machines are running. You will need to open multiple terminal windows to SSH into the different machines simultaneously.

## Phase 1: Setup the Load Balancers (HAProxy + Keepalived)

First, configure the two Load Balancers so they can manage the `192.168.56.8` Virtual IP and route traffic to the master nodes.

### 1. Install Required Software
Open two terminals. In Terminal 1, run `vagrant ssh loadbalancer-1`. In Terminal 2, run `vagrant ssh loadbalancer-2`. 
Run this command on BOTH machines:

```bash
sudo apt-get update
sudo apt-get install haproxy keepalived -y
```

### 2. Configure OS Settings for HAProxy
Because `loadbalancer-2` is the BACKUP node, it won't have the Virtual IP locally on startup. We need to allow it to bind to non-local IPs.
Run this on BOTH machines:

```bash
sudo sysctl -w net.ipv4.ip_nonlocal_bind=1
echo "net.ipv4.ip_nonlocal_bind=1" | sudo tee -a /etc/sysctl.conf
```

### 3. Configure Keepalived (The Virtual IP)
We need to tell `loadbalancer-1` to be the "Master" of the `.8` IP, and `loadbalancer-2` to be the "Backup".

On **loadbalancer-1**, create the configuration file:
```bash
sudo nano /etc/keepalived/keepalived.conf
```

Paste this inside and save:
```text
vrrp_script check_haproxy {
    script "killall -0 haproxy" # Checks if the haproxy process is running
    interval 2                  # Check every 2 seconds
    weight -20                  # Decrease priority by 20 if it fails
}

vrrp_instance VI_1 {
    state MASTER
    interface eth1
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass securepassword
    }
    virtual_ipaddress {
        192.168.56.8/24
    }
    track_script {
        check_haproxy
    }
}
```

On **loadbalancer-2**, do the same thing, but change the state and priority:
```bash
sudo nano /etc/keepalived/keepalived.conf
```

```text
vrrp_script check_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight -20
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth1
    virtual_router_id 51
    priority 90
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass securepassword
    }
    virtual_ipaddress {
        192.168.56.8/24
    }
    track_script {
        check_haproxy
    }
}
```

### 4. Configure HAProxy (The Traffic Router)
Now we tell HAProxy how to route traffic. Do this on BOTH `loadbalancer-1` and `loadbalancer-2`:

```bash
sudo nano /etc/haproxy/haproxy.cfg
```

Add this block to the very bottom of the file:
```haproxy
frontend k8s_api
    bind 192.168.56.8:6443
    mode tcp
    option tcplog
    default_backend k8s_masters

backend k8s_masters
    mode tcp
    option tcp-check
    balance roundrobin
    server master1 192.168.56.10:6443 check
    server master2 192.168.56.11:6443 check
    server master3 192.168.56.12:6443 check
```

Restart the services on BOTH load balancers to apply the changes:
```bash
sudo systemctl restart keepalived
sudo systemctl restart haproxy
```

> **Tip**: Test the VIP! On `loadbalancer-1`, run `ip a`. You should see `192.168.56.8` attached to the `eth1` interface. If you turn off `loadbalancer-1` or stop HAProxy, that IP will teleport to `loadbalancer-2`.

## Phase 2: Setup K3s Kubernetes (The Cluster)

### 1. Initialize the Cluster (Master 1)
Open a new terminal and log into the first master node: `vagrant ssh master-1`. Run the K3s installer. 
*Note: We use `--node-ip` to force K3s to use the Vagrant private network instead of the NAT network.*

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init --tls-san 192.168.56.8 --node-ip 192.168.56.10 --flannel-iface=eth1" sh -
```

Wait about 30 seconds for it to finish. Extract the secret cluster token so the other masters can join:
```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```
Copy the long string of text it outputs.

### 2. Join Master 2 and Master 3
Open a terminal for `master-2` (`vagrant ssh master-2`) and another for `master-3` (`vagrant ssh master-3`). 
Run this command on both of them, replacing `<YOUR_TOKEN>` with the string you copied in the previous step:

**On Master 2:**
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN="<YOUR_TOKEN>" sh -s - server \
  --server https://192.168.56.8:6443 \
  --tls-san 192.168.56.8 \
  --node-ip 192.168.56.11 \
  --flannel-iface=eth1
```

**On Master 3:**
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN="<YOUR_TOKEN>" sh -s - server \
  --server https://192.168.56.8:6443 \
  --tls-san 192.168.56.8 \
  --node-ip 192.168.56.12 \
  --flannel-iface=eth1
```

## Phase 3: Join the Worker Nodes

Worker nodes don't run the control plane (etcd, API server); they just run your application containers. 
Open a terminal for `worker-1` (`vagrant ssh worker-1`) and `worker-2` (`vagrant ssh worker-2`). 

Run this command on both workers, replacing `<YOUR_TOKEN>` with the exact same token you used for the masters:

**On Worker 1:**
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN="<YOUR_TOKEN>" sh -s - agent \
  --server https://192.168.56.8:6443 \
  --node-ip 192.168.56.20 \
  --flannel-iface=eth1
```

**On Worker 2:**
```bash
curl -sfL https://get.k3s.io | K3S_TOKEN="<YOUR_TOKEN>" sh -s - agent \
  --server https://192.168.56.8:6443 \
  --node-ip 192.168.56.21 \
  --flannel-iface=eth1
```

*(Note: Notice we use `agent` instead of `server`, and we don't need `--tls-san` because workers don't serve the Kubernetes API).*

## Phase 4: Verification

Go back to your `master-1` terminal. Let's check if all 5 nodes have successfully formed a High Availability cluster.

```bash
sudo k3s kubectl get nodes
```

You should see an output that looks like this:
```text
NAME       STATUS   ROLES                       AGE     VERSION
master-1   Ready    control-plane,etcd,master   10m     v1.27.4+k3s1
master-2   Ready    control-plane,etcd,master   2m      v1.27.4+k3s1
master-3   Ready    control-plane,etcd,master   2m      v1.27.4+k3s1
worker-1   Ready    <none>                      1m      v1.27.4+k3s1
worker-2   Ready    <none>                      1m      v1.27.4+k3s1
```

## Phase 5: Remote Access (Optional)

To control the cluster directly from your physical host machine (so you don't have to SSH into Vagrant every time):

1. On `master-1`, print the kubeconfig file:
   ```bash
   sudo cat /etc/rancher/k3s/k3s.yaml
   ```
2. Copy the contents and save it on your host machine (e.g., in `~/.kube/config`).
3. Edit the file on your host machine and change the `server` line from `https://127.0.0.1:6443` to point to your load balancer VIP: `https://192.168.56.8:6443`.
4. Run `kubectl get nodes` from your host laptop!
