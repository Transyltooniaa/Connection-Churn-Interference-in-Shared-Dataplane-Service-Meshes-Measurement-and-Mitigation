echo "===== WSL version ====="
wsl.exe --version 2>/dev/null || true

echo
echo "===== Cgroup v2 mount details ====="
findmnt -no SOURCE,FSTYPE,OPTIONS /sys/fs/cgroup/unified

echo
echo "===== Cgroup v2 root contents ====="
sudo ls -la /sys/fs/cgroup/unified/

echo
echo "===== Cgroup v2 mount controllers ====="
sudo cat /sys/fs/cgroup/unified/cgroup.controllers
sudo cat /sys/fs/cgroup/unified/cgroup.subtree_control

echo
echo "===== WSL networking ====="
ip -brief address
tailscale status