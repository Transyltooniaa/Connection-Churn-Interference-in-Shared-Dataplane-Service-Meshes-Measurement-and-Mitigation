# Configure the Kubernetes v1.35 package repository
sudo apt-get update
sudo apt-get install -y ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Remove holds from the old versions
sudo apt-mark unhold kubeadm kubelet kubectl

# Refresh package metadata
sudo apt-get update

# Upgrade to the exact same Kubernetes version as the laptop
sudo apt-get install -y \
  kubeadm=1.35.9-1.1 \
  kubelet=1.35.9-1.1 \
  kubectl=1.35.9-1.1

# Hold the new versions
sudo apt-mark hold kubeadm kubelet kubectl

# Verify
kubeadm version -o short
kubelet --version
kubectl version --client