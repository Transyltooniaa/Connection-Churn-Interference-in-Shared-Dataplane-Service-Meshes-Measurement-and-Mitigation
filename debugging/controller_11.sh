echo "=== Kubernetes versions ==="
kubeadm version -o short
kubelet --version

echo
echo "=== Cgroup filesystem ==="
stat -fc %T /sys/fs/cgroup
stat -fc %T /sys/fs/cgroup/unified

echo
echo "=== Available unified cgroup controllers ==="
cat /sys/fs/cgroup/unified/cgroup.controllers

echo
echo "=== containerd cgroup setting ==="
sudo containerd config dump | grep -i -A 12 'runtimes.runc.options'