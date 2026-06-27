#!/bin/bash
# CXL Full Support — Error Injection and Topology Emulation Setup
#
# Objectives:
#   - Builds a custom WSL2 kernel with KVM support
#   - Builds QEMU (jic23 CXL fork) with 3 critical CXL RAS patches
#   - Builds Linux 6.18 guest kernel with full CXL + RAS + PMEM support
#   - Sets up Ubuntu 24.04 guest VM with ndctl and cxl-cli tools
#   - Creates volatile CXL backing files  (for error injection)
#   - Creates persistent CXL backing files (for PMEM topology)
#   - Sets up OVMF UEFI firmware           (for PMEM topology)



set -euo pipefail

# CONFIGURATION 
WINDOWS_USER="User"
WINDOWS_PATH="/mnt/c/Users/${WINDOWS_USER}"
CXL_LAB_DIR="${HOME}/cxl_lab"
CXL_DIR="${CXL_LAB_DIR}/cxl"
QEMU_DIR="${CXL_LAB_DIR}/qemu"
WSL_KERNEL_DIR="${HOME}/WSL2-Linux-Kernel"

mkdir -p "${CXL_LAB_DIR}"
mkdir -p "${CXL_DIR}"

# Colour helpers
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

error_handler() {
    local exit_code=$?
    local line_number=$1
    local failed_command="$2"
    echo ""
    echo -e "${RED}SCRIPT FAILED${NC}"
    echo -e "${RED}  Line     : ${line_number}${NC}"
    echo -e "${RED}  Exit code: ${exit_code}${NC}"
    echo -e "${RED}  Command  : ${failed_command}${NC}"
    if [[ ${#FUNCNAME[@]} -gt 1 ]]; then
        echo -e "${YELLOW}  Call stack:${NC}"
        for (( i=1; i<${#FUNCNAME[@]}; i++ )); do
            echo -e "${YELLOW}    [$i] ${FUNCNAME[$i]} (line ${BASH_LINENO[$i-1]})${NC}"
        done
    fi
    echo ""
}
trap 'error_handler ${LINENO} "${BASH_COMMAND}"' ERR

echo ""
echo "  CXL Full Support — Error Injection and Topology"
echo "  Emulation Setup"
echo ""

phase1_dependencies() {
    info "PHASE 1: Installing build dependencies..."

    sudo apt-get update
    sudo apt-get install -y \
        build-essential flex bison libssl-dev libelf-dev bc python3 \
        pahole dwarves git wget curl nano ndctl libndctl-dev \
        ninja-build pkg-config libglib2.0-dev libpixman-1-dev \
        libslirp-dev python3-pip meson cloud-image-utils \
        libfdt-dev libffi-dev liburing-dev libaio-dev \
        libpmem-dev libpmem2-dev uuid-dev libjson-c-dev \
        libncurses-dev libudev-dev libpci-dev \
        ovmf qemu-utils libguestfs-tools socat \
        bridge-utils iproute2 netcat-openbsd pciutils

    if ! grep -q 'LIBGUESTFS_BACKEND' ~/.bashrc; then
        echo 'export LIBGUESTFS_BACKEND=direct' >> ~/.bashrc
    fi

    success "Dependencies installed."
}


phase2_wsl2_kernel() {
    info "PHASE 2: Building custom WSL2 kernel with KVM support..."

    # Skip if KVM already loaded or .wslconfig already written
    if lsmod | grep -q kvm || \
       [[ -f "/mnt/c/Users/${WINDOWS_USER}/.wslconfig" ]]; then
        success "WSL2 kernel already active — skipping Phase 2."
        return 0
    fi

    cd ~
    if [[ ! -d "${WSL_KERNEL_DIR}" ]]; then
        git clone https://github.com/microsoft/WSL2-Linux-Kernel.git \
            --depth=1 -b linux-msft-wsl-6.6.y
    fi
    cd "${WSL_KERNEL_DIR}"

    zcat /proc/config.gz > .config
    scripts/config --enable CONFIG_ACPI_APEI_EINJ
    scripts/config --enable CONFIG_KVM
    scripts/config --enable CONFIG_KVM_INTEL
    scripts/config --enable CONFIG_KVM_AMD
    make olddefconfig

    info "Building WSL2 kernel — takes 20-40 minutes..."
    make -j"$(nproc)" 2>&1 | tail -5

    sudo cp arch/x86/boot/bzImage "${WINDOWS_PATH}/wsl_kernel"
    success "WSL2 kernel built and copied to ${WINDOWS_PATH}/wsl_kernel"

    info "Writing .wslconfig automatically..."
    powershell.exe -Command "\$config = \"[wsl2]\`nkernel=C:\\\Users\\\\${WINDOWS_USER}\\\\wsl_kernel\"; Set-Content -Path \"\$env:USERPROFILE\\.wslconfig\" -Value \$config -Encoding UTF8"
    success ".wslconfig written to C:\\Users\\${WINDOWS_USER}\\.wslconfig"

    echo ""
    echo "  WSL2 is shutting down now to apply the new kernel."
    echo "  Please reopen your WSL2 terminal and run this"
    echo "  script again. It will resume from Phase 3 automatically."
    echo ""

    powershell.exe -Command "wsl --shutdown"
    exit 0
}

# PHASE 3: QEMU (jic23 fork) WITH CXL RAS PATCHES
phase3_qemu() {
    info "PHASE 3: Building QEMU (jic23 CXL fork) with CXL RAS patches..."

    # Install KVM modules from WSL2 kernel if available
    if [[ -d "${WSL_KERNEL_DIR}" ]]; then
        info "Installing KVM kernel modules..."
        cd "${WSL_KERNEL_DIR}"
        sudo make modules_install 2>&1 | tail -3
        success "KVM modules installed."
        cd ~
    fi

    cd ~
    if [[ ! -d "${QEMU_DIR}" ]]; then
        git clone https://gitlab.com/jic23/qemu.git \
            --depth=1 -b cxl-2025-03-20 "${QEMU_DIR}"
        cd "${QEMU_DIR}"
        git submodule update --init --recursive
    else
        cd "${QEMU_DIR}"
    fi

    # PATCH 1: Unmask RAS Errors

    info "Applying patch 1: CXL RAS error mask (cxl-component-utils.c)..."
    if grep -q "R_CXL_RAS_UNC_ERR_MASK, 0);" hw/cxl/cxl-component-utils.c; then
        success "Patch 1 already applied, skipping."
    else
        sed -i 's/stl_le_p(reg_state + R_CXL_RAS_UNC_ERR_MASK, 0x1cfff);/stl_le_p(reg_state + R_CXL_RAS_UNC_ERR_MASK, 0);/' \
            hw/cxl/cxl-component-utils.c
        sed -i 's/stl_le_p(reg_state + R_CXL_RAS_COR_ERR_MASK, 0x7f);/stl_le_p(reg_state + R_CXL_RAS_COR_ERR_MASK, 0);/' \
            hw/cxl/cxl-component-utils.c
        grep -q "R_CXL_RAS_UNC_ERR_MASK, 0);" hw/cxl/cxl-component-utils.c \
            && success "Patch 1 applied." \
            || die "Patch 1 failed. Check cxl-component-utils.c manually."
    fi

    # PATCH 2: PCIe AER correctable mask fix
    info "Applying patch 2: PCIe AER correctable mask (cxl_type3.c)..."
    if grep -q "PCI_ERR_COR_INTERNAL" hw/mem/cxl_type3.c; then
        success "Patch 2 already applied, skipping."
    else
        sed -i 's/    rc = pcie_aer_init(pci_dev, PCI_ERR_VER, 0x200, PCI_ERR_SIZEOF, NULL);/    rc = pcie_aer_init(pci_dev, PCI_ERR_VER, 0x200, PCI_ERR_SIZEOF, NULL);\n    pci_long_test_and_clear_mask(pci_dev->config + pci_dev->exp.aer_cap + PCI_ERR_COR_MASK, PCI_ERR_COR_INTERNAL);/' \
            hw/mem/cxl_type3.c
        grep -q "PCI_ERR_COR_INTERNAL" hw/mem/cxl_type3.c \
            && success "Patch 2 applied." \
            || die "Patch 2 failed. Check hw/mem/cxl_type3.c manually."
    fi

    # PATCH 3: Set Partition Info mailbox command
    info "Applying patch 3: Set Partition Info mailbox command..."
    python3 << 'PYEOF'
path = 'hw/cxl/cxl-mailbox-utils.c'
with open(path, 'r') as f:
    content = f.read()

if 'SET_PARTITION_INFO' in content:
    print("  Patch 3 already applied, skipping.")
    exit(0)

content = content.replace(
    '#define GET_PARTITION_INFO     0x0',
    '#define GET_PARTITION_INFO     0x0\n#define SET_PARTITION_INFO     0x1'
)

new_func = '''
/* CXL r3.1 Section 8.2.9.9.2.2: Set Partition Info (Opcode 4101h) */
static CXLRetCode cmd_ccls_set_partition_info(const struct cxl_cmd *cmd,
                                              uint8_t *payload_in,
                                              size_t len_in,
                                              uint8_t *payload_out,
                                              size_t *len_out,
                                              CXLCCI *cci)
{
    CXLDeviceState *cxl_dstate = &CXL_TYPE3(cci->d)->cxl_dstate;
    struct {
        uint64_t next_vmem;
        uint64_t next_pmem;
        uint8_t flags;
    } QEMU_PACKED *set_pi = (void *)payload_in;
    if (len_in < sizeof(*set_pi)) {
        return CXL_MBOX_INVALID_PAYLOAD_LENGTH;
    }
    uint64_t next_vmem = ldq_le_p(&set_pi->next_vmem) * CXL_CAPACITY_MULTIPLIER;
    uint64_t next_pmem = ldq_le_p(&set_pi->next_pmem) * CXL_CAPACITY_MULTIPLIER;
    uint64_t total = cxl_dstate->vmem_size + cxl_dstate->pmem_size;
    if (next_vmem + next_pmem != total) {
        return CXL_MBOX_INVALID_INPUT;
    }
    cxl_dstate->vmem_size = next_vmem;
    cxl_dstate->pmem_size = next_pmem;
    return CXL_MBOX_SUCCESS;
}

'''

insert_after = '    *len_out = sizeof(*part_info);\n    return CXL_MBOX_SUCCESS;\n}\n'
content = content.replace(insert_after, insert_after + new_func, 1)

old_reg = '    [CCLS][GET_PARTITION_INFO] = { "CCLS_GET_PARTITION_INFO",\n        cmd_ccls_get_partition_info, 0, 0 },'
new_reg = old_reg + '\n    [CCLS][SET_PARTITION_INFO] = { "CCLS_SET_PARTITION_INFO",\n        cmd_ccls_set_partition_info, 0x11, CXL_MBOX_IMMEDIATE_CONFIG_CHANGE },'
content = content.replace(old_reg, new_reg, 1)

with open(path, 'w') as f:
    f.write(content)
print("  Patch 3 applied successfully.")
PYEOF

    info "Configuring and building QEMU..."
    mkdir -p build
    cd build
    ../configure \
        --target-list=x86_64-softmmu \
        --enable-slirp \
        --enable-kvm \
        --enable-libpmem \
        --disable-werror
    make -j"$(nproc)" 2>&1 | tail -5

    ./qemu-system-x86_64 -device help 2>&1 | grep -i "cxl-type3" \
        && success "QEMU (jic23 fork) built. CXL devices confirmed." \
        || die "QEMU built but CXL devices not found. Check build output."
}


phase4_guest_kernel() {
    info "PHASE 4: Building Linux 6.18 guest kernel with CXL + RAS + PMEM..."
   
    mkdir -p "${CXL_DIR}"
    cd "${CXL_DIR}"

    if [[ ! -d "linux" ]]; then
        info "Cloning Linux 6.18 kernel..."
        git clone https://github.com/torvalds/linux.git \
            --depth=1 -b v6.18 linux
    fi
    cd linux

    make x86_64_defconfig
    make kvm_guest.config

    # Core CXL subsystem
    scripts/config --enable CONFIG_CXL_BUS
    scripts/config --enable CONFIG_CXL_PCI
    scripts/config --enable CONFIG_CXL_MEM
    scripts/config --enable CONFIG_CXL_ACPI
    scripts/config --enable CONFIG_CXL_PORT
    scripts/config --enable CONFIG_CXL_REGION
    scripts/config --enable CONFIG_CXL_FEATURES
    scripts/config --enable CONFIG_CXL_PMEM
    scripts/config --enable CONFIG_CXL_MEM_RAW_COMMANDS
    scripts/config --enable CONFIG_CXL_SUSPEND
    # Bypasses hardware cache invalidation 
    scripts/config --enable CONFIG_CXL_REGION_INVALIDATION_TEST

    # DAX / PMEM / Zone Device
    scripts/config --enable CONFIG_ZONE_DEVICE
    # TRANSPARENT_HUGEPAGE is a required dependency for DEV_DAX.
    scripts/config --enable CONFIG_TRANSPARENT_HUGEPAGE
    scripts/config --enable CONFIG_DEV_DAX
    scripts/config --enable CONFIG_DEV_DAX_CXL
    # DEV_DAX_KMEM is required for CXL memory to online as NUMA node.
    # Without it trigger_poison_list has no memory range and silently fails.
    scripts/config --enable CONFIG_DEV_DAX_KMEM
    scripts/config --enable CONFIG_DEV_DAX_PMEM
    scripts/config --enable CONFIG_FS_DAX
    scripts/config --enable CONFIG_LIBNVDIMM
    scripts/config --enable CONFIG_BLK_DEV_PMEM

    # Memory hotplug / NUMA
    scripts/config --enable CONFIG_MEMORY_HOTPLUG
    scripts/config --enable CONFIG_MEMORY_HOTREMOVE
    scripts/config --set-val CONFIG_MHP_DEFAULT_ONLINE_TYPE 1
    scripts/config --enable CONFIG_NUMA
    scripts/config --enable CONFIG_ACPI_NUMA
    scripts/config --enable CONFIG_MEMORY_FAILURE

    # RAS and error handling
    scripts/config --enable CONFIG_RAS
    scripts/config --enable CONFIG_PCIEAER
    # Required for CXL-specific AER path (correctable/uncorrectable injection)
    scripts/config --enable CONFIG_PCIEAER_CXL
    scripts/config --enable CONFIG_X86_MCE
    scripts/config --enable CONFIG_X86_MCE_INTEL
    scripts/config --enable CONFIG_ACPI_APEI
    scripts/config --enable CONFIG_ACPI_APEI_GHES
    scripts/config --enable CONFIG_EDAC

    # Tracing (critical for cxl trace events)
    scripts/config --enable CONFIG_TRACING
    scripts/config --enable CONFIG_FTRACE
    scripts/config --enable CONFIG_DYNAMIC_FTRACE
    scripts/config --enable CONFIG_EVENT_TRACING
    scripts/config --enable CONFIG_RING_BUFFER
    scripts/config --enable CONFIG_DYNAMIC_DEBUG
    scripts/config --enable CONFIG_DEBUG_FS

    # Filesystem and virtio
    scripts/config --enable CONFIG_EXT4_FS
    scripts/config --enable CONFIG_VIRTIO_PCI
    scripts/config --enable CONFIG_VIRTIO_BLK
    scripts/config --enable CONFIG_E1000E

    make olddefconfig

    info "Building guest kernel — takes 20-40 minutes..."
    make -j"$(nproc)" 2>&1 | tail -5

    cp arch/x86/boot/bzImage "${CXL_LAB_DIR}/cxl_guest_kernel_lab"
    success "Guest kernel built and saved to ${CXL_LAB_DIR}/cxl_guest_kernel_lab"
}


phase5_ovmf() {
    info "PHASE 5: Setting up OVMF UEFI firmware..."

    mkdir -p "${CXL_DIR}"
    cd "${CXL_DIR}"

    ls /usr/share/OVMF/OVMF_*.fd > /dev/null 2>&1 \
        || die "OVMF firmware files not found. Ensure 'ovmf' package is installed."

    cp /usr/share/OVMF/OVMF_CODE*.fd .
    cp /usr/share/OVMF/OVMF_VARS*.fd .

    mv OVMF_CODE_4M.fd OVMF_CODE.fd 2>/dev/null || true
    mv OVMF_VARS_4M.fd OVMF_VARS.fd 2>/dev/null || true

    success "OVMF firmware ready."
}


phase6_images() {
    info "PHASE 6: Setting up VM disk and CXL backing files..."

    mkdir -p "${CXL_DIR}"
    cd "${CXL_DIR}"

    # Volatile backing files — used by start-cxl.sh for RAS error injection
    if [[ ! -f "cxlmem0.img" ]]; then
        fallocate -l 512M cxlmem0.img
        success "Created cxlmem0.img (volatile, 512MB)"
    fi
    if [[ ! -f "cxlmem1.img" ]]; then
        fallocate -l 512M cxlmem1.img
        success "Created cxlmem1.img (volatile, 512MB)"
    fi

    # Persistent backing files — used by start-cxl-pmem.sh
    if [[ ! -f "cxl-mem0.raw" ]]; then
        dd if=/dev/zero of=cxl-mem0.raw bs=1M count=1024 status=progress
        success "Created cxl-mem0.raw (persistent, 1GB)"
    fi
    if [[ ! -f "cxl-lsa0.raw" ]]; then
        dd if=/dev/zero of=cxl-lsa0.raw bs=1M count=256 status=progress
        success "Created cxl-lsa0.raw (LSA, 256MB)"
    fi
    if [[ ! -f "cxl-vmem0.raw" ]]; then
        dd if=/dev/zero of=cxl-vmem0.raw bs=1M count=512 status=progress
        success "Created cxl-vmem0.raw (volatile ram, 512MB)"
    fi

    chmod 660 "${CXL_DIR}"/cxl-*.raw

    if [[ ! -f "noble-server-cloudimg-amd64.img" ]]; then
        info "Downloading Ubuntu 24.04 cloud image..."
        wget -q --show-progress \
            https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    fi

    qemu-img resize noble-server-cloudimg-amd64.img 20G

    if [[ ! -f "seed.img" ]]; then
        cat > /tmp/user-data << 'CLOUDINIT'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false
ssh_pwauth: true
package_update: true
packages:
  - ndctl
  - pciutils
CLOUDINIT

        cat > /tmp/meta-data << 'METAEOF'
instance-id: cxl-vm-001
local-hostname: ubuntu
METAEOF

        cloud-localds seed.img /tmp/user-data /tmp/meta-data
        success "cloud-init seed created (login: ubuntu / ubuntu)"
    fi

    success "All backing files ready."
}


phase7_launch_scripts() {
    info "PHASE 7: Creating launch scripts..."

    # start-cxl.sh — RAS error injection topology
    cat > "${CXL_DIR}/start-cxl.sh" << 'EOF'
#!/bin/bash

sudo modprobe kvm
sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

/home/user/cxl_lab/qemu/build/qemu-system-x86_64 \
  -machine q35,cxl=on,accel=kvm \
  -cpu host,migratable=off \
  -smp 4 \
  -m 2G,maxmem=8G,slots=4 \
  -kernel /home/user/cxl_lab/cxl_guest_kernel_lab \
  -append "root=/dev/vda1 console=ttyS0 console=tty1" \
  -nographic -serial mon:stdio \
  -D /tmp/qemu.log \
  -d guest_errors,trace:cxl* \
  -object memory-backend-file,id=mem0,mem-path=/home/user/cxl_lab/cxl/cxlmem0.img,size=512M,share=on \
  -object memory-backend-file,id=mem1,mem-path=/home/user/cxl_lab/cxl/cxlmem1.img,size=512M,share=on \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=2 \
  -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=3 \
  -device cxl-type3,bus=rp0,volatile-memdev=mem0,id=cxl0,sn=1 \
  -device cxl-type3,bus=rp1,volatile-memdev=mem1,id=cxl1,sn=2 \
  -drive file=/home/user/cxl_lab/cxl/noble-server-cloudimg-amd64.img,if=none,id=hd0,format=qcow2 \
  -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
  -drive file=/home/user/cxl_lab/cxl/seed.img,if=none,id=seed0,format=raw \
  -device virtio-blk-pci,drive=seed0,bus=pcie.0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0,bus=pcie.0 \
  -qmp tcp:127.0.0.1:4444,server,nowait
EOF
    chmod +x "${CXL_DIR}/start-cxl.sh"
    success "start-cxl.sh created."

    # start-cxl-pmem.sh — Persistent memory topology
    cat > "${CXL_DIR}/start-cxl-pmem.sh" << 'EOF'
#!/bin/bash

sudo modprobe kvm
sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

[[ -e /tmp/qmp-sock ]] && rm -f /tmp/qmp-sock

cd /home/user/cxl_lab/cxl

/home/user/cxl_lab/qemu/build/qemu-system-x86_64 \
  -machine q35,cxl=on,accel=kvm \
  -cpu host,migratable=off \
  -smp 4 \
  -m 8G,maxmem=16G,slots=4 \
  -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
  -kernel /home/user/cxl_lab/cxl_guest_kernel_lab \
  -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0 rw cloud-init=disabled" \
  -drive file=./noble-server-cloudimg-amd64.img,format=qcow2,if=none,id=hd0 \
  -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
  -drive file=./seed.img,if=none,id=seed0,format=raw \
  -device virtio-blk-pci,drive=seed0,bus=pcie.0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0,bus=pcie.0 \
  -nographic \
  -d guest_errors \
  -object memory-backend-file,id=cxl-mem0,share=on,mem-path=./cxl-mem0.raw,size=1G \
  -object memory-backend-file,id=cxl-lsa0,share=on,mem-path=./cxl-lsa0.raw,size=256M \
  -object memory-backend-ram,id=vmem0,size=512M \
  -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
  -device cxl-rp,port=0,bus=cxl.1,id=root_port13,chassis=0,slot=2 \
  -device cxl-type3,bus=root_port13,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxlpmem0,sn=0x1 \
  -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k \
  -qmp unix:/tmp/qmp-sock,server=on,wait=off
EOF
    chmod +x "${CXL_DIR}/start-cxl-pmem.sh"
    success "start-cxl-pmem.sh created."
}

phase8_validate() {
    info "PHASE 8: Validating complete environment..."

    local ok=true

    check() {
        local label="$1"
        local path="$2"
        if [[ -e "${path}" ]]; then
            success "${label}"
        else
            warn "MISSING: ${label} — ${path}"
            ok=false
        fi
    }

    check "QEMU binary"             "${QEMU_DIR}/build/qemu-system-x86_64"
    check "Guest kernel"            "${CXL_LAB_DIR}/cxl_guest_kernel_lab"
    check "OVMF_CODE.fd"            "${CXL_DIR}/OVMF_CODE.fd"
    check "OVMF_VARS.fd"            "${CXL_DIR}/OVMF_VARS.fd"
    check "Guest disk image"        "${CXL_DIR}/noble-server-cloudimg-amd64.img"
    check "cloud-init seed"         "${CXL_DIR}/seed.img"
    check "cxlmem0.img (volatile)"  "${CXL_DIR}/cxlmem0.img"
    check "cxlmem1.img (volatile)"  "${CXL_DIR}/cxlmem1.img"
    check "cxl-mem0.raw (pmem)"     "${CXL_DIR}/cxl-mem0.raw"
    check "cxl-lsa0.raw (lsa)"      "${CXL_DIR}/cxl-lsa0.raw"
    check "cxl-vmem0.raw (vmem)"    "${CXL_DIR}/cxl-vmem0.raw"
    check "start-cxl.sh"            "${CXL_DIR}/start-cxl.sh"
    check "start-cxl-pmem.sh"       "${CXL_DIR}/start-cxl-pmem.sh"

    if [[ "${ok}" == true ]]; then
        success "All pre-flight checks passed."
    else
        warn "Some files are missing. Review warnings above."
    fi
}

# MAIN
main() {
    phase1_dependencies
    phase2_wsl2_kernel
    phase3_qemu
    phase4_guest_kernel
    phase5_ovmf
    phase6_images
    phase7_launch_scripts
    phase8_validate

    echo ""
    echo "  SETUP COMPLETE"
    echo ""
    echo "  For RAS error injection testing:"
    echo "    cd ~/cxl_lab/cxl && ./start-cxl.sh"
    echo ""
    echo "  For persistent memory topology:"
    echo "    cd ~/cxl_lab/cxl && ./start-cxl-pmem.sh"
    echo ""
    echo ""
}

main "$@"
