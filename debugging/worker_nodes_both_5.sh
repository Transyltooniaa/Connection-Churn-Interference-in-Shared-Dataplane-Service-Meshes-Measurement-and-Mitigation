hostname
kubeadm version -o short
kubelet --version
containerd --version
stat -fc %T /sys/fs/cgroup
sudo systemctl is-active containerd