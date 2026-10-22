echo "===== SWAP ====="
sudo swapon --show
free -h

echo "===== SERVICES ====="
sudo systemctl is-active containerd
sudo systemctl is-active kubelet

echo "===== API SERVER PORT ====="
sudo ss -lntp | grep ':6443' || true