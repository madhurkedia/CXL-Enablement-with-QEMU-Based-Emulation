#!/usr/bin/env bash
# Description : CXL Emulation - Phase 3 (Dual Switch Topology)

# Host OS     : Ubuntu 24.04.4 LTS
# Guest OS    : Ubuntu 24.04.4 LTS
# QEMU Build  : Custom CXL-enabled QEMU

# Phase 3 extends the previous switch topology by introducing:
#   • Two independent CXL root ports
#   • Two upstream switches
#   • Four Type-3 memory devices

# Topology:
#   pxb-cxl (bus_nr=12)
#     ├─ cxl-rp  (port 0, chassis 0, slot 0)
#     │    └─ cxl-upstream (us0)
#     │         ├─ cxl-downstream (port 0 → ds0a, chassis 1, slot 1)
#     │         │    └─ cxl-type3 (mem0, lsa0, sn=0x10)
#     │         └─ cxl-downstream (port 1 → ds1a, chassis 1, slot 2)
#     │              └─ cxl-type3 (mem1, lsa1, sn=0x11)
#     │
#     └─ cxl-rp  (port 1, chassis 0, slot 1)
#          └─ cxl-upstream (us1)
#               ├─ cxl-downstream (port 0 → ds0b, chassis 2, slot 1)
#               │    └─ cxl-type3 (mem2, lsa2, sn=0x20)
#               └─ cxl-downstream (port 1 → ds1b, chassis 2, slot 2)
#                    └─ cxl-type3 (mem3, lsa3, sn=0x21)

set -euo pipefail

# Global Paths
WORKSPACE="/opt/cxl_workspace"
IMAGES="${WORKSPACE}/images"

QEMU_BIN="${WORKSPACE}/qemu_install/bin/qemu-system-x86_64"

KERNEL="${IMAGES}/bzImage-6.18-cxl"

OVMF_CODE="${IMAGES}/OVMF_CODE.fd"
OVMF_VARS="${IMAGES}/OVMF_VARS.fd"

GUEST_DISK="${IMAGES}/cxl-guest.qcow2"

# Colour Helpers
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Prepare Backing Files
prepare_backing_files_phase3() {
    info "Preparing backing files for Phase 3 dual-switch topology..."

    mkdir -p "${IMAGES}"
    cd "${IMAGES}"

    # Four 512 MiB memory devices
    dd if=/dev/zero of=cxl-mem0.raw bs=1M count=512 status=none
    dd if=/dev/zero of=cxl-mem1.raw bs=1M count=512 status=none
    dd if=/dev/zero of=cxl-mem2.raw bs=1M count=512 status=none
    dd if=/dev/zero of=cxl-mem3.raw bs=1M count=512 status=none

    # Label Storage Areas
    dd if=/dev/zero of=cxl-lsa0.raw bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa1.raw bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa2.raw bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa3.raw bs=1M count=256 status=none

    chmod 660 cxl-*.raw

    success "Phase 3 backing files created."
}

# Run QEMU
run_phase3() {

    info "Launching Phase 3 dual-switch topology..."

    cd "${IMAGES}"

    [ -e /tmp/qmp-sock ] && rm -f /tmp/qmp-sock

    exec "${QEMU_BIN}" \
        -machine q35,cxl=on,accel=kvm \
        -cpu host,migratable=off \
        -smp 4 \
        -m 8G,maxmem=32G,slots=8 \
        \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        \
        -kernel "${KERNEL}" \
        -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0,115200 rw" \
        \
        -drive file="${GUEST_DISK}",format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        \
        -virtfs local,path="${WORKSPACE}/reports",mount_tag=hostshare,security_model=mapped-xattr,id=share \
        \
        -nographic \
        -d guest_errors \
        \
        -object memory-backend-file,id=cxl-mem0,share=on,mem-path="${IMAGES}/cxl-mem0.raw",size=512M \
        -object memory-backend-file,id=cxl-lsa0,share=on,mem-path="${IMAGES}/cxl-lsa0.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem1,share=on,mem-path="${IMAGES}/cxl-mem1.raw",size=512M \
        -object memory-backend-file,id=cxl-lsa1,share=on,mem-path="${IMAGES}/cxl-lsa1.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem2,share=on,mem-path="${IMAGES}/cxl-mem2.raw",size=512M \
        -object memory-backend-file,id=cxl-lsa2,share=on,mem-path="${IMAGES}/cxl-lsa2.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem3,share=on,mem-path="${IMAGES}/cxl-mem3.raw",size=512M \
        -object memory-backend-file,id=cxl-lsa3,share=on,mem-path="${IMAGES}/cxl-lsa3.raw",size=256M \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=0 \
        -device cxl-upstream,bus=rp0,id=us0 \
        \
        -device cxl-downstream,port=0,bus=us0,id=ds0a,chassis=1,slot=1 \
        -device cxl-downstream,port=1,bus=us0,id=ds1a,chassis=1,slot=2 \
        \
        -device cxl-type3,bus=ds0a,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxl-pmem0,sn=0x10 \
        -device cxl-type3,bus=ds1a,persistent-memdev=cxl-mem1,lsa=cxl-lsa1,id=cxl-pmem1,sn=0x11 \
        \
        -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=1 \
        -device cxl-upstream,bus=rp1,id=us1 \
        \
        -device cxl-downstream,port=0,bus=us1,id=ds0b,chassis=2,slot=1 \
        -device cxl-downstream,port=1,bus=us1,id=ds1b,chassis=2,slot=2 \
        \
        -device cxl-type3,bus=ds0b,persistent-memdev=cxl-mem2,lsa=cxl-lsa2,id=cxl-pmem2,sn=0x20 \
        -device cxl-type3,bus=ds1b,persistent-memdev=cxl-mem3,lsa=cxl-lsa3,id=cxl-pmem3,sn=0x21 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=4G,cxl-fmw.0.interleave-granularity=4k
}

# Launch
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    prepare_backing_files_phase3
    run_phase3
fi