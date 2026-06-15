# Description : CXL Workspace Host Setup (Ubuntu 24.04.4 LTS)

# This script fully prepares the host system for CXL emulation on QEMU
# and launches the CXL Type 3 Memory Expansion topology.

# Covers:
#   1.  Workspace creation
#   2.  KVM setup
#   3.  Dependency installation (including deb-src + build-dep qemu)
#   4.  Building CXL-enabled QEMU (Jonathan Cameron fork)
#   5.  Building Linux 6.18 CXL kernel (full config set)
#   6.  OVMF setup (built from edk2 source)
#   7.  Ubuntu Noble cloud image preparation
#   8.  Guest customization (password, SSH, netplan, modules, ndctl,
#       networkd-wait-online fix)
#   9.  CXL backing file creation
#   10. Environment validation
#   11. CXL Type 3 VM launch

# Host OS : Ubuntu 24.04.4 LTS (Noble Numbat)

set -euo pipefail

# Error Handler — prints exact line, command, and call stack on any failure
error_handler() {
    local exit_code=$?
    local line_number=$1
    local failed_command="$2"

    echo ""
    echo -e "SCRIPT FAILED"
    echo -e "\033[0;31m  Line        : ${line_number}\033[0m"
    echo -e "\033[0;31m  Exit code   : ${exit_code}\033[0m"
    echo -e "\033[0;31m  Command     : ${failed_command}\033[0m"

    # Print the call stack (function names, skipping error_handler itself)
    if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
        echo -e "\033[1;33m  Call stack  :\033[0m"
        for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
            echo -e "\033[1;33m    [$i] ${FUNCNAME[$i]}  (called from line ${BASH_LINENO[$i-1]} in ${BASH_SOURCE[$i]:-main})\033[0m"
        done
    fi

    echo -e "\033[0;31m  Script      : ${BASH_SOURCE[0]}\033[0m"
    echo ""
}

trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

# Global Paths
WORKSPACE="/opt/cxl_workspace"

QEMU_BUILD="${WORKSPACE}/qemu_build"
KERNEL_BUILD="${WORKSPACE}/kernel_build"
IMAGES="${WORKSPACE}/images"
TOOLS="${WORKSPACE}/tools"
QEMU_INSTALL="${WORKSPACE}/qemu_install"

QEMU_SRC="${QEMU_BUILD}/qemu"
KERNEL_SRC="${KERNEL_BUILD}/linux"
EDK2_SRC="${TOOLS}/edk2"

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
        warn "Run 'newgrp kvm' or re-login after script completion."
    fi

    [[ -c /dev/kvm ]] \
        && success "/dev/kvm present." \
        || warn "/dev/kvm missing — hardware virtualisation may be disabled in BIOS."
}

# 3. Install Dependencies
install_dependencies() {
    info "Updating package index..."
    sudo apt-get update
    sudo apt-get dist-upgrade -y

    info "Installing primary dependency set..."
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
        qemu-utils libguestfs-tools \
        nasm iasl \
        socat numactl iproute2 netcat-openbsd \
        sparse cscope exuberant-ctags \
        libvirglrenderer-dev libsdl2-dev libgtk-3-dev \
        libvte-2.91-dev libpulse-dev libjack-dev \
        libspice-protocol-dev libspice-server-dev \
        xfslibs-dev libbpf-dev \
        ndctl \
        linux-image-generic

    # Enable deb-src lines so apt-get build-dep can resolve hidden QEMU
    # build dependencies that are not surfaced by the regular package list.
    info "Enabling deb-src repositories for build-dep support..."
    if grep -q '^Types: deb$' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
        sudo sed -i 's/^Types: deb$/Types: deb deb-src/' \
            /etc/apt/sources.list.d/ubuntu.sources
    fi
    sudo apt-get update
    sudo apt-get build-dep qemu -y

    # Re-confirm libguestfs-tools is fully installed after build-dep run
    sudo apt-get install -y libguestfs-tools

    # Persist LIBGUESTFS_BACKEND=direct for interactive sessions; the export
    # inside the customisation function covers the non-interactive path.
    if ! grep -q 'LIBGUESTFS_BACKEND' ~/.bashrc; then
        echo 'export LIBGUESTFS_BACKEND=direct' >> ~/.bashrc
    fi

    success "Dependencies installed."
}

# 4. Build QEMU (Jonathan Cameron CXL Branch)
build_qemu() {
    info "Cloning CXL-enabled QEMU (Jonathan Cameron fork)..."

    cd "${QEMU_BUILD}"

    if [[ ! -d "${QEMU_SRC}" ]]; then
        git clone https://gitlab.com/jic23/qemu.git
    fi

    cd "${QEMU_SRC}"

    git fetch origin

    # -B resets the branch if it already exists, making this idempotent.
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

    # Fix type mismatch in replay-tools stub that causes build failure.
    info "Applying replay-tools patch..."
    sed -i \
        's/unsigned int kind/ReplayClockKind kind/g' \
        stubs/replay-tools.c || true

    info "Building QEMU — this will take several minutes..."
    make -j"$(nproc)"
    make install

    success "QEMU build complete."
    "${QEMU_INSTALL}/bin/qemu-system-x86_64" --version

    info "Verifying CXL device support in binary..."
    "${QEMU_INSTALL}/bin/qemu-system-x86_64" -device help 2>&1 | grep -i cxl \
        && success "CXL devices confirmed in QEMU binary." \
        || die "CXL devices NOT found in QEMU binary — check build output."
}

# 5. Build Linux 6.18 CXL Kernel
build_kernel() {
    info "Cloning Linux kernel source (v6.18)..."

    cd "${KERNEL_BUILD}"

    if [[ ! -d "${KERNEL_SRC}" ]]; then
        git clone --depth=1 --branch v6.18 \
            https://github.com/torvalds/linux.git
    fi

    cd "${KERNEL_SRC}"

    info "Generating base defconfig + KVM guest overlay..."
    make defconfig
    make kvm_guest.config

    info "Injecting mandatory CXL and supporting kernel options..."

    # Core CXL subsystem
    ./scripts/config --enable CONFIG_EXPERT
    ./scripts/config --enable CONFIG_CXL_BUS
    ./scripts/config --enable CONFIG_CXL_PCI
    ./scripts/config --enable CONFIG_CXL_ACPI
    ./scripts/config --enable CONFIG_CXL_PMEM
    ./scripts/config --enable CONFIG_CXL_MEM
    ./scripts/config --enable CONFIG_CXL_PORT
    ./scripts/config --enable CONFIG_CXL_REGION
    ./scripts/config --enable CONFIG_CXL_MEM_RAW_COMMANDS
    ./scripts/config --enable CONFIG_CXL_SUSPEND

    # DAX / PMEM / Zone Device
    ./scripts/config --enable CONFIG_ZONE_DEVICE
    ./scripts/config --enable CONFIG_DEV_DAX
    ./scripts/config --enable CONFIG_DEV_DAX_CXL
    ./scripts/config --enable CONFIG_DEV_DAX_PMEM
    ./scripts/config --enable CONFIG_FS_DAX
    ./scripts/config --enable CONFIG_LIBNVDIMM
    ./scripts/config --enable CONFIG_BLK_DEV_PMEM

    # Memory hotplug / NUMA
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE
    ./scripts/config --enable CONFIG_MEMORY_HOTREMOVE
    ./scripts/config --enable CONFIG_NUMA
    ./scripts/config --enable CONFIG_ACPI_NUMA

    # Filesystem support required for DAX mounts
    ./scripts/config --enable CONFIG_EXT4_FS
    ./scripts/config --enable CONFIG_DEBUG_FS

    # CXL test / validation hooks
    ./scripts/config --enable CONFIG_CXL_REGION_INVALIDATION_TEST

    # Error handling
    ./scripts/config --enable CONFIG_RAS
    ./scripts/config --enable CONFIG_PCIEAER
    ./scripts/config --enable CONFIG_X86_MCE
    ./scripts/config --enable CONFIG_EDAC

    # Tracing / debugging (critical for CXL event inspection)
    ./scripts/config --enable CONFIG_TRACING_SUPPORT
    ./scripts/config --enable CONFIG_GENERIC_TRACER
    ./scripts/config --enable CONFIG_FTRACE
    ./scripts/config --enable CONFIG_TRACE_CLOCK
    ./scripts/config --enable CONFIG_RING_BUFFER
    ./scripts/config --enable CONFIG_EVENT_TRACING
    ./scripts/config --enable CONFIG_DYNAMIC_DEBUG

    # Resolve any newly introduced Kconfig dependencies automatically.
    make olddefconfig

    info "Building kernel — this will take a long time..."
    mkdir -p "${IMAGES}/modules"

    make -j"$(nproc)" bzImage modules

    make modules_install \
        INSTALL_MOD_PATH="${IMAGES}/modules"

    cp arch/x86/boot/bzImage \
        "${IMAGES}/bzImage-6.18-cxl"

    success "Kernel build complete. Image at ${IMAGES}/bzImage-6.18-cxl"
}

# 6. Build OVMF Firmware from edk2 Source
setup_ovmf() {
    info "Building OVMF UEFI firmware from edk2 source..."

    # Clone edk2
    cd "${TOOLS}"

    if [[ ! -d "${EDK2_SRC}" ]]; then
        git clone --recurse-submodules \
            https://github.com/tianocore/edk2.git
    fi

    cd "${EDK2_SRC}"

    # Ensure all submodules (CryptoPkg/openssl, etc.) are fully initialised.
    git submodule update --init --recursive

    # Bootstrap the edk2 build toolchain 
    # BaseTools must be compiled before any package can be built.
    info "Compiling edk2 BaseTools..."
    make -C BaseTools -j"$(nproc)"

    # Initialise the edk2 shell environment (defines EDK_TOOLS_PATH, etc.).
    export PYTHON3_ENABLE=TRUE
    export PYTHON_COMMAND=python3
    # shellcheck source=/dev/null
    source edksetup.sh --reconfig

    # Resolve the active GCC toolchain tag 
    if grep -q "^GCC_" Conf/tools_def.txt 2>/dev/null; then
        EDK2_GCC_TAG="GCC"
    elif grep -q "^GCC5_" Conf/tools_def.txt 2>/dev/null; then
        EDK2_GCC_TAG="GCC5"
    else
        die "Cannot find a GCC toolchain tag (GCC or GCC5) in Conf/tools_def.txt"
    fi
    info "Using edk2 toolchain tag: ${EDK2_GCC_TAG}"

    # Build OvmfPkg for x86-64 with a 4 MB flash layout
    info "Building OvmfPkg (x86-64, 4 MB, RELEASE/no-secboot — matches Ubuntu APT binary)..."
    build \
        -a X64 \
        -t "${EDK2_GCC_TAG}" \
        -b RELEASE \
        -p OvmfPkg/OvmfPkgX64.dsc \
        -D FD_SIZE_4MB \
        -D CC_MEASUREMENT_ENABLE=TRUE \
        -D NETWORK_HTTP_BOOT_ENABLE=TRUE \
        -D NETWORK_IP6_ENABLE=TRUE \
        -D NETWORK_TLS_ENABLE \
        -D TPM2_ENABLE=TRUE \
        --pcd PcdUninstallMemAttrProtocol=TRUE \
        -n "$(nproc)"

    # Install firmware images into the images directory 
    EDK2_FV="${EDK2_SRC}/Build/OvmfX64/RELEASE_${EDK2_GCC_TAG}/FV"

    [[ -f "${EDK2_FV}/OVMF_CODE.fd" ]] \
        || die "OvmfPkg build succeeded but OVMF_CODE.fd not found in ${EDK2_FV}"
    [[ -f "${EDK2_FV}/OVMF_VARS.fd" ]] \
        || die "OvmfPkg build succeeded but OVMF_VARS.fd not found in ${EDK2_FV}"

    cd "${IMAGES}"

    # Copy the read-only code store.
    cp "${EDK2_FV}/OVMF_CODE.fd" ./OVMF_CODE.fd

    # Copy a pristine variable store template.
    cp "${EDK2_FV}/OVMF_VARS.fd" ./OVMF_VARS.fd

    # Confirm these are plain files, not symlinks.
    file ./OVMF_CODE.fd
    file ./OVMF_VARS.fd

    success "OVMF firmware built from edk2 and ready at ${IMAGES}."
}

# 7. Prepare Ubuntu Noble Cloud Image
prepare_guest_image() {
    info "Downloading Ubuntu Noble cloud image..."

    cd "${IMAGES}"

    if [[ ! -f noble-server-cloudimg-amd64.img ]]; then
        wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    fi

    info "Converting to qcow2 and expanding to 20 GB..."
    qemu-img convert \
        -O qcow2 \
        noble-server-cloudimg-amd64.img \
        cxl-guest.qcow2

    qemu-img resize -f qcow2 cxl-guest.qcow2 20G

    success "Guest image ready at ${IMAGES}/cxl-guest.qcow2"
}

# 8. Guest Customization
customize_guest() {
    info "Customizing guest image..."

    cd "${IMAGES}"

    # Static Netplan config: bring up every Ethernet interface via DHCP.
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

    # Use direct libguestfs backend to avoid nested-KVM permission panics
    # when virt-customize builds its supermin appliance.
    export LIBGUESTFS_BACKEND=direct

    # 1. Set root password
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --root-password password:cxladmin

    # 2. Disable cloud-init (we inject config manually)
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'touch /etc/cloud/cloud-init.disabled'

    # 3. Enable serial console for -nographic boot
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'systemctl enable serial-getty@ttyS0.service'

    # 4. Allow root SSH with password (disabled by default on cloud images)
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config'

    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config'

    # 5. Inject Netplan config so guest has network on first boot
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in 01-dhcp.yaml:/etc/netplan/

    # 6. Synchronise the custom 6.18 CXL kernel modules into the guest
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in "${IMAGES}/modules/lib/modules:/lib/"

    # 7. Install ndctl inside the guest for CXL userspace management
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'apt-get update && apt-get install -y ndctl'

    # 8. Permanently suppress the systemd-networkd-wait-online hang that
    #    would stall the boot sequence by up to 90 seconds.
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'systemctl disable systemd-networkd-wait-online.service; systemctl mask systemd-networkd-wait-online.service'

    success "Guest customization complete."
}

# 9. Prepare CXL Memory Backing Files
prepare_cxl_backing_files() {
    info "Creating CXL memory backing files..."

    cd "${IMAGES}"

    # Persistent memory backing (1 GB) — mapped as the CXL Type 3 device.
    dd if=/dev/zero of=cxl-mem0.raw  bs=1M count=1024 status=progress

    # Label Storage Area backing (256 MB) — stores region and namespace labels.
    dd if=/dev/zero of=cxl-lsa0.raw  bs=1M count=256  status=progress

    # Volatile memory backing (512 MB) — used by memory-backend-ram object.
    dd if=/dev/zero of=cxl-vmem0.raw bs=1M count=512  status=progress

    # Restrict permissions on multi-user systems.
    chmod 660 "${IMAGES}"/cxl-*.raw

    # Remove stale QMP socket from a previous run, if present.
    [[ -e /tmp/qmp-sock ]] && rm -f /tmp/qmp-sock

    # Ensure the kernel image is in place (defensive copy).
    cp "${KERNEL_SRC}/arch/x86/boot/bzImage" \
        "${IMAGES}/bzImage-6.18-cxl"

    success "CXL backing files ready."
}

# 10. Environment Validation
validate_environment() {
    info "Validating complete environment before VM launch..."

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

    [[ -f "${IMAGES}/cxl-mem0.raw" ]] \
        && success "cxl-mem0.raw present." \
        || die "cxl-mem0.raw missing."

    [[ -f "${IMAGES}/cxl-lsa0.raw" ]] \
        && success "cxl-lsa0.raw present." \
        || die "cxl-lsa0.raw missing."

    [[ -f "${IMAGES}/cxl-vmem0.raw" ]] \
        && success "cxl-vmem0.raw present." \
        || die "cxl-vmem0.raw missing."

    success "All pre-flight checks passed."
}

# 11. Launch CXL Type 3 Memory Expansion VM
launch_cxl_vm() {
    info "Launching CXL Type 3 Memory Expansion topology..."
    info "  Topology: 1 host bridge → 1 root port → 1 CXL Type 3 persistent endpoint"
    info "  SSH access via:  ssh root@localhost -p 2222  (password: cxladmin)"
    info "  QMP socket:      /tmp/qmp-sock"
    info "  Press Ctrl-A X to exit the QEMU serial console."

    cd "${IMAGES}"

    # -cpu host,migratable=off   — expose all host CPU features; migration
    # boundaries must not mask hardware capability flags required by CXL.
    
    # root=LABEL=cloudimg-rootfs rootwait
    # — because we boot directly without initramfs, the kernel must wait for 
    # the VirtIO block device to initialise before mounting root.
    # rootwait prevents VFS kernel panics.
    
    # lsa=cxl-lsa0 — matches the memory-backend-file id defined
    # below; note the PDF has a typo ("cxllsa0").

    "${QEMU_INSTALL}/bin/qemu-system-x86_64" \
        -machine q35,cxl=on,accel=kvm \
        -cpu host,migratable=off \
        -smp 4 \
        -m 8G,maxmem=16G,slots=4 \
        -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
        -kernel ./bzImage-6.18-cxl \
        -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0 rw cloud-init=disabled" \
        -drive file=./cxl-guest.qcow2,format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        -nographic \
        -d guest_errors \
        -qmp unix:/tmp/qmp-sock,server=on,wait=off \
        -object memory-backend-file,id=cxl-mem0,share=on,mem-path=./cxl-mem0.raw,size=1G \
        -object memory-backend-file,id=cxl-lsa0,share=on,mem-path=./cxl-lsa0.raw,size=256M \
        -object memory-backend-ram,id=vmem0,size=512M \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        -device cxl-rp,port=0,bus=cxl.1,id=root_port13,chassis=0,slot=2 \
        -device cxl-type3,bus=root_port13,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxlpmem0,sn=0x1 \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k
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
    prepare_cxl_backing_files
    validate_environment

    success " CXL host setup complete. Launching VM..."

    launch_cxl_vm
}

main "$@"
