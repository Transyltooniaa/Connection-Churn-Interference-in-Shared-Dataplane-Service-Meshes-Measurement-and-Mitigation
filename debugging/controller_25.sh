sudo kubeadm token list

sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  get configmap -n kube-public

sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  get pods -n kube-system

sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  -n kube-system logs kube-controller-manager-laptop-99cr9k26 \
  --since=15m 2>&1 | grep -Ei 'bootstrap|cluster-info|signer|error|forbidden'