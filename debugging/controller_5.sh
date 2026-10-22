echo "===== Cgroup mounts ====="
findmnt -R /sys/fs/cgroup

echo
echo "===== Current process cgroups ====="
cat /proc/self/cgroup

echo
echo "===== Containerd cgroup settings ====="
sudo containerd config dump | grep -E 'version =|SystemdCgroup|disabled_plugins'

echo
echo "===== Kubernetes component versions ====="
kubeadm version -o short
kubelet --version
kubectl version --client

echo
echo "===== Kubelet status ====="
sudo systemctl is-active kubelet
sudo systemctl status kubelet --no-pager -l | head -25

echo
echo "===== Tailscale address ====="
tailscale ip -4