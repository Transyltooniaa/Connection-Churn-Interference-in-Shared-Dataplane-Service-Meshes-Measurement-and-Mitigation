sudo apt-mark unhold kubeadm kubelet kubectl

sudo apt-get install -y \
  kubelet=1.35.9-1.1 \
  kubeadm=1.35.9-1.1 \
  kubectl=1.35.9-1.1

sudo apt-mark hold kubelet kubeadm kubectl

kubeadm version -o short
kubelet --version
kubectl version --client