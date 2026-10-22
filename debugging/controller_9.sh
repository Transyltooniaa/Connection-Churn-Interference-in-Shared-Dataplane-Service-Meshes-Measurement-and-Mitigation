echo "===== WSL configuration ====="
cat /etc/wsl.conf

echo
echo "===== Kernel command line ====="
cat /proc/cmdline

echo
echo "===== Cgroup v2 controllers ====="
cat /sys/fs/cgroup/unified/cgroup.controllers

echo
echo "===== Systemd version ====="
systemctl --version | head -1

echo
echo "===== Kubelet restart state ====="
sudo systemctl is-active kubelet