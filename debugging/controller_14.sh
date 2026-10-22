# Back up the existing package repository configuration
sudo mkdir -p ~/k8s-rebuild-backup
sudo cp -a /etc/apt/sources.list.d ~/k8s-rebuild-backup/ 2>/dev/null || true

# Install repository prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl gpg

# Configure the Kubernetes v1.35 repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Refresh package metadata
sudo apt-get update

# Show available package versions before installing
apt-cache madison kubelet kubeadm kubectl