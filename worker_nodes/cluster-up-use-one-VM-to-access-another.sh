#!/usr/bin/env bash
# Cluster startup with direct SSH and worker-as-gateway fallback.
# Run as your normal WSL user: bash infra/cluster-up.sh [--with-istio]
# Do NOT run the entire script with sudo.

set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

CTRL_IP="${CTRL_IP:-100.96.31.124}"
WORKER1_IP="${WORKER1_IP:-100.114.48.94}"
WORKER2_IP="${WORKER2_IP:-100.117.8.27}"
WORKER1_SSH="${WORKER1_SSH:-iiitb@${WORKER1_IP}}"
WORKER2_SSH="${WORKER2_SSH:-iiitb@${WORKER2_IP}}"
WORKER_SSH_RETRIES="${WORKER_SSH_RETRIES:-4}"
WORKER_SSH_RETRY_DELAY="${WORKER_SSH_RETRY_DELAY:-5}"
WORKER_SSH_CONNECT_TIMEOUT="${WORKER_SSH_CONNECT_TIMEOUT:-10}"
WORKER_PREFLIGHT_TIMEOUT="${WORKER_PREFLIGHT_TIMEOUT:-8}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/kubernetes/super-admin.conf}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
ISTIO_VERSION="${ISTIO_VERSION:-1.31.3}"
ISTIO_VERSION_EXPECTED="${ISTIO_VERSION_EXPECTED:-${ISTIO_VERSION%.*}}"
WITH_ISTIO=0
TMP_DIR=""
WORKER1_ROUTE=skip
WORKER2_ROUTE=skip
WORKER1_STARTED=0
WORKER2_STARTED=0
SKIPPED_WORKER=0

say(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die(){ printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
cleanup(){ [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
kubectl_local(){ sudo kubectl --kubeconfig="$KUBECONFIG_PATH" "$@"; }

for arg in "$@"; do
  case "$arg" in
    --with-istio) WITH_ISTIO=1 ;;
    -h|--help)
      echo "Usage: bash infra/cluster-up.sh [--with-istio]"
      echo "Run as normal WSL user, not with sudo. Direct SSH is tested first;"
      echo "the reachable worker is used as an SSH gateway for its peer if needed."
      exit 0 ;;
    *) die "Unknown option: $arg (use --help)." ;;
  esac
done

# Interactive SSH is intentional: unlike BatchMode=yes, this permits SSH
# authentication prompts. -tt keeps remote sudo/password prompts visible.
ssh_direct_probe(){
  local label="$1" target="$2"
  say "Testing direct SSH to ${label} (${target})"
  ssh -tt -o "ConnectTimeout=${WORKER_PREFLIGHT_TIMEOUT}" \
    -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 \
    "$target" 'printf "SSH_COMMAND_OK "; hostname; whoami' </dev/tty
}

# Nested SSH through gateway. Quote the nested command before passing it to
# the gateway shell; the TTY carries prompts back to the local terminal.
ssh_gateway_probe(){
  local label="$1" gateway="$2" target="$3" nested
  say "Testing ${label} through gateway ${gateway}"
  printf -v nested 'ssh -tt -o ConnectTimeout=%q -o ConnectionAttempts=1 %q %q' \
    "$WORKER_PREFLIGHT_TIMEOUT" "$target" 'printf "GATEWAY_SSH_OK "; hostname; whoami'
  ssh -tt -o "ConnectTimeout=${WORKER_PREFLIGHT_TIMEOUT}" \
    -o ConnectionAttempts=1 "$gateway" "$nested" </dev/tty
}

# route = direct, via1, or via2
run_on_worker(){
  local route="$1" target="$2" remote_command="$3" gateway nested quoted_remote
  case "$route" in
    direct)
      ssh -tt -o "ConnectTimeout=${WORKER_SSH_CONNECT_TIMEOUT}" \
        -o ConnectionAttempts=1 -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=6 "$target" "$remote_command" </dev/tty ;;
    via1|via2)
      if [[ "$route" == via1 ]]; then gateway="$WORKER1_SSH"; else gateway="$WORKER2_SSH"; fi
      printf -v quoted_remote '%q' "$remote_command"
      printf -v nested 'ssh -tt -o ConnectTimeout=%q -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=6 %q %s' \
        "$WORKER_SSH_CONNECT_TIMEOUT" "$target" "$quoted_remote"
      ssh -tt -o "ConnectTimeout=${WORKER_SSH_CONNECT_TIMEOUT}" \
        -o ConnectionAttempts=1 -o ServerAliveInterval=5 -o ServerAliveCountMax=6 \
        "$gateway" "$nested" </dev/tty ;;
    *) echo "Invalid route '$route'" >&2; return 2 ;;
  esac
}

preflight_workers(){
  local w1=0 w2=0
  say "Checking SSH routes before changing any cluster services"
  echo "SSH and sudo prompts will be shown in this terminal; attempts have timeouts."
  if ssh_direct_probe "Worker 1" "$WORKER1_SSH"; then w1=1; else warn "Worker 1 direct SSH failed."; fi
  if ssh_direct_probe "Worker 2" "$WORKER2_SSH"; then w2=1; else warn "Worker 2 direct SSH failed."; fi
  (( w1 == 0 )) || WORKER1_ROUTE=direct
  (( w2 == 0 )) || WORKER2_ROUTE=direct

  if (( w1 == 1 && w2 == 0 )); then
    if ssh_gateway_probe "Worker 2" "$WORKER1_SSH" "$WORKER2_SSH"; then WORKER2_ROUTE=via1; fi
  elif (( w2 == 1 && w1 == 0 )); then
    if ssh_gateway_probe "Worker 1" "$WORKER2_SSH" "$WORKER1_SSH"; then WORKER1_ROUTE=via2; fi
  fi

  echo
  echo "================ Worker SSH routes ================"
  echo "Worker 1 ($WORKER1_IP): $WORKER1_ROUTE"
  echo "Worker 2 ($WORKER2_IP): $WORKER2_ROUTE"
  if [[ "$WORKER1_ROUTE" == skip && "$WORKER2_ROUTE" == skip ]]; then
    die "Neither worker is reachable directly or through the other worker. No local kubelet restart, swap/mount change, Helm operation, or Cilium change was attempted."
  fi
  if [[ "$WORKER1_ROUTE" == skip || "$WORKER2_ROUTE" == skip ]]; then
    SKIPPED_WORKER=1
    warn "One worker has no usable SSH route; only reachable worker(s) will be managed."
  fi
}

ensure_local_shared_root_mount(){
  say "Ensuring shared root-mount propagation on the laptop"
  local p
  p="$(findmnt -n -o PROPAGATION / 2>/dev/null || true)"
  if [[ "$p" != *shared* ]]; then sudo mount --make-rshared / || die "Could not make laptop root mount shared."; fi
  p="$(findmnt -n -o PROPAGATION / 2>/dev/null || true)"
  [[ "$p" == *shared* ]] || die "Laptop root mount propagation is '$p', not shared."
  echo "Laptop root mount propagation: $p"
}

start_worker(){
  local label="$1" target="$2" expected_ip="$3" route="$4" attempt cmd
  say "Starting/verifying ${label} via ${route}"
  cmd="set -eu
sudo -v
sudo systemctl start tailscaled
sudo systemctl start containerd
actual_ip=\$(tailscale ip -4 2>/dev/null | head -n 1 || true)
if [ \"\$actual_ip\" != '${expected_ip}' ]; then echo 'ERROR: Tailscale IP is' \"\$actual_ip\" ', expected ${expected_ip}'; exit 20; fi
p=\$(findmnt -n -o PROPAGATION / 2>/dev/null || true)
case \"\$p\" in *shared*) ;; *) sudo mount --make-rshared / ;; esac
p=\$(findmnt -n -o PROPAGATION / 2>/dev/null || true)
case \"\$p\" in *shared*) echo 'Root propagation:' \"\$p\" ;; *) echo 'ERROR: root mount is not shared'; exit 25 ;; esac
if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then sudo swapon --show; sudo swapoff -a; sleep 2; fi
if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then echo 'ERROR: swap remains active'; exit 21; fi
sudo systemctl restart kubelet
sleep 3
sudo systemctl is-active --quiet containerd || { sudo systemctl status containerd --no-pager || true; exit 22; }
sudo systemctl is-active --quiet kubelet || { sudo systemctl status kubelet --no-pager || true; sudo journalctl -u kubelet -n 60 --no-pager || true; exit 23; }
echo '${label}: containerd and kubelet are active.'"
  for ((attempt=1; attempt<=WORKER_SSH_RETRIES; attempt++)); do
    echo "${label}: attempt ${attempt}/${WORKER_SSH_RETRIES}"
    if run_on_worker "$route" "$target" "$cmd"; then return 0; fi
    if (( attempt < WORKER_SSH_RETRIES )); then
      warn "${label}: attempt failed; retrying in ${WORKER_SSH_RETRY_DELAY}s."
      sleep "$WORKER_SSH_RETRY_DELAY"
    fi
  done
  return 1
}

# ---------------------------- prerequisites/preflight -------------------------
say "Checking prerequisites"
for c in sudo curl tar sha256sum ssh tailscale systemctl findmnt; do have "$c" || die "$c is required in WSL."; done
sudo -v || die "Could not obtain local sudo privileges."
sudo test -r "$KUBECONFIG_PATH" || die "Cannot read kubeconfig $KUBECONFIG_PATH."
say "Ensuring local Tailscale is running"
sudo systemctl start tailscaled || die "Could not start local tailscaled."
local_ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
[[ -n "$local_ip" ]] || die "No active local Tailscale IPv4 address."
[[ "$local_ip" == "$CTRL_IP" ]] || die "Local Tailscale IP is '$local_ip'; expected '$CTRL_IP'."
preflight_workers

# ------------------------------ local control plane --------------------------
say "Starting local containerd"
sudo systemctl start containerd || die "Could not start local containerd."
ensure_local_shared_root_mount
say "Checking/disabling active swap on laptop"
if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then sudo swapon --show; sudo swapoff -a || die "Could not disable local swap."; fi
if sudo swapon --noheadings --show 2>/dev/null | grep -q .; then die "Swap is still active on laptop."; fi
say "Restarting local kubelet"
sudo systemctl restart kubelet || die "Could not restart local kubelet."
sleep 5
sudo systemctl is-active --quiet containerd || die "Local containerd is not active."
if ! sudo systemctl is-active --quiet kubelet; then sudo journalctl -u kubelet -n 60 --no-pager || true; die "Local kubelet is not active."; fi

say "Waiting for local Kubernetes API"
api_ready=0
for _ in $(seq 1 60); do
  if kubectl_local get --raw=/readyz >/dev/null 2>&1; then api_ready=1; break; fi
  sleep 2
done
if (( api_ready == 0 )); then
  sudo systemctl status kubelet --no-pager --full || true
  sudo journalctl -u kubelet -n 100 --no-pager || true
  have crictl && sudo crictl ps -a || true
  die "API server did not become ready within 120 seconds. Do not run kubeadm init/reset."
fi
say "Kubernetes API is responding"

# -------------------------------- worker startup ------------------------------
if [[ "$WORKER1_ROUTE" != skip ]]; then
  if start_worker "Worker 1" "$WORKER1_SSH" "$WORKER1_IP" "$WORKER1_ROUTE"; then WORKER1_STARTED=1; else warn "Worker 1 failed to start."; SKIPPED_WORKER=1; fi
fi
if [[ "$WORKER2_ROUTE" != skip ]]; then
  if start_worker "Worker 2" "$WORKER2_SSH" "$WORKER2_IP" "$WORKER2_ROUTE"; then WORKER2_STARTED=1; else warn "Worker 2 failed to start."; SKIPPED_WORKER=1; fi
fi
if (( WORKER1_STARTED == 0 && WORKER2_STARTED == 0 )); then die "Neither worker could be started/verified. Skipping Helm/Cilium changes."; fi
if (( WORKER1_STARTED == 0 || WORKER2_STARTED == 0 )); then SKIPPED_WORKER=1; fi

# ------------------------------------ Helm ------------------------------------
say "Checking Helm"
if ! have helm; then
  say "Installing Helm ${HELM_VERSION}"
  TMP_DIR="$(mktemp -d)"
  archive="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  url="https://get.helm.sh/${archive}"
  curl -fsSL "$url" -o "$TMP_DIR/$archive" || die "Could not download Helm archive."
  curl -fsSL "${url}.sha256sum" -o "$TMP_DIR/${archive}.sha256sum" || die "Could not download Helm checksum."
  (cd "$TMP_DIR" && sha256sum --check "${archive}.sha256sum") || die "Helm checksum verification failed."
  tar -xzf "$TMP_DIR/$archive" -C "$TMP_DIR" || die "Could not extract Helm."
  [[ -x "$TMP_DIR/linux-amd64/helm" ]] || die "Helm executable missing."
  sudo install "$TMP_DIR/linux-amd64/helm" /usr/local/bin/helm || die "Could not install Helm."
  rm -rf -- "$TMP_DIR"; TMP_DIR=""
fi
helm version --short || die "Helm cannot run."

# ----------------------------------- Cilium -----------------------------------
say "Adding/updating Cilium Helm repository"
sudo helm repo add cilium https://helm.cilium.io/ >/dev/null || warn "Cilium repo may already exist."
sudo helm repo update cilium || die "Could not update Cilium repo."
say "Installing/upgrading Cilium ${CILIUM_VERSION}"
sudo env KUBECONFIG="$KUBECONFIG_PATH" helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" --namespace kube-system \
  --set ipam.mode=kubernetes --set k8sServiceHost="$CTRL_IP" --set k8sServicePort=6443 \
  --set routingMode=tunnel --set tunnelProtocol=vxlan --set bpf.masquerade=false \
  --set kubeProxyReplacement=false --set cni.exclusive=false \
  --set bandwidthManager.enabled=true --set bandwidthManager.bbr=false ||
  die "Cilium Helm installation/upgrade failed."
say "Restarting Cilium agents"
kubectl_local -n kube-system rollout restart daemonset/cilium || die "Could not restart Cilium DaemonSet."
if (( SKIPPED_WORKER == 0 )); then
  kubectl_local -n kube-system rollout status daemonset/cilium --timeout=10m || { kubectl_local -n kube-system get pods -o wide || true; die "Cilium rollout failed."; }
else
  warn "At least one worker is unavailable; Cilium DaemonSet rollout may remain incomplete."
  kubectl_local -n kube-system get daemonset cilium -o wide || true
  kubectl_local -n kube-system get pods -o wide || true
fi
say "Waiting for Cilium operator"
kubectl_local -n kube-system rollout status deployment/cilium-operator --timeout=10m || { kubectl_local -n kube-system get pods -o wide || true; die "Cilium operator is not ready."; }

# ------------------------------- node readiness ------------------------------
expected=1
(( WORKER1_STARTED == 1 )) && (( expected += 1 ))
(( WORKER2_STARTED == 1 )) && (( expected += 1 ))
say "Waiting for at least ${expected} Ready node(s)"
ready=0
for _ in $(seq 1 90); do
  count="$(kubectl_local get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c '^True$' || true)"
  if [[ "${count:-0}" -ge "$expected" ]]; then ready=1; break; fi
  sleep 2
done
echo; echo "================ Kubernetes nodes ================"
kubectl_local get nodes -o wide || true
echo; echo "================ kube-system pods ================"
kubectl_local -n kube-system get pods -o wide || true
if (( ready == 0 )); then
  kubectl_local describe nodes || true
  kubectl_local -n kube-system get events --sort-by=.lastTimestamp | tail -n 40 || true
  die "Expected nodes did not become Ready. Do not reset/reinitialize the cluster."
fi

# ---------------------------- optional Istio Ambient -------------------------
if (( WITH_ISTIO == 1 )); then
  istioctl_path="$(command -v istioctl 2>/dev/null || true)"
  istio_ver=""
  [[ -z "$istioctl_path" ]] || istio_ver="$("$istioctl_path" version --remote=false 2>/dev/null | head -n 1 || true)"
  if [[ -z "$istioctl_path" || "$istio_ver" != *"$ISTIO_VERSION"* ]]; then
    say "Installing istioctl ${ISTIO_VERSION}"
    case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=arm64 ;; *) die "Unsupported architecture $(uname -m)." ;; esac
    TMP_DIR="$(mktemp -d)"
    curl -fsSL https://istio.io/downloadIstio | (cd "$TMP_DIR" && ISTIO_VERSION="$ISTIO_VERSION" TARGET_ARCH="$arch" sh -) || die "Istio download failed."
    [[ -x "$TMP_DIR/istio-${ISTIO_VERSION}/bin/istioctl" ]] || die "Downloaded istioctl missing."
    sudo install -m 0755 "$TMP_DIR/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/istioctl || die "Could not install istioctl."
    rm -rf -- "$TMP_DIR"; TMP_DIR=""
    istioctl_path=/usr/local/bin/istioctl
    istio_ver="$("$istioctl_path" version --remote=false 2>/dev/null | head -n 1 || true)"
  fi
  [[ "$istio_ver" == *"$ISTIO_VERSION_EXPECTED"* ]] || die "Expected istioctl ${ISTIO_VERSION_EXPECTED}.x; found '${istio_ver}'."
  say "Installing Istio Ambient"
  sudo env KUBECONFIG="$KUBECONFIG_PATH" "$istioctl_path" install --set profile=ambient --skip-confirmation || die "Istio Ambient installation failed."
  if (( SKIPPED_WORKER == 0 )); then
    kubectl_local -n istio-system rollout status daemonset/ztunnel --timeout=10m || { kubectl_local -n istio-system get pods -o wide || true; die "ztunnel rollout failed."; }
  else
    warn "A worker is unavailable; ztunnel rollout may remain incomplete."
    kubectl_local -n istio-system get daemonset ztunnel -o wide || true
    kubectl_local -n istio-system get pods -o wide || true
  fi
elif have istioctl; then
  echo "istioctl is installed, but Istio Ambient was not requested."
  echo "When ready: bash infra/cluster-up.sh --with-istio"
else
  echo "Istio Ambient was not installed because istioctl is not installed."
fi

say "Cluster-up check finished"
echo "Control plane: $CTRL_IP"
echo "Worker 1: $WORKER1_IP (route=$WORKER1_ROUTE, started=$WORKER1_STARTED)"
echo "Worker 2: $WORKER2_IP (route=$WORKER2_ROUTE, started=$WORKER2_STARTED)"
echo "Cilium: $CILIUM_VERSION"
(( WITH_ISTIO == 1 )) && echo "Istio Ambient: requested" || echo "Istio Ambient: not requested"
echo
kubectl_local get nodes -o wide
echo
kubectl_local -n kube-system get pods -o wide || true
if (( SKIPPED_WORKER == 1 )); then warn "At least one worker was skipped/failed and may remain NotReady."; else echo "Both workers were started and verified."; fi
echo "Swap was checked/disabled for this run; persistent WSL swap configuration is separate."
