#!/bin/bash
# ============================================================
# node-prereqs.sh
# SSP Ambient-Mesh Testbed — Run on EVERY NODE before kubeadm
# ============================================================
# Prepares a bare-metal Ubuntu 22.04/24.04 node for:
#   - Kubernetes 1.33 (kubeadm)
#   - Cilium 1.20 (VXLAN, eBPF, BBR bandwidth manager)
#   - Istio 1.31 ambient (ztunnel, cgroup v2)
#
# Run as root (or with sudo):
#   sudo bash infra/node-prereqs.sh
#
# Run on: CONTROLLER, WORKER1, and WORKER2
# ============================================================
set -euo pipefail

echo "=== [0] System info ==="
uname -r
cat /etc/os-release | grep PRETTY

echo "=== [1] Disable swap (required by Kubernetes + Cilium) ==="
swapoff -a
# Make permanent across reboots
sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

echo "=== [2] Load kernel modules for Cilium VXLAN + eBPF ==="
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "=== [3] Set sysctl params for Kubernetes networking ==="
cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
# Required for iptables to see bridged traffic
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                  = 1
# BBR congestion control (Cilium bandwidth manager)
net.core.default_qdisc               = fq
net.ipv4.tcp_congestion_control      = bbr
EOF
sysctl --system

echo "=== [4] Install containerd (CRI) ==="
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release

# Docker's containerd (ships a newer version than distro packages)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${VERSION_CODENAME}) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq containerd.io

# Configure containerd to use systemd cgroup driver (required for Cilium + K8s 1.33)
mkdir -p /etc/containerd
containerd config default | sed \
  's/SystemdCgroup = false/SystemdCgroup = true/' \
  > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
echo "containerd status: $(systemctl is-active containerd)"

echo "=== [5] Install kubeadm, kubelet, kubectl 1.33 ==="
apt-get install -y -qq apt-transport-https
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

echo "=== [6] Install helm (controller node only, no-op on workers) ==="
if command -v helm &>/dev/null; then
  echo "  helm already installed: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "=== [7] Verify ==="
echo "containerd: $(containerd --version)"
echo "kubeadm:    $(kubeadm version -o short)"
echo "kubelet:    $(kubelet --version)"
echo "kubectl:    $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
echo ""
echo "Node prereqs complete. Next steps:"
echo "  CONTROLLER: sudo kubeadm init --config infra/kubeadm-config.yaml --upload-certs"
echo "  WORKERS:    sudo kubeadm join CONTROLLER_IP:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
