# Step-by-Step: Standard Kubernetes (kubeadm) HA Cluster

This guide walks you through building a standard, full-blown Kubernetes cluster (using `kubeadm`) in High Availability mode on your Vagrant VMs. This is the industry-standard way to install K8s, as opposed to lightweight distributions like K3s.

## Architecture Setup
- **2 Load Balancers**: `192.168.56.8` (Virtual IP)
- **3 Master Nodes**: `192.168.56.10`, `192.168.56.11`, `192.168.56.12`
- **2 Worker Nodes**: `192.168.56.20`, `192.168.56.21` (Example IPs)

> [!WARNING]
> Standard K8s is heavier than K3s. Ensure your Vagrant VMs for the Master nodes have at least **2 CPUs and 2GB of RAM** each, otherwise `kubeadm` will throw an error and refuse to install.

## Prerequisites

### 1. VMware Workstation Users (Important!)
Vagrant does not support VMware out-of-the-box. Before running `vagrant up`, you MUST install the integration tools. 

**Step A: Install the Vagrant VMware Utility (.msi)**
1. Download the **Vagrant VMware Utility** from HashiCorp: [https://developer.hashicorp.com/vagrant/downloads/vmware](https://developer.hashicorp.com/vagrant/downloads/vmware)
2. You will get a `.msi` installer file. You MUST double-click this file and install it manually:
   * **Double-click** the `.msi` file.
   * Click **Yes** on the Windows Security prompt.
   * Click **Next** on the Welcome screen.
   * Accept the License Agreement and click **Next**.
   * Leave the Destination Folder as default and click **Next**.
   * Click **Install**, wait for the green bar, then click **Finish**.
   * *(Note: Once finished, you can safely delete the .msi file from your computer!)*
3. **Why is this required?** Vagrant cannot talk to VMware Workstation directly. This utility acts as a "translator bridge" between the two programs. Because it controls VMware at a deep system level, it installs a background Windows Service and generates security certificates, which is why it requires your manual Administrator approval to install!

**Step B: Install the Vagrant Plugin**
Open PowerShell as an Administrator and install the plugin by running:
```powershell
vagrant plugin install vagrant-vmware-desktop
```

### 2. Boot the VMs
Make sure you have run `vagrant up` with the 7-node Vagrantfile and that all 7 machines are running. You will need to open multiple terminal windows to SSH into the different machines simultaneously.

---

## Phase 1: Setup the Load Balancers (HAProxy + Keepalived)

*This is identical to the K3s setup. If you already have your load balancers running from the previous guide, you can skip to Phase 2.*

### 🖥️ [ON: loadbalancer-1 AND loadbalancer-2]
**1. Install software on BOTH load balancers:**
```bash
sudo apt-get update
sudo apt-get install haproxy keepalived -y
sudo sysctl -w net.ipv4.ip_nonlocal_bind=1
echo "net.ipv4.ip_nonlocal_bind=1" | sudo tee -a /etc/sysctl.conf
```

### 🖥️ [ON: loadbalancer-1 AND loadbalancer-2]
**2. Configure HAProxy (`/etc/haproxy/haproxy.cfg`) on BOTH load balancers:**
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

### 🖥️ [ON: loadbalancer-1 AND loadbalancer-2]
**3. Configure Keepalived (`/etc/keepalived/keepalived.conf`):**
Set `loadbalancer-1` as `MASTER` (Priority 100) and `loadbalancer-2` as `BACKUP` (Priority 90) for the VIP `192.168.56.8`. Restart both services (`sudo systemctl restart haproxy keepalived`).

---

## Phase 2: Prepare ALL Kubernetes Nodes

> [!IMPORTANT]
> **🖥️ [ON: ALL MASTERS AND ALL WORKERS]**
> You must run EVERY SINGLE COMMAND in Phase 2 on `master-1`, `master-2`, `master-3`, `worker-1`, AND `worker-2`!

### 1. Disable Swap
Kubelet will refuse to run if swap is enabled.
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 2. Configure Kernel Modules & Networking
K8s requires specific kernel modules and IPv4 forwarding to route traffic between pods.
```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 3. Install the Container Runtime (containerd)
Standard K8s requires a runtime. We will use `containerd`.
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key (containerd is hosted here)
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add the repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd.io

# Configure containerd to use systemd for cgroups (Required by K8s)
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### 4. Install Kubeadm, Kubelet, and Kubectl
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Download the public signing key for the Kubernetes package repositories
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the appropriate Kubernetes apt repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install the tools and lock their versions
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

## Phase 3: Initialize the Cluster 

### 🖥️ [ON: master-1 ONLY]
Now we build the cluster. Log into `master-1` and run the initialization command. 
* Note 1: We specify the Load Balancer VIP (`192.168.56.8`).
* Note 2: We specify `--apiserver-advertise-address` so K8s binds to the Vagrant private network (`eth1`), not the NAT network.
* Note 3: We specify `--pod-network-cidr` because our networking plugin (Flannel) requires it.

```bash
sudo kubeadm init \
  --control-plane-endpoint "192.168.56.8:6443" \
  --upload-certs \
  --apiserver-advertise-address=192.168.56.10 \
  --pod-network-cidr=10.244.0.0/16
```

> [!IMPORTANT]
> When `kubeadm init` finishes successfully, **DO NOT CLEAR YOUR SCREEN**. It will output specific `kubeadm join` commands with secure tokens and hashes. **Copy these somewhere safe!**

### 🖥️ [ON: master-1 ONLY]
Next, set up your local `kubectl` access:
```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### 🖥️ [ON: master-1 ONLY]
Finally, install the Networking Plugin (Flannel):
```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```
Run `kubectl get nodes` and `kubectl get pods -n kube-system`. Wait until all pods are `Running` and the node is `Ready`.

---

## Phase 4: Join Additional Masters 

You will run the command that `kubeadm init` generated for joining **control-plane** nodes, but we need to add the `--apiserver-advertise-address` flag so it binds to the correct Vagrant network interface.

### 🖥️ [ON: master-2 ONLY]
```bash
sudo kubeadm join 192.168.56.8:6443 \
  --token <your_token> \
  --discovery-token-ca-cert-hash sha256:<your_hash> \
  --control-plane --certificate-key <your_cert_key> \
  --apiserver-advertise-address=192.168.56.11
```

### 🖥️ [ON: master-3 ONLY]
```bash
sudo kubeadm join 192.168.56.8:6443 \
  --token <your_token> \
  --discovery-token-ca-cert-hash sha256:<your_hash> \
  --control-plane --certificate-key <your_cert_key> \
  --apiserver-advertise-address=192.168.56.12
```

---

## Phase 5: Verification

### 🖥️ [ON: master-1 ONLY]
Go back to `master-1` and check your highly available standard Kubernetes cluster:

```bash
kubectl get nodes
```

You should see `master-1`, `master-2`, and `master-3` all in the `Ready` state and sharing the `control-plane` role!

---

## Phase 6: Join Worker Nodes

Worker nodes only run application workloads, so they do NOT need the `--control-plane` flag or the `--certificate-key` when joining. 

When you ran `kubeadm init` on `master-1`, it outputted two join commands. Use the **second** one (the shorter one) on your worker nodes. It will look like this:

### 🖥️ [ON: worker-1 AND worker-2]
```bash
sudo kubeadm join 192.168.56.8:6443 \
  --token <your_token> \
  --discovery-token-ca-cert-hash sha256:<your_hash>
```

### 🖥️ [ON: master-1 ONLY]
Go back to `master-1` and run `kubectl get nodes`. You should now see all 5 Kubernetes nodes in the `Ready` state!
