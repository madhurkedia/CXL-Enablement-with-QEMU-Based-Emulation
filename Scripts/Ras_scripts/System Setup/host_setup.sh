#!/usr/bin/env bash

# CXL RAS Emulation — Consolidated Setup Script
# Version  : 2.0.0
# Platform : Ubuntu 24.04.4 LTS (Noble Numbat) — Host side

set -euo pipefail

# Mode Parsing (before everything — helpers reference it) 
MODE="${1:-}"

# Error Handler 
# Prints exact line, exit code, failed command and full call stack on ERR.
error_handler() {
    local exit_code=$?
    local line_number=$1
    local failed_cmd="$2"
    echo "  SCRIPT FAILED"
    echo "  Line      : ${line_number}"
    echo "  Exit code : ${exit_code}"
    echo "  Command   : ${failed_cmd}"
    if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
        echo "  Call stack :"
        for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
            echo "    [$i] ${FUNCNAME[$i]}  (line ${BASH_LINENO[$i-1]}" \
                 "in ${BASH_SOURCE[$i]:-main})"
        done
    fi
    echo "  Script    : ${BASH_SOURCE[0]}"
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
GUEST_IMAGE="${IMAGES}/cxl-guest.qcow2"
QEMU_BIN="${QEMU_INSTALL}/bin/qemu-system-x86_64"
QMP_PORT="4444"
QEMU_LOG="/tmp/qemu.log"

# Colour Helpers
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

info()    { echo -e "[INFO]  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${RED}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
section() { echo -e "\n══ $* ══"; }

# Usage / Help
usage() {
    sed -n '/^# ── Usage/,/^# ──/p' "$0" | sed 's/^#\s\?//' | head -n -1
    exit 0
}
[[ "$MODE" == "--help" || "$MODE" == "-h" ]] && usage


# SECTION 1 — Workspace Setup (HOST)
create_workspace() {
    section "SECTION 1 — Workspace Setup"
    info "Creating workspace directories under ${WORKSPACE}..."

    sudo mkdir -p "${QEMU_BUILD}"
    sudo mkdir -p "${KERNEL_BUILD}"
    sudo mkdir -p "${IMAGES}"
    sudo mkdir -p "${TOOLS}"
    sudo mkdir -p "${QEMU_INSTALL}"

    # Hand ownership to the invoking user so git/make/dd run without sudo.
    sudo chown -R "$USER:$USER" "${WORKSPACE}"

    success "Workspace ready: ${WORKSPACE}"
}


# SECTION 2 — KVM Setup (HOST)
setup_kvm() {
    section "SECTION 2 — KVM Setup"
    info "Adding ${USER} to kvm group..."
    sudo usermod -aG kvm "$USER"

    if groups | grep -q kvm; then
        success "Current session already has kvm group access."
    else
        warn "Group change requires re-login or: newgrp kvm"
    fi

    if [[ -c /dev/kvm ]]; then
        success "/dev/kvm present."
    else
        warn "/dev/kvm not found — BIOS/UEFI virtualisation may be disabled."
        warn "RAS injection may be unreliable under software TCG emulation."
    fi

    # Proactively load KVM modules; modprobe is a no-op if already loaded.
    # Both Intel (vmx) and AMD (svm) variants are attempted; one will fail
    # silently depending on CPU vendor — that is expected.
    sudo modprobe kvm         2>/dev/null || true
    sudo modprobe kvm_intel   2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

    if lsmod | grep -q "^kvm "; then
        success "KVM kernel modules loaded."
    else
        warn "KVM module not loaded — QEMU will warn at startup."
    fi
}


# SECTION 3 — Dependency Installation (HOST)
install_dependencies() {
    section "SECTION 3 — Dependency Installation"
    info "Updating package index and performing dist-upgrade..."
    sudo apt-get update
    sudo apt-get dist-upgrade -y

    info "Installing primary dependency set..."
    sudo apt-get install --no-install-recommends -y \
        \
        build-essential git ccache flex bison bc pkg-config \
        automake autoconf libtool ninja-build meson cmake \
        python3 python3-venv python3-pip python3-dev \
        python3-sphinx python3-sphinx-rtd-theme \
        ca-certificates wget curl \
        \
        libglib2.0-dev libpixman-1-dev zlib1g-dev libgcrypt20-dev \
        libfdt-dev libffi-dev libslirp-dev liburing-dev libnfs-dev \
        libcurl4-gnutls-dev libzstd-dev libgudev-1.0-dev libaio-dev \
        libpmem-dev libpmem2-dev libssh-dev dbus-daemon dwarves perl \
        \
        bridge-utils libncurses-dev libssl-dev libelf-dev libudev-dev \
        libpci-dev llvm clang asciidoc asciidoctor ruby-asciidoctor \
        xmlto libkmod-dev libsystemd-dev uuid-dev libjson-c-dev \
        libkeyutils-dev libiniparser-dev libtraceevent-dev libtracefs-dev \
        libnl-3-dev libnl-route-3-dev libibverbs-dev librdmacm-dev \
        libusb-1.0-0-dev libepoxy-dev libdrm-dev libgbm-dev libegl1-mesa-dev \
        \
        libvirglrenderer-dev libsdl2-dev libgtk-3-dev \
        libvte-2.91-dev libpulse-dev libjack-dev \
        libspice-protocol-dev libspice-server-dev \
        xfslibs-dev libbpf-dev \
        \
        ovmf qemu-utils libguestfs-tools \
        socat numactl iproute2 netcat-openbsd \
        sparse cscope exuberant-ctags \
        \
        ndctl \
        linux-image-generic

    # Enable deb-src so build-dep can resolve hidden QEMU dependencies 
    info "Enabling deb-src repositories for build-dep resolution..."
    if grep -q '^Types: deb$' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
        sudo sed -i 's/^Types: deb$/Types: deb deb-src/' \
            /etc/apt/sources.list.d/ubuntu.sources
        sudo apt-get update
    fi
    sudo apt-get build-dep qemu -y

    # Re-confirm libguestfs-tools — build-dep can displace it 
    sudo apt-get install -y libguestfs-tools

    # Persist LIBGUESTFS_BACKEND for all future interactive sessions 
    if ! grep -q 'LIBGUESTFS_BACKEND' ~/.bashrc; then
        echo 'export LIBGUESTFS_BACKEND=direct' >> ~/.bashrc
        info "Added LIBGUESTFS_BACKEND=direct to ~/.bashrc"
    fi

    success "All dependencies installed."
}


# SECTION 4 — Build QEMU (Jonathan Cameron / jic23 CXL Fork) (HOST)
build_qemu() {
    section "SECTION 4 — QEMU Build (jic23 CXL Fork)"
    info "Cloning / updating CXL QEMU from gitlab.com/jic23/qemu..."

    cd "${QEMU_BUILD}"

    if [[ ! -d "${QEMU_SRC}" ]]; then
        git clone https://gitlab.com/jic23/qemu.git
    fi

    cd "${QEMU_SRC}"

    git fetch origin

    # -B resets the tracking branch if it already exists → idempotent
    git checkout -B cxl-stable origin/cxl-2025-03-20

    git submodule update --init --recursive

    # Apply replay-tools type-mismatch patch
    info "Patching stubs/replay-tools.c (ReplayClockKind type mismatch)..."
    sed -i 's/unsigned int kind/ReplayClockKind kind/g' \
        stubs/replay-tools.c 2>/dev/null || true

    info "Configuring QEMU (target: x86_64-softmmu)..."
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

    info "Building QEMU — approx. 10 min on a 4-core machine..."
    make -j"$(nproc)"
    make install

    success "QEMU build complete:"
    "${QEMU_BIN}" --version

    # Verify CXL device model is present in the built binary 
    info "Verifying CXL device support in binary..."
    if "${QEMU_BIN}" -device help 2>&1 | grep -qi cxl; then
        success "CXL devices confirmed in QEMU binary."
        "${QEMU_BIN}" -device help 2>&1 | grep -i cxl | sed 's/^/  /'
    else
        die "CXL devices NOT found in QEMU binary — check configure/build output."
    fi
}


# SECTION 5 — Build Linux 6.18 Kernel (CXL + Full RAS) (HOST → GUEST)
build_kernel() {
    section "SECTION 5 — Kernel Build (Linux v6.18, CXL + RAS)"
    info "Cloning / verifying Linux v6.18 source..."

    cd "${KERNEL_BUILD}"

    if [[ ! -d "${KERNEL_SRC}" ]]; then
        git clone --depth=1 --branch v6.18 \
            https://github.com/torvalds/linux.git
    else
        info "Kernel source already present — skipping clone."
    fi

    cd "${KERNEL_SRC}"

    info "Generating base defconfig + KVM guest overlay..."
    make defconfig
    make kvm_guest.config

    info "Injecting CXL and RAS Kconfig options..."

    # Core CXL Subsystem
    ./scripts/config --enable CONFIG_EXPERT
    ./scripts/config --enable CONFIG_CXL_BUS
    ./scripts/config --enable CONFIG_CXL_PCI
    ./scripts/config --enable CONFIG_CXL_ACPI
    ./scripts/config --enable CONFIG_CXL_PMEM
    ./scripts/config --enable CONFIG_CXL_MEM
    ./scripts/config --enable CONFIG_CXL_PORT
    ./scripts/config --enable CONFIG_CXL_REGION
    ./scripts/config --enable CONFIG_CXL_MEM_RAW_COMMANDS
    ./scripts/config --enable CONFIG_CXL_FEATURES           
    ./scripts/config --enable CONFIG_CXL_SUSPEND
    ./scripts/config --enable CONFIG_CXL_REGION_INVALIDATION_TEST

    # RAS Infrastructure 
    # MEMORY_FAILURE must precede RAS to gate CONFIG_CXL_MCE correctly
    ./scripts/config --enable CONFIG_MEMORY_FAILURE          
    ./scripts/config --enable CONFIG_ACPI_APEI               
    ./scripts/config --enable CONFIG_ACPI_APEI_GHES          
    ./scripts/config --enable CONFIG_RAS
    ./scripts/config --enable CONFIG_PCIEAER
    ./scripts/config --enable CONFIG_PCIEAER_CXL             
    ./scripts/config --enable CONFIG_X86_MCE                 
    ./scripts/config --enable CONFIG_EDAC                    

    # DAX / PMEM / Zone Device 
    ./scripts/config --enable CONFIG_ZONE_DEVICE
    ./scripts/config --enable CONFIG_DEV_DAX
    ./scripts/config --enable CONFIG_DEV_DAX_CXL
    ./scripts/config --enable CONFIG_DEV_DAX_PMEM            
    ./scripts/config --enable CONFIG_FS_DAX                  
    ./scripts/config --enable CONFIG_LIBNVDIMM               
    ./scripts/config --enable CONFIG_BLK_DEV_PMEM            

    # Memory Hotplug / NUMA 
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG
    ./scripts/config --enable CONFIG_MEMORY_HOTPLUG_DEFAULT_ONLINE
    ./scripts/config --enable CONFIG_MEMORY_HOTREMOVE        
    ./scripts/config --enable CONFIG_NUMA
    ./scripts/config --enable CONFIG_ACPI_NUMA

    # Filesystem 
    ./scripts/config --enable CONFIG_EXT4_FS
    ./scripts/config --enable CONFIG_DEBUG_FS

    # Tracing / Debugging 
    ./scripts/config --enable CONFIG_TRACING_SUPPORT         
    ./scripts/config --enable CONFIG_GENERIC_TRACER          
    ./scripts/config --enable CONFIG_FTRACE                  
    ./scripts/config --enable CONFIG_TRACE_CLOCK             
    ./scripts/config --enable CONFIG_RING_BUFFER             
    ./scripts/config --enable CONFIG_EVENT_TRACING           
    ./scripts/config --enable CONFIG_DYNAMIC_DEBUG           

    # Resolve newly introduced Kconfig dependency chains 
    make olddefconfig

    info "Compiling kernel + modules — approx. 20-40 min depending on CPU count..."
    mkdir -p "${IMAGES}/modules"
    make -j"$(nproc)" bzImage modules

    make modules_install INSTALL_MOD_PATH="${IMAGES}/modules"

    cp arch/x86/boot/bzImage "${IMAGES}/bzImage-6.18-cxl"

    success "Kernel build complete: ${IMAGES}/bzImage-6.18-cxl"

    # Opportunistic module injection
    # If the guest image already exists (e.g. --kernel rebuild after full setup),
    # inject modules now so a full re-customize is not needed.
    # If the image does not yet exist, customize_guest() handles injection later.
    if [[ -f "${GUEST_IMAGE}" ]]; then
        info "Guest image found — injecting updated kernel modules..."
        export LIBGUESTFS_BACKEND=direct
        if sudo virt-customize \
                -a "${GUEST_IMAGE}" \
                --copy-in "${IMAGES}/modules/lib/modules:/lib/"; then
            success "Kernel modules injected into guest image."
        else
            warn "Module injection failed — will retry in customize_guest()."
        fi
    else
        info "Guest image not yet present — module injection deferred to Section 8."
    fi
}

# SECTION 6 — OVMF UEFI Firmware Setup (HOST)
setup_ovmf() {
    section "SECTION 6 — OVMF UEFI Firmware Setup"
    info "Copying OVMF firmware files to ${IMAGES}/..."

    cd "${IMAGES}"

    # Confirm OVMF package is installed before attempting copy
    ls /usr/share/OVMF/OVMF_*.fd > /dev/null 2>&1 \
        || die "OVMF firmware not found — ensure 'ovmf' package is installed."

    cp /usr/share/OVMF/OVMF_CODE*.fd .
    cp /usr/share/OVMF/OVMF_VARS*.fd .

    # Ubuntu Noble ships 4M variants; rename to the canonical names QEMU expects
    mv OVMF_CODE_4M.fd OVMF_CODE.fd 2>/dev/null || true
    mv OVMF_VARS_4M.fd OVMF_VARS.fd 2>/dev/null || true

    # Confirm these are regular files, not dangling symlinks
    file ./OVMF_CODE.fd
    file ./OVMF_VARS.fd

    success "OVMF firmware ready."
}


# SECTION 7 — Ubuntu Noble Cloud Image Preparation (HOST)
prepare_guest_image() {
    section "SECTION 7 — Guest Image Preparation"
    info "Downloading Ubuntu Noble (24.04) cloud image..."

    cd "${IMAGES}"

    if [[ ! -f noble-server-cloudimg-amd64.img ]]; then
        wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    else
        info "Cloud image already present — skipping download."
    fi

    info "Converting to qcow2 and expanding to 20 GiB..."
    qemu-img convert \
        -O qcow2 \
        noble-server-cloudimg-amd64.img \
        cxl-guest.qcow2

    qemu-img resize -f qcow2 cxl-guest.qcow2 20G

    success "Guest image ready: ${IMAGES}/cxl-guest.qcow2"
}


# SECTION 8 — Guest Image Customization (HOST, via virt-customize) (HOST→GUEST)
customize_guest() {
    section "SECTION 8 — Guest Image Customization"
    info "Customizing guest image via virt-customize (8 steps)..."

    cd "${IMAGES}"

    # Generate Netplan config for injection 
    cat << 'NETPLAN_EOF' > 01-dhcp.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    all_eth:
      match:
        name: "e*"
      dhcp4: true
NETPLAN_EOF

    # Required for this shell's invocation of virt-customize (not just ~/.bashrc)
    export LIBGUESTFS_BACKEND=direct

    # 1. Set root password
    info "  [1/8] Setting root password to 'cxladmin'..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --root-password password:cxladmin

    # 2. Disable cloud-init
    info "  [2/8] Disabling cloud-init..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'touch /etc/cloud/cloud-init.disabled'

    # 3. Enable ttyS0 serial getty (required for -nographic console)
    info "  [3/8] Enabling serial-getty@ttyS0..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'systemctl enable serial-getty@ttyS0.service'

    # 4. Allow root SSH with password authentication
    info "  [4/8] Enabling root SSH + password auth in sshd_config..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command \
        'sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config'
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command \
        'sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config'

    # 5. Inject Netplan DHCP config
    info "  [5/8] Injecting Netplan DHCP config (01-dhcp.yaml → /etc/netplan/)..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in 01-dhcp.yaml:/etc/netplan/

    # 6. Inject custom Linux 6.18 CXL kernel modules
    info "  [6/8] Injecting kernel modules (6.18 CXL build)..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --copy-in "${IMAGES}/modules/lib/modules:/lib/"

    # 7. Install ndctl (cxl-cli) and pciutils (setpci) inside the guest.
    info "  [7/8] Installing ndctl + pciutils inside guest..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command 'apt-get update && apt-get install -y ndctl pciutils'

    # 8. Disable + mask systemd-networkd-wait-online (prevents 90-second stall)
    info "  [8/8] Masking systemd-networkd-wait-online..."
    sudo virt-customize \
        -a cxl-guest.qcow2 \
        --run-command \
        'systemctl disable systemd-networkd-wait-online.service; \
         systemctl mask    systemd-networkd-wait-online.service'

    success "Guest customization complete."
}


# SECTION 9 — CXL Memory Backing Files (HOST)
prepare_cxl_backing_files() {
    section "SECTION 9 — CXL Memory Backing Files"
    info "Creating persistent-topology CXL raw backing files..."

    cd "${IMAGES}"

    if [[ ! -f cxl-mem0.raw ]]; then
        info "Creating cxl-mem0.raw (1 GiB persistent pmem backing)..."
        dd if=/dev/zero of=cxl-mem0.raw  bs=1M count=1024 status=progress
    else
        info "cxl-mem0.raw already exists — skipping."
    fi

    if [[ ! -f cxl-lsa0.raw ]]; then
        info "Creating cxl-lsa0.raw (256 MiB Label Storage Area backing)..."
        dd if=/dev/zero of=cxl-lsa0.raw  bs=1M count=256  status=progress
    else
        info "cxl-lsa0.raw already exists — skipping."
    fi

    if [[ ! -f cxl-vmem0.raw ]]; then
        info "Creating cxl-vmem0.raw (512 MiB legacy vmem placeholder)..."
        dd if=/dev/zero of=cxl-vmem0.raw bs=1M count=512  status=progress
    else
        info "cxl-vmem0.raw already exists — skipping."
    fi

    chmod 660 "${IMAGES}"/cxl-*.raw

    # Clean stale QMP socket from any previous QEMU run
    [[ -e /tmp/qmp-sock ]] && rm -f /tmp/qmp-sock && info "Removed stale /tmp/qmp-sock"

    # Defensive kernel image copy — ensures bzImage is in IMAGES/ even if
    # invoked after a --kernel-only rebuild without re-running this section.
    cp "${KERNEL_SRC}/arch/x86/boot/bzImage" \
        "${IMAGES}/bzImage-6.18-cxl"
    success "Kernel image copied: ${IMAGES}/bzImage-6.18-cxl"

    success "CXL memory backing files ready."
}

# SECTION 10 — Pre-flight Environment Validation (HOST)
validate_environment() {
    section "SECTION 11 — Pre-flight Validation"
    local errors=0

    _check_file() {
        if [[ -f "$1" ]]; then
            success "$2"
        else
            warn "MISSING — $2 : $1"
            (( errors++ )) || true
        fi
    }
    _check_exec() {
        if [[ -x "$1" ]]; then
            success "$2"
        else
            warn "NOT EXECUTABLE — $2 : $1"
            (( errors++ )) || true
        fi
    }

    _check_exec "${QEMU_BIN}"                    "QEMU binary"
    _check_file "${IMAGES}/bzImage-6.18-cxl"     "Guest kernel bzImage"
    _check_file "${IMAGES}/OVMF_CODE.fd"         "OVMF_CODE.fd (UEFI code flash)"
    _check_file "${IMAGES}/OVMF_VARS.fd"         "OVMF_VARS.fd (UEFI vars flash)"
    _check_file "${GUEST_IMAGE}"                  "Guest qcow2 image"
    _check_file "${IMAGES}/cxl-mem0.raw"         "cxl-mem0.raw  (persistent pmem)"
    _check_file "${IMAGES}/cxl-lsa0.raw"         "cxl-lsa0.raw  (Label Storage Area)"
    _check_file "${IMAGES}/cxl-vmem0.raw"        "cxl-vmem0.raw (legacy placeholder)"
    _check_file "${IMAGES}/ras_guest_setup.sh"   "Guest RAS setup script"

    # Verify QMP TCP port is not already bound (stale QEMU process)
    if ss -tlnp 2>/dev/null | grep -q ":${QMP_PORT} "; then
        warn "TCP port ${QMP_PORT} already in use — QEMU may already be running."
        warn "To kill stale instance: pkill -f qemu-system-x86_64"
        (( errors++ )) || true
    else
        success "QMP TCP port ${QMP_PORT} available."
    fi

    # Clean any stale QMP unix socket
    if [[ -e /tmp/qmp-sock ]]; then
        rm -f /tmp/qmp-sock
        info "Removed stale /tmp/qmp-sock"
    fi

    if [[ $errors -gt 0 ]]; then
        die "${errors} pre-flight check(s) failed — resolve above before launch."
    fi

    success "All pre-flight checks passed."
}


# SECTION 11 — Launch CXL VM  (RAS Topology — 2 Volatile Type-3 Endpoints)
# (HOST → runs QEMU)

# Topology 
#   pxb-cxl  bus_nr=12 (PCIe bus 0x0c)
#     ├── cxl-rp  port=0  id=rp0  (0000:0c:00.0)
#     │     └── cxl-type3  volatile  512 MiB  id=cxl0  sn=0x1
#     │           memory-backend-ram id=cxl-vmem0
#     │           → guest /sys/bus/cxl/devices/mem0
#     └── cxl-rp  port=1  id=rp1  (0000:0c:01.0)
#           └── cxl-type3  volatile  512 MiB  id=cxl1  sn=0x2
#                 memory-backend-ram id=cxl-vmem1
#                 → guest /sys/bus/cxl/devices/mem1
launch_cxl_vm() {
    section "SECTION 11 — Launching CXL VM (RAS Topology)"
    info "Topology  : 2 volatile Type-3 endpoints (mem0 + mem1)"
    info "QMP TCP   : nc 127.0.0.1 ${QMP_PORT}   then: {\"execute\":\"qmp_capabilities\"}"
    info "QMP UNIX  : /tmp/qmp-sock"
    info "SSH       : ssh -p 2222 root@127.0.0.1   password: cxladmin"
    info "QEMU log  : ${QEMU_LOG}  (includes trace:cxl* events)"
    info "Console   : Ctrl-A X to exit QEMU serial console"
    info "After the guest boots, run the RAS guest setup script:"
    info "  scp -P 2222 ${IMAGES}/ras_guest_setup.sh root@127.0.0.1:/root/"
    info "  ssh -p 2222 root@127.0.0.1 'bash /root/ras_guest_setup.sh'"

    rm -f "${QEMU_LOG}"
    cd "${IMAGES}"

    # exec replaces the shell process — no cleanup needed after QEMU exits.
    exec "${QEMU_BIN}" \
        \
        -machine q35,cxl=on,accel=kvm \
        -cpu     host,migratable=off \
        -smp     4 \
        -m       8G,maxmem=16G,slots=4 \
        \
        -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
        \
        -kernel ./bzImage-6.18-cxl \
        -append "root=/dev/vda1 rootwait rootdelay=5 \
console=ttyS0,115200 earlyprintk=ttyS0 rw cloud-init=disabled" \
        \
        -drive  file=./cxl-guest.qcow2,format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        \
        -nographic \
        -D "${QEMU_LOG}" \
        -d guest_errors,trace:cxl* \
        \
        -chardev socket,id=qmp-tcp,host=127.0.0.1,port="${QMP_PORT}",server=on,wait=off \
        -mon    chardev=qmp-tcp,mode=control \
        -chardev socket,id=qmp-unix,path=/tmp/qmp-sock,server=on,wait=off \
        -mon    chardev=qmp-unix,mode=control \
        \
        -object memory-backend-ram,id=cxl-vmem0,size=512M \
        -object memory-backend-ram,id=cxl-vmem1,size=512M \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
        -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3 \
        -device cxl-type3,bus=rp0,volatile-memdev=cxl-vmem0,id=cxl0,sn=0x1 \
        -device cxl-type3,bus=rp1,volatile-memdev=cxl-vmem1,id=cxl1,sn=0x2 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k
}

# Main Controller
main() {
    echo "   CXL RAS Emulation — Consolidated Setup  v2.0.0    "
    echo "   Host OS: $(lsb_release -ds 2>/dev/null || uname -r)  "

    case "$MODE" in

        --qemu)
            # Rebuild QEMU only (e.g. after upstream branch update)
            build_qemu
            success "QEMU rebuild complete."
            info "Re-run without flags (or with --launch) to start the VM."
            ;;

        --kernel)
            # Rebuild kernel only + re-inject modules into existing guest image
            build_kernel
            success "Kernel rebuild complete."
            info "Re-run without flags (or with --launch) to start the VM."
            ;;

        --build)
            # Build both QEMU and kernel; do NOT prepare images or launch.
            # Useful when building on a machine that will run the VM elsewhere.
            build_qemu
            build_kernel
            success "QEMU + kernel build complete."
            info "Run without --build flags to continue image prep + launch."
            ;;

        --launch)
            # Validates presence of all required files then launches the VM.
            validate_environment
            launch_cxl_vm
            ;;

        "")
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
            success "Full CXL RAS host setup complete — launching VM "
            launch_cxl_vm             
            ;;

        *)
            die "Unknown argument: '$MODE'  —  run with --help for usage."
            ;;

    esac
}

main "$@"