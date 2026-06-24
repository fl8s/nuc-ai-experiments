# Running on Fedora Silverblue / IoT

Running K3s with NPU support on Fedora Silverblue or Fedora IoT requires a slightly different mindset than a traditional mutable Linux distribution (like Ubuntu or Debian), but it is fully supported by this project.

The scripts in this repository have been updated to dynamically detect `dnf` or `rpm-ostree` and map Debian package names to their Fedora equivalents.

## Why K3s Works Natively on Silverblue/IoT

Fedora Silverblue and IoT are immutable OSes relying on OSTree. This means that you cannot arbitrarily modify `/usr`. However, `k3s` is designed as a single static binary that installs itself into `/usr/local/bin` and drops its configuration in `/etc` and `/var`. Because `/usr/local`, `/etc`, and `/var` are writable on Silverblue, **K3s installs and runs perfectly fine natively on the host.**

In fact, running K3s natively on the host is highly recommended over running it inside a Toolbox or Distrobox container, as K3s itself manages containers (via containerd) and needs deep system integration (cgroups, iptables, mounts, device nodes like `/dev/accel/accel0`). Running K3s natively allows it to function without the complexities of "nested containerization".

## NPU Drivers and Ubuntu Dockerfiles

You might notice that the project's Dockerfiles (such as `npu-chatbot/Dockerfile`) are still based on Ubuntu (`openvino/ubuntu24_dev`). **This is intentional and will not cause issues on Fedora.**

Currently, Intel only distributes the out-of-tree user-space NPU driver components as Debian (`.deb`) packages. By encapsulating these dependencies inside an Ubuntu container, we bypass the need to install them on the Fedora host. The K3s cluster orchestrates pulling and running this Ubuntu-based container, and the Intel Device Plugin passes the `/dev/accel/accel0` node from the Fedora host directly into the container.

This is the exact problem containers are meant to solve: decoupling the application runtime environment from the host operating system.

## Setup Methods

### Method 1: Native K3s on Fedora (Recommended)

1. Boot your Fedora Silverblue / IoT machine.
2. Verify you have the correct NPU character device:
   ```bash
   ls -l /dev/accel/accel0
   ```
   *Note: Make sure the permissions allow access (e.g. `chmod 666 /dev/accel/accel0` via a udev rule).*
3. Run the setup scripts directly on your host:
   ```bash
   sudo ./setup-k3s-npu.sh
   sudo ./setup-k3s-gpu.sh
   ```
4. If the scripts notify you of missing packages via `rpm-ostree`, layer them using `rpm-ostree install <packages>` and reboot.

### Method 2: Virtual Machine with Device Passthrough

If you prefer keeping your host entirely pristine, you can spin up a VM (using KVM/libvirt on Fedora) and run K3s inside it.

However, unlike GPUs which use standard PCIe VFIO passthrough, `/dev/accel/accel0` is often exposed as a character device depending on the platform/kernel. Passing through character devices to a VM is more complex, but can be achieved using Virtio-FS (for file sharing, though not ideal for `/dev`) or explicitly mapping the device node if using lightweight virtualization like LXC (which is the method described in our main `README.md` using Proxmox).

For KVM/QEMU, standard PCIe passthrough of the NPU device (e.g., binding the PCI device to `vfio-pci`) is required.

**Summary:** The most pragmatic, "container-native" approach on Silverblue is running K3s natively and letting K3s launch the Ubuntu containers containing the `.deb` NPU driver.

## Monitoring

The `setup-npu-monitor.sh` script currently clones a repository and expects standard Linux utilities. On Silverblue, you might need to layer `git` and `python3` dependencies, or alternatively, run the monitoring tool inside a Toolbox container that mounts the necessary `/sys/class/intel_pmt/` directories.
