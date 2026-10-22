echo "===== OS ====="
cat /etc/os-release | grep -E '^(NAME|VERSION_ID)='

echo "===== Kernel ====="
uname -r

echo "===== Containerd ====="
containerd --version
sudo systemctl is-active containerd

echo "===== Kubernetes services ====="
sudo systemctl is-active kubelet || true

echo "===== Swap ====="
swapon --show

echo "===== Cgroup ====="
stat -fc %T /sys/fs/cgroup

echo "===== Network interfaces ====="
ip -br addr