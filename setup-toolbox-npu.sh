#!/bin/bash
# Sets up Intel NPU + GPU access on Fedora 44 Silverblue and creates
# a ready-to-use toolbox container with the Intel userspace NPU driver,
# OpenVINO, Neovim, and uv pre-installed.
#
# Usage: ./setup-toolbox-npu.sh [--rebuild] [--name <container-name>]
#   --rebuild   Force removal and rebuild of the container image
#   --name      Container name (default: npu-toolbox)

set -euo pipefail

CONTAINER_NAME="npu-toolbox"
REBUILD=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case $1 in
        --rebuild) REBUILD=true; shift ;;
        --name) CONTAINER_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "==> Fedora 44 Silverblue: Intel NPU + GPU toolbox setup"
echo

# ── Host: udev rules ──────────────────────────────────────────────────────────
# NPU character device — needs 0666 so the toolbox container can access it
if [[ ! -f /etc/udev/rules.d/99-intel-npu.rules ]]; then
    echo "==> Adding udev rule for /dev/accel/accel0"
    echo 'SUBSYSTEM=="accel", KERNEL=="accel*", MODE="0666"' \
        | sudo tee /etc/udev/rules.d/99-intel-npu.rules > /dev/null
else
    echo "==> udev rule for NPU already exists, skipping"
fi

# PMT telemetry — needed for npu-monitor-tool power/temp/utilization metrics
if [[ ! -f /etc/udev/rules.d/99-intel-pmt.rules ]]; then
    echo "==> Adding udev rule for Intel PMT telemetry"
    echo 'SUBSYSTEM=="intel_pmt", MODE="0444"' \
        | sudo tee /etc/udev/rules.d/99-intel-pmt.rules > /dev/null
else
    echo "==> udev rule for PMT already exists, skipping"
fi

echo "==> Reloading udev rules"
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=accel 2>/dev/null || true
sudo udevadm trigger --subsystem-match=intel_pmt 2>/dev/null || true

# ── Verify NPU device is present ──────────────────────────────────────────────
if [[ ! -c /dev/accel/accel0 ]]; then
    echo "ERROR: /dev/accel/accel0 not found."
    echo "  Make sure the intel_vpu kernel module is loaded: lsmod | grep intel_vpu"
    echo "  This hardware requires kernel 6.8+ (Fedora 44 ships a compatible kernel)."
    exit 1
fi
echo "==> NPU device: $(ls -la /dev/accel/accel0)"

# ── Build container image ──────────────────────────────────────────────────────
IMAGE_NAME="npu-toolbox:latest"

if $REBUILD || ! podman image exists "$IMAGE_NAME"; then
    echo "==> Building container image: $IMAGE_NAME"
    podman build \
        --tag "$IMAGE_NAME" \
        --file "${SCRIPT_DIR}/toolbox/Containerfile" \
        "${SCRIPT_DIR}/toolbox/"
else
    echo "==> Container image $IMAGE_NAME already exists (use --rebuild to force)"
fi

# ── Create toolbox container ───────────────────────────────────────────────────
if toolbox list --containers 2>/dev/null | grep -q "^${CONTAINER_NAME}"; then
    if $REBUILD; then
        echo "==> Removing existing container: $CONTAINER_NAME"
        toolbox rm --force "$CONTAINER_NAME"
    else
        echo "==> Container '$CONTAINER_NAME' already exists (use --rebuild to recreate)"
        echo
        echo "To enter: toolbox enter $CONTAINER_NAME"
        exit 0
    fi
fi

echo "==> Creating toolbox container: $CONTAINER_NAME"
toolbox create --image "$IMAGE_NAME" --container "$CONTAINER_NAME"

echo
echo "==> Done! Enter the container with:"
echo "      toolbox enter $CONTAINER_NAME"
echo
echo "==> Verify NPU is visible to OpenVINO (run inside the container):"
echo "      uv run python3 -c \"import openvino as ov; core = ov.Core(); print('Devices:', core.available_devices)\""
echo "    Expected output includes: CPU NPU"
