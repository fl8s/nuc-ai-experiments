#!/bin/bash
#
# setup-ssh.sh
#
# Run this inside a fresh LXC container to set up SSH access with a non-root user.
#
# Usage:
#   chmod +x setup-ssh.sh
#   ./setup-ssh.sh
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi


install_packages() {
    local pkgs=("$@")

    # Check for package manager
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y -qq "${pkgs[@]}"
    elif command -v dnf &> /dev/null; then
        # Map debian names to fedora names
        local fedora_pkgs=()
        for pkg in "${pkgs[@]}"; do
            case "$pkg" in
                "emacs-nox") fedora_pkgs+=("emacs-nox") ;; # emacs-nox is valid in fedora
                "openssh-server") fedora_pkgs+=("openssh-server") ;;
                *) fedora_pkgs+=("$pkg") ;;
            esac
        done
        if command -v rpm-ostree &> /dev/null; then
            local missing=()
            for pkg in "${fedora_pkgs[@]}"; do
                if ! rpm -q "$pkg" &> /dev/null; then
                    missing+=("$pkg")
                fi
            done
            if [ ${#missing[@]} -gt 0 ]; then
                echo "rpm-ostree detected. The following packages need to be installed:"
                echo "${missing[*]}"
                echo "Please install them manually using 'rpm-ostree install <packages>' and reboot, or use --apply-live."
            fi
        else
            dnf install -y "${fedora_pkgs[@]}"
        fi
    else
        echo "ERROR: Could not find supported package manager (apt-get, dnf, rpm-ostree)"
        kill -TERM $$
    fi
}

echo "Installing openssh-server and sudo and other stuff..."
install_packages openssh-server sudo emacs-nox net-tools make git

echo "Enabling SSH..."
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable --now ssh

echo "Creating user smbaker..."
if id smbaker &>/dev/null; then
    echo "User smbaker already exists, skipping creation"
else
    useradd -m -s /bin/bash -u 1026 smbaker
    echo "smbaker:smbaker" | chpasswd
    usermod -aG sudo smbaker
    echo "smbaker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/smbaker
    chmod 440 /etc/sudoers.d/smbaker
fi

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "Done! SSH into this container with:"
echo "  ssh smbaker@${IP}"
echo ""
echo "Remember to change the default password after first login:"
echo "  passwd"
