#!/usr/bin/env bash
# Description : CXL Emulation - Persistent Memory (Dual Switch — Two Independent Memory Pools)

# Topology:
#   pxb-cxl (bus_nr=12)
#     ├─ cxl-rp  (port 0, chassis 0, slot 0)   ← Switch A
#     │    └─ cxl-upstream (us0)
#     │         ├─ cxl-downstream (ds0a) → cxl-type3 mem0  (sn=0x10)
#     │         └─ cxl-downstream (ds1a) → cxl-type3 mem1  (sn=0x11)
#     │
#     └─ cxl-rp  (port 1, chassis 0, slot 1)   ← Switch B
#          └─ cxl-upstream (us1)
#               ├─ cxl-downstream (ds0b) → cxl-type3 mem2  (sn=0x20)
#               └─ cxl-downstream (ds1b) → cxl-type3 mem3  (sn=0x21)

set -euo pipefail

# Global Paths
CXL_LAB_DIR="${HOME}/cxl_lab2"
IMAGES="${CXL_LAB_DIR}/cxl"
QEMU_BIN="${CXL_LAB_DIR}/qemu/build/qemu-system-x86_64"
KERNEL="${CXL_LAB_DIR}/cxl_guest_kernel_lab"
OVMF_CODE="${IMAGES}/OVMF_CODE.fd"
OVMF_VARS="${IMAGES}/OVMF_VARS.fd"
GUEST_DISK="${IMAGES}/noble-server-cloudimg-amd64.img"
REPORTS_DIR="${CXL_LAB_DIR}/reports"

# Colour Helpers
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Pre-flight Checks
preflight_checks() {
    info "Running pre-flight checks"
    [[ -x "${QEMU_BIN}" ]]   || die "QEMU binary not found at ${QEMU_BIN}."
    [[ -f "${KERNEL}" ]]     || die "Guest kernel not found at ${KERNEL}."
    [[ -f "${OVMF_CODE}" ]]  || die "OVMF_CODE.fd not found at ${OVMF_CODE}."
    [[ -f "${OVMF_VARS}" ]]  || die "OVMF_VARS.fd not found at ${OVMF_VARS}."
    [[ -f "${GUEST_DISK}" ]] || die "Guest disk not found at ${GUEST_DISK}."
    success "Pre-flight checks passed."
}

# Backing File Preparation
# Four 1 GiB memory devices so each ext4 filesystem has comfortable room.
prepare_backing_files() {
    info "Preparing backing files (4 × 1 GiB mem + 4 × 256 MiB lsa)"

    mkdir -p "${IMAGES}" "${REPORTS_DIR}"
    cd "${IMAGES}"

    # Switch A memory devices
    [[ -f cxl-mem0.raw ]] || dd if=/dev/zero of=cxl-mem0.raw bs=1M count=1024 status=progress
    [[ -f cxl-mem1.raw ]] || dd if=/dev/zero of=cxl-mem1.raw bs=1M count=1024 status=progress

    # Switch B memory devices
    [[ -f cxl-mem2.raw ]] || dd if=/dev/zero of=cxl-mem2.raw bs=1M count=1024 status=progress
    [[ -f cxl-mem3.raw ]] || dd if=/dev/zero of=cxl-mem3.raw bs=1M count=1024 status=progress

    # Label Storage Areas (one per device)
    [[ -f cxl-lsa0.raw ]] || dd if=/dev/zero of=cxl-lsa0.raw bs=1M count=256 status=progress
    [[ -f cxl-lsa1.raw ]] || dd if=/dev/zero of=cxl-lsa1.raw bs=1M count=256 status=progress
    [[ -f cxl-lsa2.raw ]] || dd if=/dev/zero of=cxl-lsa2.raw bs=1M count=256 status=progress
    [[ -f cxl-lsa3.raw ]] || dd if=/dev/zero of=cxl-lsa3.raw bs=1M count=256 status=progress

    chmod 660 cxl-mem*.raw cxl-lsa*.raw
    success "Backing files ready in ${IMAGES}."
}

# QEMU Launch 
run() {
    info "Launching — Dual-switch topology (two independent memory pools)"

    cd "${IMAGES}"
    [[ -e /tmp/qmp-sock ]] && rm -f /tmp/qmp-sock

    exec "${QEMU_BIN}" \
        -machine q35,cxl=on,accel=kvm \
        -cpu host,migratable=off,+clflushopt,+clwb \
        -smp 4 \
        -m 8G,maxmem=32G,slots=8 \
        \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        \
        -kernel "${KERNEL}" \
        -append "root=/dev/vda1 rootwait rootdelay=5 \
        console=ttyS0,115200 earlyprintk=ttyS0 rw \
        clearcpuid=clflushopt,clwb" \
        \
        -drive file="${GUEST_DISK}",format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        \
        -virtfs local,path="${REPORTS_DIR}",mount_tag=hostshare,security_model=mapped-xattr,id=share \
        \
        -nographic \
        -d guest_errors \
        \
        -object memory-backend-file,id=cxl-mem0,share=on,mem-path="${IMAGES}/cxl-mem0.raw",size=1G \
        -object memory-backend-file,id=cxl-lsa0,share=on,mem-path="${IMAGES}/cxl-lsa0.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem1,share=on,mem-path="${IMAGES}/cxl-mem1.raw",size=1G \
        -object memory-backend-file,id=cxl-lsa1,share=on,mem-path="${IMAGES}/cxl-lsa1.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem2,share=on,mem-path="${IMAGES}/cxl-mem2.raw",size=1G \
        -object memory-backend-file,id=cxl-lsa2,share=on,mem-path="${IMAGES}/cxl-lsa2.raw",size=256M \
        \
        -object memory-backend-file,id=cxl-mem3,share=on,mem-path="${IMAGES}/cxl-mem3.raw",size=1G \
        -object memory-backend-file,id=cxl-lsa3,share=on,mem-path="${IMAGES}/cxl-lsa3.raw",size=256M \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=0 \
        -device cxl-upstream,bus=rp0,id=us0 \
        -device cxl-downstream,port=0,bus=us0,id=ds0a,chassis=1,slot=1 \
        -device cxl-downstream,port=1,bus=us0,id=ds1a,chassis=1,slot=2 \
        -device cxl-type3,bus=ds0a,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxl-pmem0,sn=0x10 \
        -device cxl-type3,bus=ds1a,persistent-memdev=cxl-mem1,lsa=cxl-lsa1,id=cxl-pmem1,sn=0x11 \
        \
        -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=1 \
        -device cxl-upstream,bus=rp1,id=us1 \
        -device cxl-downstream,port=0,bus=us1,id=ds0b,chassis=2,slot=1 \
        -device cxl-downstream,port=1,bus=us1,id=ds1b,chassis=2,slot=2 \
        -device cxl-type3,bus=ds0b,persistent-memdev=cxl-mem2,lsa=cxl-lsa2,id=cxl-pmem2,sn=0x20 \
        -device cxl-type3,bus=ds1b,persistent-memdev=cxl-mem3,lsa=cxl-lsa3,id=cxl-pmem3,sn=0x21 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=16G,cxl-fmw.0.interleave-granularity=4k \
        \
        -qmp unix:/tmp/qmp-sock,server=on,wait=off
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    preflight_checks
    prepare_backing_files
    run
fi