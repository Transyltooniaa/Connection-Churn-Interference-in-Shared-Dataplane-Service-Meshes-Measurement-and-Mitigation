echo "===== KUBELET STATUS ====="
sudo systemctl status kubelet --no-pager -l

echo "===== RECENT KUBELET ERRORS ====="
sudo journalctl -u kubelet -n 100 --no-pager

echo "===== CONTAINERD KUBERNETES CONTAINERS ====="
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a

echo "===== STATIC POD MANIFESTS ====="
sudo ls -lh /etc/kubernetes/manifests/