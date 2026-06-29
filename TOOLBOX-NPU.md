# Intel NPU + GPU on Fedora 44 Silverblue — Toolbox Setup

This guide covers getting Intel Panther Lake NPU and iGPU working for local LLM
inference on **Fedora 44 Silverblue** using a toolbox container. No exotic
kernels, no IOMMU flags, no VM passthrough required.

Tested on: Intel Core Ultra Series 3 (356H), Fedora 44 Silverblue, kernel 7.0.x

---

## How it works

- **Kernel driver** (`intel_vpu`) ships in the Fedora 44 kernel — already loaded,
  no extra packages needed.
- **Userspace driver** (Intel's `.deb`-only packages) lives inside the toolbox
  container (Ubuntu 24.04 base), keeping the immutable host clean.
- **Device access** — toolbox containers share `/dev` with the host, so
  `/dev/accel/accel0` is directly accessible without passthrough configuration.
- **GPU OpenCL** works out of the box — `intel-opencl` and `intel-gmmlib` are
  already present in the Fedora 44 base image.

---

## Quick start

```bash
# One command does everything
./setup-toolbox-npu.sh

# Enter the container
toolbox enter npu-toolbox

# Verify NPU is visible
uv run python3 -c "import openvino as ov; core = ov.Core(); print('Devices:', core.available_devices)"
# Expected: ['CPU', 'GPU', 'NPU']
```

---

## What the setup script does

### Host (Fedora 44 Silverblue)

1. **udev rule — NPU device access**
   Writes `/etc/udev/rules.d/99-intel-npu.rules` to set `/dev/accel/accel0`
   permissions to `0666`. Without this the container can see the device but
   can't open it.

2. **udev rule — PMT telemetry**
   Writes `/etc/udev/rules.d/99-intel-pmt.rules` to make
   `/sys/class/intel_pmt/` readable. This enables power, temperature, and
   utilization metrics in `npu-monitor-tool`.

3. **Builds the container image** from `toolbox/Containerfile`.

4. **Creates the toolbox container** named `npu-toolbox`.

The script is idempotent — safe to run again. Use `--rebuild` to force a fresh
container image and container.

### Inside the container (baked into the image)

| What | Why |
|------|-----|
| Ubuntu 24.04 base with locale | zsh and other tools need `en_US.UTF-8` or the line editor breaks |
| `libze1` from kobuk-team PPA | Level Zero loader required by `intel-level-zero-npu` |
| Intel NPU driver bundle | Userspace runtime OpenVINO uses to talk to `/dev/accel/accel0` |
| Neovim (latest from GitHub) | Ubuntu 24.04 ships 0.9.x; build from the release tarball instead |
| `uv` | Fast Python package manager; use `uv run` / `uv pip install` for deps |

---

## What you do NOT need

| Item | Why it's not needed |
|------|---------------------|
| `intel_iommu=on iommu=pt` kernel flags | Those are for PCIe device passthrough *into VMs*. Bare metal doesn't need them. |
| Custom/OEM kernel | `intel_vpu` has been upstream since kernel 6.8; Fedora 44 includes it. |
| `rpm-ostree install` of NPU libraries | Intel only ships `.deb` packages; we put them in the container instead. |
| VM or Proxmox | The proxmox guide needed LXC passthrough because they weren't on bare metal. |
| FUSE for AppImages | Unrelated to NPU; fix with `rpm-ostree install fuse-libs` if needed. |

---

## Installing Python packages

The container includes `uv` but no pre-installed Python packages — manage
them per-project so venvs live with your code:

```bash
# Inside the container, in your project directory
uv pip install openvino openvino-genai "optimum[openvino]"

# Run with the venv active
uv run python3 your_script.py

# Or activate manually
source .venv/bin/activate
```

---

## Rebuilding the container

The container image is reproducible. When Intel releases a new NPU driver
version, update the `ARG` values in `toolbox/Containerfile` and rebuild:

```bash
./setup-toolbox-npu.sh --rebuild
```

Check https://github.com/intel/linux-npu-driver/releases for new versions.

---

## Monitoring NPU metrics

Once the PMT udev rule is in place, `npu-monitor-tool` will show live
power, temperature, DDR bandwidth, and utilization:

```bash
# Inside the container, from the intel edge-ai-libraries repo
sudo python3 tools/npu-monitor-tool/npu-monitor-tool.py
```

If telemetry values are still zero after adding the udev rule, check that
the PMT kernel module is loaded on the host:
```bash
lsmod | grep pmt
```
