# Description : CXL Emulation - Phase 1 (Basic Single-Device Topology)

# Host OS     : Ubuntu 24.04.4 LTS
# Guest OS    : Ubuntu 24.04.4 LTS (GNU/Linux 6.18.0 x86_64)
# QEMU Build  : Custom — /opt/cxl_workspace/qemu_install/bin/qemu-system-x86_64
# CXL Tooling : cxl-cli (ndctl suite), ndctl, lspci

set -euo pipefail

# Global paths 
WORKSPACE="/opt/cxl_workspace"
IMAGES="${WORKSPACE}/images"
QEMU_BIN="${WORKSPACE}/qemu_install/bin/qemu-system-x86_64"
KERNEL="${IMAGES}/bzImage-6.18-cxl"
OVMF_CODE="${IMAGES}/OVMF_CODE.fd"
OVMF_VARS="${IMAGES}/OVMF_VARS.fd"
GUEST_DISK="${IMAGES}/cxl-guest.qcow2"

# Colour helpers
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Creates the raw memory-backend files required by both emulation phases.
# Must be executed on the HOST before launching QEMU.
prepare_backing_files_basic() {
    info "Preparing backing files for Phase 1 (basic single-device topology)..."
    mkdir -p "${IMAGES}"
    cd "${IMAGES}"

    dd if=/dev/zero of=cxl-mem0.raw  bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-lsa0.raw  bs=1M count=256 status=none

    chmod 660 cxl-*.raw
    success "Basic backing files created."
}


# Topology:
#   pxb-cxl (bus_nr=12)
#     └─ cxl-rp  (port 0, chassis 0, slot 0)
#          └─ cxl-upstream (us0)
#               └─ cxl-downstream (port 0, chassis 0, slot 0)
#                    └─ cxl-type3 (mem0, lsa0, sn=0x1)
run_phase1_basic() {
    info "Launching Phase 1 — Basic CXL single-device emulation..."
    cd "${IMAGES}"

    [ -e /tmp/qmp-sock ] && rm -f /tmp/qmp-sock

    exec "${QEMU_BIN}" \
        -machine q35,cxl=on,accel=kvm \
        -cpu host,migratable=off \
        -smp 4 \
        -m 8G,maxmem=16G,slots=4 \
        \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        \
        -kernel "${KERNEL}" \
        -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0,115200 earlyprintk=ttyS0 rw" \
        \
        -drive file="${GUEST_DISK}",format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        \
        -nographic \
        -d guest_errors \
        \
        -object memory-backend-file,id=cxl-mem0,share=on,mem-path="${IMAGES}/cxl-mem0.raw",size=1G \
        -object memory-backend-file,id=cxl-lsa0,share=on,mem-path="${IMAGES}/cxl-lsa0.raw",size=256M \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=0 \
        -device cxl-upstream,bus=rp0,id=us0 \
        -device cxl-downstream,port=0,bus=us0,id=ds0,chassis=0,slot=1 \
        -device cxl-type3,bus=ds0,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxl-pmem0,sn=0x1 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=8G,cxl-fmw.0.interleave-granularity=4k
}

# Launch Qemu
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    prepare_backing_files_basic
    run_phase1_basic
fi
