#!/usr/bin/env bash
# SSP Ambient-Mesh testbed:
#   1. Start the local Kubernetes control plane.
#   2. Disable active swap and restart kubelet.
#   3. Ensure shared root-mount propagation on the laptop and workers.
#   4. Start and verify both worker nodes over Tailscale SSH.
#   5. Install Helm if needed.
#   6. Install/upgrade Cilium and restart its agents to apply host fixes.
#   7. Wait for all three nodes to become Ready.
#   8. Optionally install Istio Ambient.
#
# Install as <repo>/infra/cluster-up.sh
#
# Usage:
#   bash infra/cluster-up.sh
#   bash infra/cluster-up.sh --with-istio
#
# Optional environment overrides:
#   CTRL_IP, WORKER1_IP, WORKER2_IP, WORKER1_SSH, WORKER2_SSH
#   KUBECONFIG_PATH, CILIUM_VERSION, HELM_VERSION
#   ISTIO_VERSION, ISTIO_VERSION_EXPECTED
#
# Safety:
#   - Does NOT run kubeadm init or kubeadm reset.
#   - Does NOT delete Kubernetes cluster data.
#   - Disables active swap on the local machine and workers.
#   - Makes the root mount recursively shared on Linux/WSL hosts for Cilium.
#   - Does NOT automatically modify the Windows .wslconfig file.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Paths and configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

CTRL_IP="${CTRL_IP:-100.96.31.124}"
WORKER1_IP="${WORKER1_IP:-100.114.48.94}"
WORKER2_IP="${WORKER2_IP:-100.117.8.27}"

WORKER1_SSH="${WORKER1_SSH:-iiitb@${WORKER1_IP}}"
WORKER2_SSH="${WORKER2_SSH:-iiitb@${WORKER2_IP}}"

# Retry SSH operations because the WSL-to-worker Tailscale path can be intermittent.
# Override these with environment variables if needed.
WORKER_SSH_RETRIES="${WORKER_SSH_RETRIES:-8}"
WORKER_SSH_RETRY_DELAY="${WORKER_SSH_RETRY_DELAY:-10}"
WORKER_SSH_CONNECT_TIMEOUT="${WORKER_SSH_CONNECT_TIMEOUT:-20}"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/kubernetes/super-admin.conf}"

CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
ISTIO_VERSION="${ISTIO_VERSION:-1.31.3}"
ISTIO_VERSION_EXPECTED="${ISTIO_VERSION_EXPECTED:-${ISTIO_VERSION%.*}}"

WITH_ISTIO=0
LOCAL_TS_IP=""
TMP_DIR=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

say() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}

die() {
    printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap cleanup EXIT

kubectl_local() {
    sudo kubectl --kubeconfig="$KUBECONFIG_PATH" "$@"
}

# Cilium mounts /var/run/netns from the host. Container runtimes can reject
# that mount when the host root mount is private. Make root recursively shared
# and verify the effective setting before installing/restarting Cilium.
ensure_local_shared_root_mount() {
    say "Ensuring shared root-mount propagation on the laptop"

    local propagation
    propagation="$(findmnt -n -o PROPAGATION / 2>/dev/null || true)"

    if [[ "$propagation" != *shared* ]]; then
        sudo mount --make-rshared / ||
            die "Could not make the laptop root mount recursively shared. Cilium may fail with the /var/run/netns mount-propagation error."
    fi

    propagation="$(findmnt -n -o PROPAGATION / 2>/dev/null || true)"
    if [[ "$propagation" != *shared* ]]; then
        die "Laptop root mount propagation is '$propagation', not shared. Cannot safely continue with Cilium startup."
    fi

    echo "Laptop root mount propagation: $propagation"
}

# ---------------------------------------------------------------------------
# Command-line arguments
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --with-istio)
            WITH_ISTIO=1
            ;;
        -h|--help)
            cat <<'HELP'
Usage:
  bash infra/cluster-up.sh [--with-istio]

Starts the existing Kubernetes control plane and worker nodes,
disables active swap, installs/upgrades Cilium, and checks cluster health.

Options:
  --with-istio    Install Istio Ambient after Kubernetes and Cilium are ready.
  -h, --help      Show this help.

Environment overrides:
  CTRL_IP
  WORKER1_IP
  WORKER2_IP
  WORKER1_SSH
  WORKER2_SSH
  WORKER_SSH_RETRIES          SSH attempts per worker (default: 8)
  WORKER_SSH_RETRY_DELAY      Seconds between attempts (default: 10)
  WORKER_SSH_CONNECT_TIMEOUT  SSH connection timeout in seconds (default: 20)
  KUBECONFIG_PATH
  CILIUM_VERSION
  HELM_VERSION
  ISTIO_VERSION              Istio version to install (default: 1.31.3)
  ISTIO_VERSION_EXPECTED     Required version prefix (default: 1.31)

This script does not initialize or reset the Kubernetes cluster.
When --with-istio is supplied, the script installs the matching istioctl
binary if it is missing or has a different version.
HELP
            exit 0
            ;;
        *)
            die "Unknown option: $arg. Use --help for usage."
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

say "Checking prerequisites"

have sudo || die "sudo is required."
have curl || die "curl is required. Install it with: sudo apt-get install curl"
have tar || die "tar is required. Install it with: sudo apt-get install tar"
have sha256sum || die "sha256sum is required."
have ssh || die "SSH is required. Install it with: sudo apt-get install openssh-client"
have tailscale || die "Tailscale CLI is missing in WSL."

sudo -v || die "Could not obtain sudo privileges."

# The Kubernetes super-admin kubeconfig is normally root-readable only.
# Check it through sudo instead of checking readability as the normal user.
sudo test -r "$KUBECONFIG_PATH" ||
    die "Cannot read $KUBECONFIG_PATH even with sudo. Check that the kubeconfig exists."

have systemctl || die "systemctl is unavailable. Run this inside the laptop's WSL Ubuntu."
have findmnt || die "findmnt is required to verify mount propagation. Install util-linux if it is missing."

ensure_local_shared_root_mount

# ---------------------------------------------------------------------------
# Local control plane: Tailscale, containerd, swap, kubelet
# ---------------------------------------------------------------------------

say "Starting local Tailscale and containerd"

sudo systemctl start tailscaled ||
    die "Could not start tailscaled on the laptop."

sudo systemctl start containerd ||
    die "Could not start containerd on the laptop."

LOCAL_TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"

[[ -n "$LOCAL_TS_IP" ]] ||
    die "The laptop has no active Tailscale IPv4 address. Check Tailscale."

[[ "$LOCAL_TS_IP" == "$CTRL_IP" ]] ||
    die "Laptop Tailscale IP is '$LOCAL_TS_IP'; expected '$CTRL_IP'. Check the configuration."

say "Checking and disabling active swap on the laptop"

# Kubernetes kubelet defaults to failSwapOn=true.
# Disable active swap before restarting kubelet.
if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then
    warn "Active swap was detected on the laptop:"
    sudo swapon --show || true

    sudo swapoff -a ||
        die "Could not disable swap on the laptop. Check permissions and active swap devices."

    sleep 2
fi

if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then
    sudo swapon --show || true
    die "Swap is still active on the laptop. Kubelet may refuse to start."
fi

say "Restarting local kubelet"

sudo systemctl restart kubelet ||
    die "Could not restart kubelet on the laptop."

sleep 5

if ! sudo systemctl is-active --quiet containerd; then
    sudo systemctl --no-pager --full status containerd || true
    die "Local containerd is not active."
fi

if ! sudo systemctl is-active --quiet kubelet; then
    warn "Kubelet is not active. Recent logs follow:"
    sudo journalctl -u kubelet -n 60 --no-pager || true
    die "Local kubelet failed to start. Resolve the reported error before continuing."
fi

# ---------------------------------------------------------------------------
# Wait for local Kubernetes API
# ---------------------------------------------------------------------------

say "Waiting for the local Kubernetes API"

api_ready=0

for _ in $(seq 1 60); do
    if kubectl_local get --raw='/readyz' >/dev/null 2>&1; then
        api_ready=1
        break
    fi

    sleep 2
done

if [[ "$api_ready" -ne 1 ]]; then
    warn "The Kubernetes API did not become ready. Collecting diagnostics."

    echo
    echo "----- kubelet status -----"
    sudo systemctl --no-pager --full status kubelet || true

    echo
    echo "----- containerd status -----"
    sudo systemctl --no-pager --full status containerd || true

    echo
    echo "----- recent kubelet logs -----"
    sudo journalctl -u kubelet -n 100 --no-pager || true

    echo
    echo "----- local Kubernetes containers -----"
    if have crictl; then
        sudo crictl ps -a || true
    fi

    die "API server did not become ready within 120 seconds. Do not rerun kubeadm init or reset the cluster."
fi

say "Kubernetes API is responding"

kubectl_local get --raw='/readyz' ||
    die "The API readiness endpoint failed."

# ---------------------------------------------------------------------------
# Worker startup over Tailscale SSH
# ---------------------------------------------------------------------------

start_worker() {
    local label="$1"
    local ssh_target="$2"
    local expected_ip="$3"
    local attempt

    say "Checking and starting ${label} (${expected_ip})"

    # The remote actions are safe to retry: service starts, swapoff, and making
    # root mount propagation shared are idempotent. If SSH drops mid-run, the
    # next attempt verifies/reapplies these steps before continuing.
    for ((attempt = 1; attempt <= WORKER_SSH_RETRIES; attempt++)); do
        say "${label}: SSH attempt ${attempt}/${WORKER_SSH_RETRIES}"

        if ssh -tt \
            -o "ConnectTimeout=${WORKER_SSH_CONNECT_TIMEOUT}" \
            -o ConnectionAttempts=1 \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=6 \
            -o TCPKeepAlive=yes \
            "$ssh_target" \
            "set -eu
             sudo -v

             sudo systemctl start tailscaled
             sudo systemctl start containerd

             actual_ip=\$(tailscale ip -4 2>/dev/null | head -n 1 || true)

             if [ \"\$actual_ip\" != '${expected_ip}' ]; then
                 echo 'ERROR: Tailscale IP is' \"\$actual_ip\" ', expected ${expected_ip}'
                 exit 20
             fi

             echo 'Ensuring shared root-mount propagation on ${label}'
             root_propagation=\$(findmnt -n -o PROPAGATION / 2>/dev/null || true)
             case \"\$root_propagation\" in
                 *shared*) ;;
                 *)
                     sudo mount --make-rshared / || {
                         echo 'ERROR: Could not make root mount recursively shared on ${label}'
                         exit 24
                     }
                     ;;
             esac
             root_propagation=\$(findmnt -n -o PROPAGATION / 2>/dev/null || true)
             case \"\$root_propagation\" in
                 *shared*) echo '${label} root mount propagation: '\"\$root_propagation\" ;;
                 *)
                     echo 'ERROR: Root mount propagation is not shared on ${label}: '\"\$root_propagation\"
                     exit 25
                     ;;
             esac

             echo 'Checking active swap on ${label}'
             if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then
                 sudo swapon --show
                 sudo swapoff -a
                 sleep 2
             fi

             if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then
                 sudo swapon --show
                 echo 'ERROR: Swap remains active on ${label}'
                 exit 21
             fi

             echo 'Restarting kubelet on ${label}'
             sudo systemctl restart kubelet
             sleep 3

             sudo systemctl is-active --quiet containerd || {
                 sudo systemctl --no-pager --full status containerd || true
                 exit 22
             }

             sudo systemctl is-active --quiet kubelet || {
                 sudo systemctl --no-pager --full status kubelet || true
                 sudo journalctl -u kubelet -n 60 --no-pager || true
                 exit 23
             }

             echo '${label}: containerd and kubelet are active.'
            "; then
            return 0
        fi

        if (( attempt < WORKER_SSH_RETRIES )); then
            warn "${label}: SSH attempt ${attempt} failed. Waiting ${WORKER_SSH_RETRY_DELAY}s before retrying."
            sleep "$WORKER_SSH_RETRY_DELAY"
        fi
    done

    die "Could not start or verify ${label} after ${WORKER_SSH_RETRIES} SSH attempts. Check worker availability, Tailscale connectivity, SSH authentication, and remote sudo. Target: ${ssh_target}"
}

start_worker "iiitb" "$WORKER1_SSH" "$WORKER1_IP"
start_worker "iiitb-worker2" "$WORKER2_SSH" "$WORKER2_IP"

# ---------------------------------------------------------------------------
# Install Helm if needed
# ---------------------------------------------------------------------------

say "Checking Helm"

if ! have helm; then
    say "Installing Helm ${HELM_VERSION}"

    TMP_DIR="$(mktemp -d)"

    archive="helm-${HELM_VERSION}-linux-amd64.tar.gz"
    url="https://get.helm.sh/${archive}"

    curl -fsSL "$url" -o "$TMP_DIR/$archive" ||
        die "Could not download Helm archive: $url"

    curl -fsSL "${url}.sha256sum" -o "$TMP_DIR/${archive}.sha256sum" ||
        die "Could not download Helm checksum file."

    (
        cd "$TMP_DIR"
        sha256sum --check "${archive}.sha256sum"
    ) || die "Helm archive checksum verification failed. Refusing to install it."

    tar -xzf "$TMP_DIR/$archive" -C "$TMP_DIR" ||
        die "Could not extract Helm archive."

    [[ -x "$TMP_DIR/linux-amd64/helm" ]] ||
        die "The downloaded Helm archive does not contain the expected executable."

    sudo install "$TMP_DIR/linux-amd64/helm" /usr/local/bin/helm ||
        die "Could not install Helm into /usr/local/bin."

    rm -rf -- "$TMP_DIR"
    TMP_DIR=""
fi

helm version --short ||
    die "Helm is installed but could not run."

# ---------------------------------------------------------------------------
# Install/upgrade Cilium
# ---------------------------------------------------------------------------

say "Adding or updating the Cilium Helm repository"

sudo helm repo add cilium https://helm.cilium.io/ >/dev/null ||
    warn "Could not add the Cilium repository. It may already be configured."

sudo helm repo update cilium ||
    die "Could not update the Cilium Helm repository."

say "Installing/upgrading Cilium ${CILIUM_VERSION}"

sudo env KUBECONFIG="$KUBECONFIG_PATH" helm upgrade --install cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set k8sServiceHost="$CTRL_IP" \
    --set k8sServicePort=6443 \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set bpf.masquerade=false \
    --set kubeProxyReplacement=false \
    --set cni.exclusive=false \
    --set bandwidthManager.enabled=true \
    --set bandwidthManager.bbr=false ||
    die "Cilium Helm installation/upgrade failed. Inspect Helm and Kubernetes logs before retrying."

# The root mount propagation fix is a host-level runtime change. Existing
# Cilium pods may have been created before that fix, so recreate the DaemonSet
# pods once to ensure container creation is retried with the corrected mounts.
say "Restarting Cilium agents to apply host mount-propagation fixes"
kubectl_local -n kube-system rollout restart daemonset/cilium ||
    die "Could not restart the Cilium DaemonSet after correcting mount propagation."

# ---------------------------------------------------------------------------
# Wait for Cilium
# ---------------------------------------------------------------------------

say "Waiting for Cilium agents"

kubectl_local -n kube-system rollout status daemonset/cilium --timeout=10m ||
    {
        warn "Cilium agents did not become ready. Current Cilium resources:"
        kubectl_local -n kube-system get pods -o wide || true
        kubectl_local -n kube-system get daemonset cilium -o wide || true
        die "Cilium agent rollout failed."
    }

say "Waiting for the Cilium operator"

kubectl_local -n kube-system rollout status deployment/cilium-operator --timeout=10m ||
    {
        warn "Cilium operator did not become ready. Current Cilium resources:"
        kubectl_local -n kube-system get pods -o wide || true
        die "Cilium operator rollout failed."
    }

# ---------------------------------------------------------------------------
# Wait for all three Kubernetes nodes
# ---------------------------------------------------------------------------

say "Waiting for all three nodes to become Ready"

nodes_ready=0

for _ in $(seq 1 90); do
    ready_count="$(
        kubectl_local get nodes \
            -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
            2>/dev/null |
            grep -c '^True$' || true
    )"

    if [[ "${ready_count:-0}" -ge 3 ]]; then
        nodes_ready=1
        break
    fi

    sleep 2
done

echo
echo "================ Kubernetes nodes ================"
kubectl_local get nodes -o wide || true

echo
echo "================ kube-system pods ================"
kubectl_local -n kube-system get pods -o wide || true

if [[ "$nodes_ready" -ne 1 ]]; then
    echo
    warn "Cilium was installed, but all three nodes did not become Ready in time."

    echo
    echo "----- Node conditions -----"
    kubectl_local describe nodes || true

    echo
    echo "----- Cilium status -----"
    kubectl_local -n kube-system get pods -o wide || true
    kubectl_local -n kube-system get events --sort-by='.lastTimestamp' | tail -n 40 || true

    die "Cluster startup is incomplete. Use the diagnostics above; do not reset or reinitialize the cluster."
fi

# ---------------------------------------------------------------------------
# Optional Istio Ambient installation
# ---------------------------------------------------------------------------

if [[ "$WITH_ISTIO" -eq 1 ]]; then
    # Ensure the requested istioctl version is available locally. This
    # downloads the official Istio release archive only when needed.
    istioctl_path="$(command -v istioctl 2>/dev/null || true)"
    istio_ver=""

    if [[ -n "$istioctl_path" ]]; then
        istio_ver="$("$istioctl_path" version --remote=false 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "$istioctl_path" || "$istio_ver" != *"$ISTIO_VERSION"* ]]; then
        say "Installing istioctl ${ISTIO_VERSION}"

        have uname || die "uname is required to determine the system architecture."

        case "$(uname -m)" in
            x86_64|amd64)
                ISTIO_TARGET_ARCH="x86_64"
                ;;
            aarch64|arm64)
                ISTIO_TARGET_ARCH="arm64"
                ;;
            *)
                die "Unsupported architecture '$(uname -m)' for automatic istioctl installation."
                ;;
        esac

        TMP_DIR="$(mktemp -d)"

        curl -fsSL https://istio.io/downloadIstio |
            (
                cd "$TMP_DIR"
                ISTIO_VERSION="$ISTIO_VERSION" \
                TARGET_ARCH="$ISTIO_TARGET_ARCH" sh -
            ) ||
            die "Could not download/extract Istio ${ISTIO_VERSION}. Check network access and the requested release version."

        downloaded_istioctl="$TMP_DIR/istio-${ISTIO_VERSION}/bin/istioctl"

        [[ -x "$downloaded_istioctl" ]] ||
            die "The Istio download did not contain an executable istioctl at the expected path: $downloaded_istioctl"

        sudo install -m 0755 "$downloaded_istioctl" /usr/local/bin/istioctl ||
            die "Could not install istioctl into /usr/local/bin."

        rm -rf -- "$TMP_DIR"
        TMP_DIR=""
        istioctl_path="/usr/local/bin/istioctl"
        istio_ver="$("$istioctl_path" version --remote=false 2>/dev/null | head -n 1 || true)"
    fi

    echo
    echo "istioctl local version: ${istio_ver:-unknown}"

    if [[ "$istio_ver" != *"$ISTIO_VERSION_EXPECTED"* ]]; then
        die "Expected istioctl ${ISTIO_VERSION_EXPECTED}.x, but found '${istio_ver}'. Verify version compatibility before installing Istio."
    fi

    say "Installing/upgrading Istio Ambient"

    sudo env KUBECONFIG="$KUBECONFIG_PATH" \
        "$istioctl_path" install \
        --set profile=ambient \
        --skip-confirmation ||
        die "Istio Ambient installation failed."

    say "Waiting for the Istio ztunnel DaemonSet"

    kubectl_local -n istio-system rollout status daemonset/ztunnel --timeout=10m ||
        {
            warn "ztunnel did not become ready."
            kubectl_local -n istio-system get pods -o wide || true
            die "Istio Ambient startup is incomplete."
        }

    echo
    echo "================ istio-system pods ================"
    kubectl_local -n istio-system get pods -o wide || true

elif have istioctl; then
    echo
    echo "istioctl is installed, but Istio Ambient installation was not requested."
    echo "When ready, run: bash infra/cluster-up.sh --with-istio"

else
    echo
    echo "Istio Ambient was not installed because istioctl is not installed."
fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

say "Cluster-up check finished successfully"

echo
echo "Control plane: ${CTRL_IP}"
echo "Worker 1:      ${WORKER1_IP}"
echo "Worker 2:      ${WORKER2_IP}"
echo "Cilium:        ${CILIUM_VERSION}"

if [[ "$WITH_ISTIO" -eq 1 ]]; then
    echo "Istio Ambient: installation requested and rollout checked"
else
    echo "Istio Ambient: not requested"
fi

echo
echo "Final node status:"
kubectl_local get nodes -o wide

echo
echo "Active swap was checked and disabled for this run."
echo "For persistent WSL swap configuration, review the Windows .wslconfig file."