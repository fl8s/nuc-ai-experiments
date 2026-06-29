#!/bin/bash
#
# setup-k3s-npu.sh
#
# Sets up K3s with Intel NPU support on Fedora 44 Silverblue (bare metal).
# Also works in a privileged LXC container on Proxmox.
#
# Usage:
#   sudo ./setup-k3s-npu.sh [--dry-run] [--uninstall]
#
#   --dry-run    Print what would be done without making changes
#   --uninstall  Tear down everything this script installed
#
# Prerequisites:
#   - /dev/accel/accel0 must exist with 0666 permissions
#   - Run setup-toolbox-npu.sh first (adds the required udev rules)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
K3S_DISABLE_TRAEFIK=true
K3S_DISABLE_SERVICELB=true
NFD_VERSION="0.16.4"
CERTMANAGER_VERSION="v1.15.2"
PANTHER_LAKE_DEVICE_ID="b03e"
HELM_TIMEOUT="120s"
K3S_READY_TIMEOUT=120
POD_READY_TIMEOUT=180
NPU_REGISTER_TIMEOUT=60

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
DRY_RUN=false
UNINSTALL=false

for arg in "$@"; do
    case $arg in
        --dry-run)   DRY_RUN=true ;;
        --uninstall) UNINSTALL=true ;;
        *) echo "Unknown option: $arg"; echo "Usage: $0 [--dry-run] [--uninstall]"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Calling-user detection
# ---------------------------------------------------------------------------
# The script must be run with sudo, but helm/kubectl/kubeconfig should
# belong to the user who invoked sudo, not root.
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo: sudo $0 $*"
    exit 1
fi

CALLING_USER="${SUDO_USER:-$USER}"
CALLING_HOME="$(getent passwd "$CALLING_USER" | cut -d: -f6)"

run_as_user() {
    if [[ "$CALLING_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$CALLING_USER" env \
            HOME="$CALLING_HOME" \
            PATH="$PATH" \
            KUBECONFIG="$CALLING_HOME/.kube/config" \
            "$@"
    fi
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m';  GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

dry() {
    # In --dry-run mode, print the command instead of running it.
    if $DRY_RUN; then
        echo "  [DRY RUN] $*"
    else
        "$@"
    fi
}

dry_as_user() {
    if $DRY_RUN; then
        echo "  [DRY RUN] (as $CALLING_USER) $*"
    else
        run_as_user "$@"
    fi
}

# ---------------------------------------------------------------------------
# Uninstall / teardown
# ---------------------------------------------------------------------------
teardown() {
    log "Tearing down k3s and all installed components..."
    log "Running as: root (system) + $CALLING_USER (helm/kubectl)"

    # Helm releases in reverse installation order
    for release_ns in "npu:inteldeviceplugins-system" "dp-operator:inteldeviceplugins-system" \
                      "cert-manager:cert-manager" "nfd:node-feature-discovery"; do
        release="${release_ns%%:*}"
        ns="${release_ns##*:}"
        if run_as_user helm status "$release" -n "$ns" &>/dev/null 2>&1; then
            log "Uninstalling helm release: $release"
            dry_as_user helm uninstall "$release" -n "$ns"
        fi
    done

    # cert-manager CRDs are not removed by helm uninstall
    if run_as_user kubectl get crd 2>/dev/null | grep -q 'cert-manager.io'; then
        log "Removing cert-manager CRDs (not cleaned up by helm)..."
        dry_as_user bash -c \
            "kubectl get crd | grep cert-manager.io | awk '{print \$1}' | xargs kubectl delete crd"
    fi

    # k3s ships its own uninstall script that cleans iptables, CNI, etc.
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        log "Running k3s uninstall script..."
        dry /usr/local/bin/k3s-uninstall.sh
    fi

    # Remove helm binary
    dry rm -f /usr/local/bin/helm

    # Remove nerdctl binary (binary-only install, single file)
    dry rm -f /usr/local/bin/nerdctl

    # Remove the mount-rshared systemd service
    if [[ -f /etc/systemd/system/k3s-mount-rshared.service ]]; then
        dry systemctl disable k3s-mount-rshared.service
        dry rm -f /etc/systemd/system/k3s-mount-rshared.service
        dry systemctl daemon-reload
    fi

    # Remove kubeconfig
    dry rm -f "$CALLING_HOME/.kube/config"

    # Remove KUBECONFIG from /etc/environment
    if grep -q 'KUBECONFIG' /etc/environment 2>/dev/null; then
        dry sed -i '/^KUBECONFIG=/d' /etc/environment
    fi

    ok "Teardown complete. You may want to reboot to clear mount propagation changes."
    exit 0
}

if $UNINSTALL; then
    teardown
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Intel NUC: K3s + NPU Setup"
if $DRY_RUN; then echo "  ** DRY RUN — no changes will be made **"; fi
echo "  Installing as: root (system), $CALLING_USER (helm/k8s)"
echo "============================================================"
echo ""

if [[ ! -c /dev/accel/accel0 ]]; then
    fail "/dev/accel/accel0 not found. Run setup-toolbox-npu.sh first to add udev rules."
fi
ok "/dev/accel/accel0: $(ls -la /dev/accel/accel0)"

# ---------------------------------------------------------------------------
# STEP 1: System packages
# ---------------------------------------------------------------------------
log "STEP 1: Installing system prerequisites..."

install_packages() {
    local pkgs=("$@")
    if command -v apt-get &>/dev/null; then
        dry apt-get update -qq
        dry apt-get install -y -qq "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        local fedora_pkgs=()
        for pkg in "${pkgs[@]}"; do
            case "$pkg" in
                open-iscsi) fedora_pkgs+=(iscsi-initiator-utils) ;;
                nfs-common)  fedora_pkgs+=(nfs-utils) ;;
                apt-transport-https|gnupg2) ;; # debian-only, skip
                *) fedora_pkgs+=("$pkg") ;;
            esac
        done
        if command -v rpm-ostree &>/dev/null; then
            local missing=()
            for pkg in "${fedora_pkgs[@]}"; do
                rpm -q "$pkg" &>/dev/null || missing+=("$pkg")
            done
            if [[ ${#missing[@]} -gt 0 ]]; then
                warn "Missing packages for rpm-ostree: ${missing[*]}"
                warn "Run: rpm-ostree install ${missing[*]} && reboot"
            fi
        else
            dry dnf install -y "${fedora_pkgs[@]}"
        fi
    else
        fail "No supported package manager found (apt-get, dnf)"
    fi
}

install_packages curl wget ca-certificates open-iscsi nfs-common jq make

# /dev/kmsg required by k3s in LXC environments
if [[ ! -e /dev/kmsg ]]; then
    dry ln -s /dev/console /dev/kmsg
    log "Created /dev/kmsg -> /dev/console"
fi

# Use a dedicated systemd oneshot instead of clobbering /etc/rc.local
if [[ ! -f /etc/systemd/system/k3s-mount-rshared.service ]]; then
    log "Installing k3s-mount-rshared systemd service..."
    if ! $DRY_RUN; then
        cat > /etc/systemd/system/k3s-mount-rshared.service << 'EOF'
[Unit]
Description=Make root mount shared for k3s
Before=k3s.service
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/bin/mount --make-rshared /
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    else
        echo "  [DRY RUN] write /etc/systemd/system/k3s-mount-rshared.service"
    fi
    dry systemctl daemon-reload
    dry systemctl enable k3s-mount-rshared.service
fi

dry mount --make-rshared / 2>/dev/null || warn "mount --make-rshared failed (may already be set)"
dry swapoff -a 2>/dev/null || true

ok "System prerequisites done"

# ---------------------------------------------------------------------------
# STEP 2: Install K3s
# ---------------------------------------------------------------------------
log "STEP 2: Installing K3s..."

if command -v k3s &>/dev/null && systemctl is-active --quiet k3s 2>/dev/null; then
    ok "K3s already running, skipping"
else
    K3S_FLAGS="--write-kubeconfig-mode 644 --snapshotter=native"
    K3S_FLAGS="$K3S_FLAGS --kubelet-arg=feature-gates=KubeletInUserNamespace=true"
    K3S_FLAGS="$K3S_FLAGS --kube-controller-manager-arg=feature-gates=KubeletInUserNamespace=true"
    K3S_FLAGS="$K3S_FLAGS --kube-apiserver-arg=feature-gates=KubeletInUserNamespace=true"
    $K3S_DISABLE_TRAEFIK   && K3S_FLAGS="$K3S_FLAGS --disable=traefik"
    $K3S_DISABLE_SERVICELB && K3S_FLAGS="$K3S_FLAGS --disable=servicelb"

    if ! $DRY_RUN; then
        # Download then execute (not pipe-to-sh) so the script is auditable
        wget -q https://get.k3s.io -O /tmp/k3s-install.sh
        chmod +x /tmp/k3s-install.sh
        INSTALL_K3S_EXEC="server $K3S_FLAGS" /tmp/k3s-install.sh
        rm -f /tmp/k3s-install.sh
    else
        echo "  [DRY RUN] download https://get.k3s.io, execute with: INSTALL_K3S_EXEC='server $K3S_FLAGS'"
    fi
    ok "K3s installed"
fi

# Set up kubeconfig for the calling user (not root)
dry mkdir -p "$CALLING_HOME/.kube"
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    dry cp /etc/rancher/k3s/k3s.yaml "$CALLING_HOME/.kube/config"
    dry chown "$CALLING_USER:$CALLING_USER" "$CALLING_HOME/.kube/config"
    dry chmod 600 "$CALLING_HOME/.kube/config"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! grep -q 'KUBECONFIG' /etc/environment 2>/dev/null; then
    dry bash -c 'echo "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /etc/environment'
fi

# Shell aliases for the calling user (not root)
CALLING_BASHRC="$CALLING_HOME/.bashrc"
grep -q 'alias k=kubectl' "$CALLING_BASHRC" 2>/dev/null || dry bash -c "cat >> '$CALLING_BASHRC' << 'ALIASES'
source <(kubectl completion bash) 2>/dev/null || true
alias k=kubectl
complete -o default -F __start_kubectl k
ALIASES"

# Wait for K3s to be ready
if ! $DRY_RUN; then
    log "Waiting up to ${K3S_READY_TIMEOUT}s for K3s node to be Ready..."
    elapsed=0
    while [[ $elapsed -lt $K3S_READY_TIMEOUT ]]; do
        run_as_user kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
        sleep 5; elapsed=$((elapsed + 5))
    done
    run_as_user kubectl get nodes 2>/dev/null | grep -q ' Ready ' \
        && ok "K3s node is Ready" \
        || fail "K3s did not become Ready within ${K3S_READY_TIMEOUT}s. Check: systemctl status k3s"
fi

# ---------------------------------------------------------------------------
# STEP 3: Helm
# ---------------------------------------------------------------------------
log "STEP 3: Installing Helm..."

if command -v helm &>/dev/null; then
    ok "Helm already installed ($(helm version --short 2>/dev/null))"
else
    if ! $DRY_RUN; then
        # Download then execute — check the script at /tmp/get-helm-3.sh before running if paranoid
        wget -q https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -O /tmp/get-helm-3.sh
        chmod +x /tmp/get-helm-3.sh
        /tmp/get-helm-3.sh
        rm -f /tmp/get-helm-3.sh
    else
        echo "  [DRY RUN] download + execute helm installer"
    fi
    ok "Helm installed"
fi

# ---------------------------------------------------------------------------
# STEP 4: nerdctl (binary only — avoids scattering containerd/CNI into /usr/local)
# ---------------------------------------------------------------------------
log "STEP 4: Installing nerdctl..."

if command -v nerdctl &>/dev/null; then
    ok "nerdctl already installed ($(nerdctl --version 2>/dev/null))"
else
    NERDCTL_VERSION=$(curl -sL https://api.github.com/repos/containerd/nerdctl/releases/latest \
        | jq -r .tag_name | sed 's/^v//')
    [[ -z "$NERDCTL_VERSION" || "$NERDCTL_VERSION" == "null" ]] \
        && fail "Could not determine nerdctl version from GitHub API"

    # Binary-only archive: single nerdctl binary, nothing else
    NERDCTL_URL="https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz"
    log "Downloading nerdctl v${NERDCTL_VERSION} (binary only)..."

    if ! $DRY_RUN; then
        wget -q "$NERDCTL_URL" -O /tmp/nerdctl.tar.gz
        [[ $(stat -c%s /tmp/nerdctl.tar.gz) -lt 1000 ]] \
            && fail "nerdctl archive too small — bad download?"
        tar -xzf /tmp/nerdctl.tar.gz -C /usr/local/bin nerdctl
        rm -f /tmp/nerdctl.tar.gz
    else
        echo "  [DRY RUN] download $NERDCTL_URL, extract nerdctl binary to /usr/local/bin/"
    fi
    ok "nerdctl v${NERDCTL_VERSION} installed"
fi

# ---------------------------------------------------------------------------
# STEP 5-9: Helm charts (all run as calling user)
# ---------------------------------------------------------------------------

wait_for_all_pods() {
    local ns=$1 timeout=$2 elapsed=0
    $DRY_RUN && return 0
    log "Waiting up to ${timeout}s for all pods in $ns..."
    while [[ $elapsed -lt $timeout ]]; do
        not_ready=$(run_as_user kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | grep -cvE 'Running|Completed' || true)
        total=$(run_as_user kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        [[ $not_ready -eq 0 && $total -gt 0 ]] && { ok "All $total pods in $ns are running"; return 0; }
        sleep 5; elapsed=$((elapsed + 5))
    done
    warn "Some pods in $ns not ready after ${timeout}s"
    run_as_user kubectl get pods -n "$ns" 2>/dev/null || true
}

log "STEP 5: Helm repositories..."
dry_as_user helm repo add nfd     https://kubernetes-sigs.github.io/node-feature-discovery/charts 2>/dev/null || true
dry_as_user helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
dry_as_user helm repo add intel   https://intel.github.io/helm-charts/ 2>/dev/null || true
dry_as_user helm repo update
ok "Helm repos configured"

log "STEP 6: Node Feature Discovery..."
if run_as_user helm status nfd -n node-feature-discovery &>/dev/null 2>&1; then
    ok "NFD already installed"
else
    dry_as_user helm install nfd nfd/node-feature-discovery \
        --namespace node-feature-discovery --create-namespace \
        --version "$NFD_VERSION" --wait --timeout "$HELM_TIMEOUT"
    ok "NFD installed"
fi
wait_for_all_pods node-feature-discovery $POD_READY_TIMEOUT

log "STEP 7: cert-manager..."
if run_as_user helm status cert-manager -n cert-manager &>/dev/null 2>&1; then
    ok "cert-manager already installed"
else
    dry_as_user helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERTMANAGER_VERSION" --set installCRDs=true \
        --wait --timeout "$HELM_TIMEOUT"
    ok "cert-manager installed"
fi
wait_for_all_pods cert-manager $POD_READY_TIMEOUT

log "STEP 8: Intel Device Plugin Operator..."
if run_as_user helm status dp-operator -n inteldeviceplugins-system &>/dev/null 2>&1; then
    ok "Intel Device Plugin Operator already installed"
else
    dry_as_user helm install dp-operator intel/intel-device-plugins-operator \
        --namespace inteldeviceplugins-system --create-namespace \
        --wait --timeout "$HELM_TIMEOUT"
    ok "Intel Device Plugin Operator installed"
fi
wait_for_all_pods inteldeviceplugins-system $POD_READY_TIMEOUT

log "STEP 9: Intel NPU Device Plugin..."
if run_as_user helm status npu -n inteldeviceplugins-system &>/dev/null 2>&1; then
    ok "NPU Device Plugin already installed"
else
    dry_as_user helm install npu intel/intel-device-plugins-npu \
        --namespace inteldeviceplugins-system --create-namespace \
        --set nodeFeatureRule=true
    ok "NPU Device Plugin installed"
fi

# ---------------------------------------------------------------------------
# STEP 10: Patch NodeFeatureRule for Panther Lake
# ---------------------------------------------------------------------------
log "STEP 10: Checking NodeFeatureRule for Panther Lake ($PANTHER_LAKE_DEVICE_ID)..."

if ! $DRY_RUN; then
    elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        run_as_user kubectl get nodefeaturerule intel-dp-npu-device &>/dev/null && break
        sleep 2; elapsed=$((elapsed + 2))
    done
    run_as_user kubectl get nodefeaturerule intel-dp-npu-device &>/dev/null \
        || fail "NodeFeatureRule not found after 30s"

    existing=$(run_as_user kubectl get nodefeaturerule intel-dp-npu-device -o json \
        | jq -r '.spec.rules[0].matchFeatures[0].matchExpressions.device.value[]' 2>/dev/null)
    if echo "$existing" | grep -q "$PANTHER_LAKE_DEVICE_ID"; then
        ok "Panther Lake device ID already in NodeFeatureRule"
    else
        run_as_user kubectl patch nodefeaturerule intel-dp-npu-device --type='json' -p="[
            {\"op\": \"add\", \"path\": \"/spec/rules/0/matchFeatures/0/matchExpressions/device/value/-\", \"value\": \"$PANTHER_LAKE_DEVICE_ID\"}
        ]" || fail "Failed to patch NodeFeatureRule"
        ok "Added Panther Lake device ID to NodeFeatureRule"
    fi
else
    echo "  [DRY RUN] patch nodefeaturerule intel-dp-npu-device to add $PANTHER_LAKE_DEVICE_ID"
fi

# ---------------------------------------------------------------------------
# STEP 11: Verify NPU schedulable
# ---------------------------------------------------------------------------
log "STEP 11: Waiting for NPU to register as schedulable..."

if ! $DRY_RUN; then
    sleep 10
    wait_for_all_pods inteldeviceplugins-system $POD_READY_TIMEOUT
    elapsed=0
    while [[ $elapsed -lt $NPU_REGISTER_TIMEOUT ]]; do
        NPU_COUNT=$(run_as_user kubectl get node -o json \
            | jq -r '.items[0].status.allocatable["npu.intel.com/accel"] // empty' 2>/dev/null)
        [[ -n "$NPU_COUNT" && "$NPU_COUNT" != "0" ]] && { ok "NPU schedulable: npu.intel.com/accel=$NPU_COUNT"; break; }
        sleep 5; elapsed=$((elapsed + 5))
    done
    [[ -z "${NPU_COUNT:-}" || "${NPU_COUNT:-}" == "0" ]] \
        && warn "NPU not yet in allocatable — check: kubectl logs -n inteldeviceplugins-system -l app=intel-npu-plugin"
fi

# ---------------------------------------------------------------------------
# STEP 12: NPU test pod
# ---------------------------------------------------------------------------
log "STEP 12: Running NPU test pod..."

if ! $DRY_RUN; then
    run_as_user kubectl delete pod npu-test --ignore-not-found=true 2>/dev/null
    sleep 2
    run_as_user kubectl apply -f - << 'TESTPOD'
apiVersion: v1
kind: Pod
metadata:
  name: npu-test
spec:
  restartPolicy: Never
  containers:
  - name: npu-test
    image: ubuntu:24.04
    command: ["/bin/bash", "-c"]
    args:
    - |
      echo "=== NPU Device Test ==="
      ls -la /dev/accel/ 2>/dev/null || echo "ERROR: /dev/accel not found"
      cat /sys/class/accel/accel0/device/uevent 2>/dev/null || true
    resources:
      limits:
        npu.intel.com/accel: "1"
      requests:
        npu.intel.com/accel: "1"
TESTPOD

    elapsed=0
    while [[ $elapsed -lt 120 ]]; do
        phase=$(run_as_user kubectl get pod npu-test -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 3; elapsed=$((elapsed + 3))
    done
    echo ""
    echo "--- Test pod output ---"
    run_as_user kubectl logs npu-test 2>/dev/null || warn "Could not get test pod logs"
    echo "--- End test pod output ---"
    run_as_user kubectl logs npu-test 2>/dev/null | grep -q '/dev/accel/accel0' \
        && ok "NPU accessible from Kubernetes pods!" \
        || warn "NPU device not visible in test pod"
    run_as_user kubectl delete pod npu-test --ignore-not-found=true 2>/dev/null
else
    echo "  [DRY RUN] deploy and run NPU test pod"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Setup Complete!"
if $DRY_RUN; then echo "  (dry run — no changes were made)"; fi
echo "============================================================"
echo ""
echo "  Kubeconfig: $CALLING_HOME/.kube/config"
echo ""
echo "  Quick commands (run as $CALLING_USER):"
echo "    kubectl get nodes"
echo "    kubectl get pods -A"
echo "    kubectl get node -o json | jq '.items[].status.allocatable'"
echo ""
echo "  To undo everything:"
echo "    sudo $0 --uninstall"
echo ""
