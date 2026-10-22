sudo kubeadm init phase upload-config kubelet \
  --config infra/kubeadm-config.yaml \
  --kubeconfig /etc/kubernetes/super-admin.conf

sudo kubeadm init phase addon kube-proxy \
  --config infra/kubeadm-config.yaml \
  --kubeconfig /etc/kubernetes/super-admin.conf

sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  -n kube-system get configmaps kubeadm-config kubelet-config kube-proxy