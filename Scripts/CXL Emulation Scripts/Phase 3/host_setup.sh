#!/usr/bin/env bash
# Description : CXL Workspace Host Setup (Ubuntu 24.04.4 LTS)

# This script prepares the host system for CXL emulation on QEMU.

# Covers:
#   1. Workspace creation
#   2. KVM setup
#   3. Dependency installation
#   4. Building CXL-enabled QEMU
#   5. Building Linux 6.18 CXL kernel
#   6. OVMF setup
#   7. Ubuntu cloud image preparation
#   8. Guest customization

# Host OS : Ubuntu 24.04.4 LTS

set -euo pipefail

# Global Paths
WORKSPACE="/opt/cxl_workspace"

QEMU_BUILD="${WORKSPACE}/qemu_build"
KERNEL_BUILD="${WORKSPACE}/kernel_build"

IMAGES="${WORKSPACE}/images"
TOOLS="${WORKSPACE}/tools"

QEMU_INSTALL="${WORKSPACE}/qemu_install"

QEMU_SRC="${QEMU_BUILD}/qemu"
KERNEL_SRC="${KERNEL_BUILD}/linux"

GUEST_IMAGE="${IMAGES}/cxl-guest.qcow2"

# Colour Helpers
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# 1. Workspace Setup
create_workspace() {
    info "Creating workspace directories..."

    sudo mkdir -p "${QEMU_BUILD}"
    sudo mkdir -p "${KERNEL_BUILD}"
    sudo mkdir -p "${IMAGES}"
    sudo mkdir -p "${TOOLS}"
    sudo mkdir -p "${QEMU_INSTALL}"

    sudo chown -R "$USER:$USER" "${WORKSPACE}"

    success "Workspace ready at ${WORKSPACE}"
}

# 2. KVM Setup
setup_kvm() {
    info "Configuring KVM permissions..."

    sudo usermod -aG kvm "$USER"

    if groups | grep -q kvm; then
        success "User already has KVM access."
    else
        warn "Run 'newgrp kvm' or relogin after script completion."
    fi

    [[ -c /dev/kvm ]] \
        && success "/dev/kvm present." \
        || warn "/dev/kvm missing."
}

# 3. Install Dependencies
install_dependencies() {
    info "Updating package index..."

    sudo apt-get update
    sudo apt-get dist-upgrade -y

    info "Installing required dependencies..."

    sudo apt-get install --no-install-recommends -y \
        build-essential git ccache flex bison bc pkg-config \
        automake autoconf libtool ninja-build meson cmake \
        python3 python3-venv python3-pip python3-dev \
        python3-sphinx python3-sphinx-rtd-theme \
        ca-certificates wget curl \
        libglib2.0-dev libpixman-1-dev zlib1g-dev libgcrypt20-dev \
        libfdt-dev libffi-dev libslirp-dev liburing-dev libnfs-dev \
        libcurl4-gnutls-dev libzstd-dev libgudev-1.0-dev libaio-dev \
        libpmem-dev libpmem2-dev libssh-dev dbus-daemon dwarves perl \
        bridge-utils libncurses-dev libssl-dev libelf-dev libudev-dev \
        libpci-dev llvm clang asciidoc asciidoctor ruby-asciidoctor \
        xmlto libkmod-dev libsystemd-dev uuid-dev libjson-c-dev \
        libkeyutils-dev libiniparser-dev libtraceevent-dev libtracefs-dev \
        libnl-3-dev libnl-route-3-dev libibverbs-dev librdmacm-dev \
        libusb-1.0-0-dev libepoxy-dev libdrm-dev libgbm-dev libegl1-mesa-dev \
        ovmf qemu-utils libguestfs-tools \
        socat numactl iproute2 netcat-openbsd \
        sparse cscope exuberant-ctags \
        libvirglrenderer-dev libsdl2-dev libgtk-3-dev \
        libvte-2.91-dev libpulse-dev libjack-dev \
        libspice-protocol-dev libspice-server-dev \
        xfslibs-dev libbpf-dev \
        ndctl

    sudo update-guestfs-appliance

    success "Dependencies installed."
}

# 4. Build QEMU (Jonathan Cameron CXL Branch)
build_qemu() {
    info "Cloning CXL-enabled QEMU..."

    cd "${QEMU_BUILD}"

    if [[ ! -d "${QEMU_SRC}" ]]; then
        git clone https://gitlab.com/jic23/qemu.git
    fi

    cd "${QEMU_SRC}"

    git fetch origin

    git checkout -B cxl-stable origin/cxl-2025-03-20

    git submodule update --init --recursive

    info "Configuring QEMU..."

    ./configure \
        --target-list=x86_64-softmmu \
        --enable-debug \
        --enable-slirp \
        --enable-kvm \
        --enable-vhost-net \
        --enable-libpmem \
        --enable-virtfs \
        --enable-linux-aio \
        --enable-bpf \
        --disable-werror \
        --prefix="${QEMU_INSTALL}"

    info "Applying replay-tools patch..."

    sed -i \
        's/unsigned int kind/ReplayClockKind kind/g' \
        stubs/replay-tools.c || true

    info "Building QEMU..."

    make -j"$(nproc)"

    make install

    success "QEMU build complete."

    "${QEMU_INSTALL}/bin/qemu-system-x86_64" --version
}

# 5. Build Linux 6.18 CXL Kernel
build_kernel() {
    info "Cloning Linux kernel source..."

    cd "${KERNEL_BUILD}"

    if [[ ! -d "${KERNEL_SRC}" ]]; then
        git clone --depth=1 --branch v6.18 \
            https://github.com/torvalds/linux.git
    fi

    cd "${KERNEL_SRC}"

    info "Configuring kernel..."

    make defconfig
    make kvm_guest.config

    ./scripts/config --enable CONFIG_EXPERT
    ./scripts/config --enable CONFIG_CXL_BUS
    ./scripts/config --enable CONFIG_CXL_PCI
    ./scripts/config --enable CONFIG_CXL_ACPI
    ./scripts/config --enable CONFIG_CXL_PMEM
    ./scripts/config --enable CONFIG_CXL_MEM
    ./scripts/config --enable CONFIG_CXL_PORT
    ./scripts/config --enable CONFIG_CXL_REGION
    ./scripts/config --enable CONFIG_CXL_MEM_RAW_COMMANDS
    ./scripts/config --enable CONFIG_ZONE_DEVICE
    ./scripts/config --enable CONFIG_DEV_DAX
    ./scripts/config --enable CONFIG_DEV_DAX_CXL
    ./scripts/config --enable CONFIG_FS_DAX
    ./scripts/config --enable CONFIG_LIBNVDIMM
    ./scripts/config --enable CONFIG_BLK_DEV_PMEM
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG
    ./scripts/config --enable CONFIG_NUMA
    ./scripts/config --enable CONFIG_ACPI_NUMA
    ./scripts/config --enable CONFIG_RAS
    ./scripts/config --enable CONFIG_PCIEAER
    ./scripts/config --enable CONFIG_X86_MCE

    make olddefconfig

    info "Building kernel..."

    mkdir -p "${IMAGES}/modules"

    make -j"$(nproc)" bzImage modules

    make modules_install \
        INSTALL_MOD_PATH="${IMAGES}/modules"

    cp arch/x86/boot/bzImage \
        "${IMAGES}/bzImage-6.18-cxl"

    success "Kernel build complete."
}

# 6. Setup OVMF
setup_ovmf() {
    info "Setting up OVMF firmware..."

    cd "${IMAGES}"

    cp /usr/share/OVMF/OVMF_CODE*.fd .
    cp /usr/share/OVMF/OVMF_VARS*.fd .

    mv OVMF_CODE_4M.fd OVMF_CODE.fd 2>/dev/null || true
    mv OVMF_VARS_4M.fd OVMF_VARS.fd 2>/dev/null || true

    success "OVMF firmware ready."
}

# 7. Prepare Ubuntu Cloud Image
prepare_guest_image() {
    info "Downloading Ubuntu Noble cloud image..."

    cd "${IMAGES}"

    if [[ ! -f noble-server-cloudimg-amd64.img ]]; then
        wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    fi

    info "Creating qcow2 guest image..."

    qemu-img convert \
        -O qcow2 \
        noble-server-cloudimg-amd64.img \
        cxl-guest.qcow2

    qemu-img resize -f qcow2 cxl-guest.qcow2 20G

    success "Guest image ready."
}

# 8. Guest Customization
customize_guest() {
    info "Customizing guest image..."

    cd "${IMAGES}"

    cat << 'EOF' > 01-dhcp.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    all_eth:
      match:
        name: "e*"
      dhcp4: true
EOF

    export LIBGUESTFS_BACKEND=direct

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --root-password password:cxladmin

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'touch /etc/cloud/cloud-init.disabled'

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'systemctl enable serial-getty@ttyS0.service'

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config'

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config'

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in 01-dhcp.yaml:/etc/netplan/

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in "${IMAGES}/modules/lib/modules:/lib/"

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'apt-get update && apt-get install -y ndctl'

    success "Guest customization complete."
}

# 9. Validation
validate_environment() {
    info "Validating environment..."

    [[ -x "${QEMU_INSTALL}/bin/qemu-system-x86_64" ]] \
        && success "QEMU binary present." \
        || die "QEMU binary missing."

    [[ -f "${IMAGES}/bzImage-6.18-cxl" ]] \
        && success "Kernel image present." \
        || die "Kernel image missing."

    [[ -f "${IMAGES}/OVMF_CODE.fd" ]] \
        && success "OVMF_CODE.fd present." \
        || die "OVMF_CODE.fd missing."

    [[ -f "${IMAGES}/OVMF_VARS.fd" ]] \
        && success "OVMF_VARS.fd present." \
        || die "OVMF_VARS.fd missing."

    [[ -f "${GUEST_IMAGE}" ]] \
        && success "Guest image present." \
        || die "Guest image missing."

    success "Environment validation complete."
}

# Main Controller
main() {
    create_workspace
    setup_kvm
    install_dependencies
    build_qemu
    build_kernel
    setup_ovmf
    prepare_guest_image
    customize_guest
    validate_environment

    success "CXL host setup complete."
}

main "$@"