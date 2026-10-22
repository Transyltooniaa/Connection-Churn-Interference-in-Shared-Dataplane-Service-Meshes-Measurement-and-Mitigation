# Disable swap for this session
sudo swapoff -a

# Stop kubelet while the cluster is being rebuilt
sudo systemctl stop kubelet

# Inspect cgroup mounts
findmnt -T /sys/fs/cgroup -o TARGET,FSTYPE,OPTIONS
cat /proc/self/cgroup

# Check containerd and kubelet
sudo systemctl is-active containerd
sudo systemctl status kubelet --no-pager -l