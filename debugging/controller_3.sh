echo "===== WSL configuration ====="
cat /etc/wsl.conf 2>/dev/null || echo "No /etc/wsl.conf"

echo "===== Cgroup mounts ====="
findmnt -R /sys/fs/cgroup

echo "===== Kernel command line ====="
cat /proc/cmdline

echo "===== Systemd version ====="
systemctl --version | head -n 1

echo "===== Containerd package ====="
dpkg-query -W -f='${Package} ${Version}\n' containerd.io containerd 2>/dev/null

echo "===== Containerd cgroup configuration ====="
sudo containerd config dump 2>/dev/null | grep -i -E 'SystemdCgroup|version ='

echo "===== Swap ====="
swapon --show