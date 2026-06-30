# NUC16 Experiments

This repository contains experiments performed on an ASUS NUC16. The configuration is:

* NUC16 Pro with 356H CPU
* 64GB DDR5
* 1TB Samsung 9100 NVME drive

The notes in this README are somewhat terse, intended to help me remember what I did.

## Proxmox installation

Installed Proxmox 9.1 from USB stick. Use the non-graphical installer.

## Post-install setup proxmox

```bash
mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.disabled
mv /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.disabled

cat > /etc/apt/sources.list.d/pve-no-subscription.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
EOF

sudo apt install emacs-nox
emacs /etc/default/grub
# add to KERNEL_CMDLINE: intel_iommu=on iommu=pt
reboot

chmod 666 /dev/accel/accel0
echo 'SUBSYSTEM=="accel", KERNEL=="accel*", MODE="0666"' > /etc/udev/rules.d/99-intel-npu.rules
udevadm control --reload-rules
udevadm trigger /dev/accel/accel0
```

## Create the LXC container for NPU experiments

Download the Ubuntu 24.04 LXC image.

```bash
pveam update
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

Create the LXC container and set the configuration to allow NPU and GPU passthrough.

```bash
pct create 100 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname k3s-node \
  --memory 32768 \
  --swap 0 \
  --cores 8 \
  --rootfs local-lvm:400 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,hwaddr=BC:24:11:00:01:00 \
  --features nesting=1,fuse=1 \
  --ostype ubuntu \
  --password smbaker \
  --unprivileged 0

cat >> /etc/pve/lxc/100.conf << 'EOF'
# K3s requirements
lxc.apparmor.profile: unconfined
lxc.cgroup.devices.allow: a
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw cgroup:rw
# Allow K3s system calls
lxc.seccomp.profile:
# NPU passthrough
lxc.cgroup2.devices.allow: c 261:* rwm
lxc.mount.entry: /dev/accel dev/accel none bind,optional,create=dir
# NPU monitor access
lxc.mount.entry: /sys/class/intel_pmt sys/class/intel_pmt none bind,optional,create=dir
lxc.mount.entry: /sys/kernel/debug sys/kernel/debug none bind,optional,create=dir
# GPU passthrough
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF

pct start 100
```

## Enter the LXC container and setup SSH, K3s, and other things via Ansible

The provisioning of the host, K3s cluster, and multi-device AI services has been refactored from shell scripts into a set of well-factored Ansible playbooks.

### Ansible Roles Overview
- **common**: Installs required system packages (openssh-server, sudo, make, git, etc.), enables SSH, creates a non-root user (`smbaker`), and allows passwordless sudo.
- **k3s**: Disables swap, installs cluster prerequisites (`nfs-common`, `open-iscsi`), creates the necessary `/dev/kmsg` symlink, handles the native K3s installation with specific LXC feature gates (`KubeletInUserNamespace=true`), and configures containerd/nerdctl.
- **npu**: Installs NFD (Node Feature Discovery), cert-manager, the Intel Device Plugin Operator, and the NPU plugin via Helm. It dynamically patches the Panther Lake NodeFeatureRule to ensure the NPU schedules correctly.
- **gpu**: Installs the Intel GPU plugin via Helm on top of the existing operator and patches its NodeFeatureRule to properly detect the `xe` and `i915` kernel modules.
- **npu_monitor**: Clones the Intel NPU monitoring tool to the host and creates a convenience symlink at `/usr/local/bin/npu-monitor`.

### Playbooks
You can run the entire provisioning suite using `site.yml`, or you can run individual components:
- `ansible-playbook ansible/playbooks/provision_host.yml`
- `ansible-playbook ansible/playbooks/provision_cluster.yml`
- `ansible-playbook ansible/playbooks/provision_services.yml`

### Execution

First, install Ansible, then run the playbooks locally inside the LXC container:

```bash
pct enter 100

# Install Ansible and passlib (required for user password hashing)
apt-get update && apt-get install -y ansible git python3-passlib

# Clone the repository (if you haven't already copied it in)
git clone <this-repo-url> /opt/nuc-experiments
cd /opt/nuc-experiments

# Run the entire Ansible suite locally
ansible-playbook ansible/site.yml
```

At this point the LXC will have SSH running inside, making it
convenient to SSH in as well as to SCP in files.

## Copy project files to the container

Copy the `npu-chatbot` and `npu-imagegen` directories to the LXC container.
SSH, SCP, or any other method works.

## npu-chatbot

See [npu-chatbot/README.md](npu-chatbot/README.md) for details.

```bash
cd ~/npu-chatbot

# list models
make models

# build and deploy a chatbot
sudo make build MODEL=qwen3-4b
make deploy MODEL=qwen3-4b

# attach to chat
make attach
```

## npu-imagegen

See [npu-imagegen/README.md](npu-imagegen/README.md) for details.

```bash
cd ~/npu-imagegen

# list models
make models

# build and deploy an image generator
sudo make build MODEL=sdxl-turbo
make deploy MODEL=sdxl-turbo DEVICES=npu,gpu

# web UI at http://<node-ip>:30080
```

## Troubleshooting

### "Failed to compile Model0_kv1152_FCEW000__0 for all devices in [NPU]"

Two possible causes:

1. **NPU device permissions** — Inside the LXC, check `/dev/accel/accel0`
   permissions. It needs to be readable by the container process:
   ```bash
   ls -la /dev/accel/accel0
   ```
   If it shows `rw-rw----` (not world-readable), fix it on the **Proxmox host**:
   ```bash
   chmod 666 /dev/accel/accel0
   ```
   The udev rule in `/etc/udev/rules.d/99-intel-npu.rules` should make this
   persistent across reboots, but LXC bind mounts can lose permissions after
   container restarts.

2. **Model too large for NPU** — Very large models may exceed the NPU
   compiler's limits. If so, use `--device CPU` as a fallback:
   ```bash
   make deploy MODEL=<model> DEVICE=CPU
   ```
   Note: 14B models (e.g., qwen25-14b) work on NPU 5 (Panther Lake).

### "failed to reserve container name ... is reserved for ..."

Stale containerd state. Run `make nuke` to clean up orphaned containers,
then redeploy.

### "context deadline exceeded" / "stream terminated by RST_STREAM with error code: CANCEL"

The kubelet timed out waiting for containerd to create the container. Common
with large images on the native snapshotter (required for K3s in LXC).
Run `make fix-k3s` to increase the runtime request timeout and lower
eviction thresholds. This only needs to be done once.
