sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide

sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -o wide