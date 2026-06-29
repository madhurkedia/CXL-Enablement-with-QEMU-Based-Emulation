#!/usr/bin/env bash
# Description : CXL Volatile Emulation 

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
GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Backing File Preparation 
prepare_backing_files_volatile() {
    info "Preparing volatile backing files (4 × 1 GiB)..."

    mkdir -p "${IMAGES}" "${REPORTS_DIR}"
    cd "${IMAGES}"

    # Create empty files to allocate raw host memory backing blocks for QEMU
    dd if=/dev/zero of=cxl-volatile-mem0.raw bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-volatile-mem1.raw bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-volatile-mem2.raw bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-volatile-mem3.raw bs=1M count=1024 status=none

    chmod 660 cxl-volatile-*.raw
    success "Volatile backing files created."
}

# QEMU Launch
run_volatile() {
    info "Launching — Volatile Memory Expansion Mode (1GB Motherboard RAM Baseline)"

    cd "${IMAGES}"
    [ -e /tmp/qmp-sock ] && rm -f /tmp/qmp-sock

    exec "${QEMU_BIN}" \
        -machine q35,cxl=on,accel=kvm \
        -cpu host,migratable=off \
        -smp 4 \
        -m 1G,maxmem=16G,slots=8 \
        -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
        -drive if=pflash,format=raw,file="${OVMF_VARS}" \
        -kernel "${KERNEL}" \
        -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0,115200 earlyprintk=ttyS0 rw" \
        -drive file="${GUEST_DISK}",format=qcow2,if=none,id=hd0 \
        -device virtio-blk-pci,drive=hd0,bus=pcie.0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0,bus=pcie.0 \
        -virtfs local,path="${REPORTS_DIR}",mount_tag=hostshare,security_model=mapped-xattr,id=share \
        -nographic \
        -d guest_errors \
        \
        -object memory-backend-file,id=vmem0,share=on,mem-path="${IMAGES}/cxl-volatile-mem0.raw",size=1G \
        -object memory-backend-file,id=vmem1,share=on,mem-path="${IMAGES}/cxl-volatile-mem1.raw",size=1G \
        -object memory-backend-file,id=vmem2,share=on,mem-path="${IMAGES}/cxl-volatile-mem2.raw",size=1G \
        -object memory-backend-file,id=vmem3,share=on,mem-path="${IMAGES}/cxl-volatile-mem3.raw",size=1G \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=0 \
        -device cxl-upstream,bus=rp0,id=us0 \
        -device cxl-downstream,port=0,bus=us0,id=ds0a,chassis=1,slot=1 \
        -device cxl-downstream,port=1,bus=us0,id=ds1a,chassis=1,slot=2 \
        -device cxl-type3,bus=ds0a,volatile-memdev=vmem0,id=cxl-dev0,sn=0x10 \
        -device cxl-type3,bus=ds1a,volatile-memdev=vmem1,id=cxl-dev1,sn=0x11 \
        \
        -device cxl-rp,port=1,bus=cxl.1,id=rp1,chassis=0,slot=1 \
        -device cxl-upstream,bus=rp1,id=us1 \
        -device cxl-downstream,port=0,bus=us1,id=ds0b,chassis=2,slot=1 \
        -device cxl-downstream,port=1,bus=us1,id=ds1b,chassis=2,slot=2 \
        -device cxl-type3,bus=ds0b,volatile-memdev=vmem2,id=cxl-dev2,sn=0x20 \
        -device cxl-type3,bus=ds1b,volatile-memdev=vmem3,id=cxl-dev3,sn=0x21 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=8G,cxl-fmw.0.interleave-granularity=4k
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    prepare_backing_files_volatile
    run_volatile
fi