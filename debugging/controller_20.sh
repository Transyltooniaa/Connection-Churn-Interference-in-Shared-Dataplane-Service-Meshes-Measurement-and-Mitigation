sudo kubectl \
  --kubeconfig=/etc/kubernetes/admin.conf \
  get clusterrolebinding kubeadm:cluster-admins -o yaml

sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf auth can-i list nodes
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf auth can-i create clusterrolebindings