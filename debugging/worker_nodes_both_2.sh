sudo kubeadm reset -f
sudo systemctl stop kubelet

# Remove stale CNI configuration and allocation state
sudo rm -rf /etc/cni/net.d/*
sudo rm -rf /var/lib/cni/

# Remove the old Flannel interface, if it still exists
if ip link show flannel.1 >/dev/null 2>&1; then
    sudo ip link delete flannel.1
fi

sudo systemctl restart containerd
sudo systemctl is-active containerd