echo "===== Kubelet error log ====="
sudo journalctl -u kubelet -n 80 --no-pager

echo
echo "===== Kubelet configuration files ====="
sudo ls -la /var/lib/kubelet/

echo
echo "===== Containerd service log ====="
sudo journalctl -u containerd -n 30 --no-pager