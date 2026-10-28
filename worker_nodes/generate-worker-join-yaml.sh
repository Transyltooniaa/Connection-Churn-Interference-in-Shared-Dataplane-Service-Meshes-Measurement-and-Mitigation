#!/usr/bin/env bash

set -Eeuo pipefail

# ------------------------------------------------------------
# Generate Kubernetes kubeadm JoinConfiguration for a worker.
# Run this script on the Kubernetes controller node.
# ------------------------------------------------------------

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v kubeadm >/dev/null 2>&1 ||
    die "kubeadm is not installed on this controller."

command -v openssl >/dev/null 2>&1 ||
    die "openssl is required."

sudo test -r /etc/kubernetes/pki/ca.crt ||
    die "Cannot read /etc/kubernetes/pki/ca.crt."

# ------------------------------------------------------------
# Controller endpoint
# ------------------------------------------------------------

echo
echo "============================================"
echo " Kubernetes Worker Join YAML Generator"
echo "============================================"
echo

# Display available IPv4 addresses to help select the correct one.
echo "Controller IPv4 addresses:"
ip -4 -o addr show scope global |
    awk '{print "  " $2 ": " $4}'

echo
read -r -p "Enter controller IP reachable by workers: " CTRL_IP

[[ -n "$CTRL_IP" ]] ||
    die "Controller IP cannot be empty."

read -r -p "Enter Kubernetes API port [6443]: " CTRL_PORT
CTRL_PORT="${CTRL_PORT:-6443}"

[[ "$CTRL_PORT" =~ ^[0-9]+$ ]] &&
    (( CTRL_PORT >= 1 && CTRL_PORT <= 65535 )) ||
    die "Invalid API port: $CTRL_PORT"

API_ENDPOINT="${CTRL_IP}:${CTRL_PORT}"

# ------------------------------------------------------------
# Worker configuration
# ------------------------------------------------------------

echo
echo "Enter the worker details."
echo

read -r -p "Worker node name [iiitb]: " NODE_NAME
NODE_NAME="${NODE_NAME:-iiitb}"

[[ "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
    die "Invalid Kubernetes node name: $NODE_NAME"

read -r -p "Worker node IP: " NODE_IP

[[ -n "$NODE_IP" ]] ||
    die "Worker node IP cannot be empty."

read -r -p "Output YAML file [worker-join.yaml]: " OUTPUT_FILE
OUTPUT_FILE="${OUTPUT_FILE:-worker-join.yaml}"

# ------------------------------------------------------------
# Generate bootstrap token
# ------------------------------------------------------------

echo
echo "Generating a new Kubernetes bootstrap token..."

TOKEN="$(sudo kubeadm token create)" ||
    die "Failed to create a bootstrap token."

# ------------------------------------------------------------
# Calculate the Kubernetes CA certificate hash
# ------------------------------------------------------------

echo "Calculating Kubernetes CA certificate hash..."

CA_HASH="$(
    sudo openssl x509 \
        -pubkey \
        -in /etc/kubernetes/pki/ca.crt |
    openssl rsa \
        -pubin \
        -outform DER 2>/dev/null |
    openssl dgst -sha256 -hex |
    awk '{print $NF}'
)" || die "Could not calculate the CA certificate hash."

[[ "$CA_HASH" =~ ^[a-f0-9]{64}$ ]] ||
    die "The calculated CA certificate hash is invalid."

# ------------------------------------------------------------
# Generate JoinConfiguration YAML
# ------------------------------------------------------------

cat > "$OUTPUT_FILE" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration

discovery:
  bootstrapToken:
    token: "${TOKEN}"
    apiServerEndpoint: "${API_ENDPOINT}"
    caCertHashes:
      - "sha256:${CA_HASH}"

nodeRegistration:
  name: "${NODE_NAME}"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${NODE_IP}"
EOF

chmod 600 "$OUTPUT_FILE"

# ------------------------------------------------------------
# Display summary
# ------------------------------------------------------------

echo
echo "============================================"
echo " Worker JoinConfiguration generated"
echo "============================================"
echo
echo "Controller endpoint: ${API_ENDPOINT}"
echo "Worker name:         ${NODE_NAME}"
echo "Worker IP:           ${NODE_IP}"
echo "Output file:         ${OUTPUT_FILE}"
echo
echo "Generated YAML:"
cat "$OUTPUT_FILE"

echo
echo "IMPORTANT:"
echo "1. Copy this YAML securely to the worker VM."
echo "2. Run kubeadm join on the worker using this file."
echo "3. Ensure the worker can reach ${API_ENDPOINT}."
echo "4. Do not share the generated YAML publicly; it contains a token."
echo