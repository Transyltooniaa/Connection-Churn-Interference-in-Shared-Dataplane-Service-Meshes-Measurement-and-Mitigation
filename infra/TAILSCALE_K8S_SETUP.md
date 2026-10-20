# Kubernetes Cluster Setup — Tailscale Overlay
## Topology: Windows Laptop (controller) + 2 Ubuntu 22.04 VMs (workers)

> **kubeadm cannot run on Windows natively.**
> The controller role (running `kubeadm init`) must be executed on **one of the VMs** OR inside **WSL2 on the laptop**.
> The API-server will advertise the laptop's **Tailscale IP** so both VMs can reach it.

---

## 0. Gather your Tailscale IPs

Run on each machine:
```bash
tailscale ip -4
```

Fill in these values everywhere you see `REPLACE ME`:

| Machine       | Hostname (example) | Tailscale IP       |
|---------------|--------------------|--------------------|
| Laptop (ctrl) | `my-laptop`        | `100.100.CTRL.IP`  <- REPLACE |
| VM-1 (worker1)| `vm-one`           | `100.100.W1.IP`    <- REPLACE |
| VM-2 (worker2)| `vm-two`           | `100.100.W2.IP`    <- REPLACE |

---

## 1. Edit `infra/kubeadm-config.yaml` (already done -- just fill in IPs)

Replace all three placeholders with real values:
```bash
# On your laptop (PowerShell or Git Bash):
sed -i 's/100.100.CTRL.IP/YOUR_CTRL_TAILSCALE_IP/g' infra/kubeadm-config.yaml
```

---

## 2. Run node prerequisites on EVERY node

Copy the script to each machine and run it. Do all three in parallel.

### On VM-1 and VM-2 (SSH in via Tailscale):
```bash
ssh user@100.100.W1.IP   # VM-1
# --- once inside: ---
sudo bash infra/node-prereqs.sh
```
Repeat for VM-2 (`100.100.W2.IP`).

### On the controller (WSL2 on the laptop, or SSH into a dedicated control-plane VM):
```bash
sudo bash infra/node-prereqs.sh
```

> **What this does:** Disables swap, loads kernel modules, installs containerd (systemd cgroup), kubeadm, kubelet, kubectl 1.33, and helm.

---

## 3. Set up Tailscale routing on each node

### On EACH node (VM-1, VM-2, and controller):
```bash
# Allow Kubernetes and Cilium traffic through the Tailscale firewall.
sudo ufw allow in on tailscale0   # if ufw is enabled
sudo ufw allow out on tailscale0

# Ensure FORWARD is allowed for pod-to-pod traffic:
sudo iptables -P FORWARD ACCEPT
```

---

## 4. Initialize the cluster on the controller

> **Important**: `kubeadm init` must run on a **Linux** machine.
> If your laptop is Windows:
> - **Option A (recommended):** Designate one of the VMs as the control plane.
>   Update `advertiseAddress` and `controlPlaneEndpoint` in `kubeadm-config.yaml`
>   to that VM's Tailscale IP instead of the laptop's.
> - **Option B:** Use WSL2 on your Windows laptop (Ubuntu WSL2 instance).

```bash
# On the controller (Linux) -- from the repo root:
sudo kubeadm init \
  --config infra/kubeadm-config.yaml \
  --upload-certs \
  2>&1 | tee kubeadm-init.log

# Set up kubeconfig:
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify:
kubectl get nodes
```

The output will contain a `kubeadm join` command like:
```
kubeadm join 100.100.CTRL.IP:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```
**Save this** -- you'll need it for step 5.

---

## 5. Join the worker nodes

Run on **VM-1** (worker-1, ssp-role=under-test):
```bash
sudo kubeadm join 100.100.CTRL.IP:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Run on **VM-2** (worker-2, ssp-role=loadgen):
```bash
sudo kubeadm join 100.100.CTRL.IP:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

> If the token expired (>24h), regenerate it on the controller:
> ```bash
> kubeadm token create --print-join-command
> ```

---

## 6. Verify all nodes are Ready

Back on the controller:
```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME         STATUS   ROLES           AGE   VERSION   INTERNAL-IP
my-laptop    Ready    control-plane   Xm    v1.33.x   100.100.CTRL.IP
vm-one       Ready    <none>          Xm    v1.33.x   100.100.W1.IP
vm-two       Ready    <none>          Xm    v1.33.x   100.100.W2.IP
```

---

## 7. Install Cilium + Istio ambient

```bash
bash infra/install-cilium-ambient.sh
```

> **Note on Cilium + Tailscale MTU**: Tailscale adds ~60 bytes of overhead.
> If you see MTU-related packet drops, add `--set MTU=1380` to the helm install in install-cilium-ambient.sh.

---

## 8. Label nodes and run full setup

```bash
export REGISTRY=YOUR_DOCKERHUB_USER
export UNDER_TEST_NODE=vm-one    # kubectl get nodes name for VM-1
export LOADGEN_NODE=vm-two       # kubectl get nodes name for VM-2
bash infra/setup-full.sh
```

---

## Troubleshooting

### Workers can't reach the API server
```bash
# From a worker, test connectivity:
curl -k https://100.100.CTRL.IP:6443/healthz
# Should return: ok

# If it times out -- check Tailscale ACL allows port 6443.
# On Tailscale admin console, Access Controls, add rule:
#   {"action": "accept", "src": ["*"], "dst": ["*:6443"]}
```

### kubeadm join fails with certificate error
```bash
# The certSANs in kubeadm-config.yaml must include the controller Tailscale IP.
# If you already ran init without the correct SAN, regenerate the cert:
sudo kubeadm init phase certs apiserver \
  --config infra/kubeadm-config.yaml
sudo systemctl restart kube-apiserver
```

### Cilium pods in CrashLoopBackOff
```bash
kubectl -n kube-system logs ds/cilium | grep -i error
# Common fix for Tailscale: ensure Cilium uses the right interface
# Add to helm install: --set devices="eth0"
```

### Token expired
```bash
# On controller:
kubeadm token create --print-join-command
```
