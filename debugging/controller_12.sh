echo "=== WSL kernel ==="
uname -r

echo
echo "=== Cgroup mounts ==="
findmnt -t cgroup,cgroup2

echo
echo "=== Cgroup controller files ==="
sudo find /sys/fs/cgroup -maxdepth 3 -name cgroup.controllers -print

echo
echo "=== WSL configuration ==="
cat /etc/wsl.conf