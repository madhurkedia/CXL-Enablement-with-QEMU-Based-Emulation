# Description : CXL Emulation - Phase 2 (Advanced Switch Topology)

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
prepare_backing_files_advanced() {
    info "Preparing backing files for Phase 2 (advanced switch topology)..."
    mkdir -p "${IMAGES}"
    cd "${IMAGES}"

    dd if=/dev/zero of=cxl-mem0.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-mem1.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-mem2.raw  bs=1M count=512 status=none

    dd if=/dev/zero of=cxl-lsa0.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa1.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa2.raw  bs=1M count=256 status=none

    chmod 660 cxl-*.raw
    success "Advanced backing files created."
}

prepare_backing_files_expanded() {
    info "Preparing expanded backing files (1 GiB / 1 GiB / 512 MiB)..."
    mkdir -p "${IMAGES}"
    cd "${IMAGES}"

    dd if=/dev/zero of=cxl-mem0.raw  bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-mem1.raw  bs=1M count=1024 status=none
    dd if=/dev/zero of=cxl-mem2.raw  bs=1M count=512  status=none

    dd if=/dev/zero of=cxl-lsa0.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa1.raw  bs=1M count=256 status=none
    dd if=/dev/zero of=cxl-lsa2.raw  bs=1M count=256 status=none

    chmod 660 cxl-*.raw
    success "Expanded backing files created."
}

# Topology:
#   pxb-cxl (bus_nr=12)
#     └─ cxl-rp  (port 0, chassis 0, slot 0)
#          └─ cxl-upstream (us0)
#               ├─ cxl-downstream (port 0 → ds0, chassis 1, slot 1)
#               │    └─ cxl-type3 (mem0, lsa0, sn=0x1)
#               ├─ cxl-downstream (port 1 → ds1, chassis 2, slot 2)
#               │    └─ cxl-type3 (mem1, lsa1, sn=0x2)
#               └─ cxl-downstream (port 2 → ds2, chassis 3, slot 3)
#                    └─ cxl-type3 (mem2, lsa2, sn=0x3)
run_phase2() {
    local memory_config="${1:-basic}"
    
    cd "${IMAGES}"
    [ -e /tmp/qmp-sock ] && rm -f /tmp/qmp-sock

    local m0_size="256M" m1_size="256M" m2_size="512M" fmw_size="8G"
    
    if [[ "${memory_config}" == "expanded" ]]; then
        info "Launching Phase 2 (expanded) — 1 GiB + 1 GiB + 512 MiB endpoints..."
        m0_size="1024M"
        m1_size="1024M"
        m2_size="512M"
        fmw_size="2G"
    else
        info "Launching Phase 2 — Advanced CXL switch topology (3 endpoints)..."
    fi

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
        -append "root=/dev/vda1 rootwait rootdelay=5 console=ttyS0,115200 earlyprintk=ttyS0 rw" \
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
        -object memory-backend-file,id=cxl-mem0,share=on,mem-path="${IMAGES}/cxl-mem0.raw",size=${m0_size} \
        -object memory-backend-file,id=cxl-lsa0,share=on,mem-path="${IMAGES}/cxl-lsa0.raw",size=256M \
        -object memory-backend-file,id=cxl-mem1,share=on,mem-path="${IMAGES}/cxl-mem1.raw",size=${m1_size} \
        -object memory-backend-file,id=cxl-lsa1,share=on,mem-path="${IMAGES}/cxl-lsa1.raw",size=256M \
        -object memory-backend-file,id=cxl-mem2,share=on,mem-path="${IMAGES}/cxl-mem2.raw",size=${m2_size} \
        -object memory-backend-file,id=cxl-lsa2,share=on,mem-path="${IMAGES}/cxl-lsa2.raw",size=256M \
        \
        -device pxb-cxl,bus_nr=12,bus=pcie.0,id=cxl.1 \
        -device cxl-rp,port=0,bus=cxl.1,id=rp0,chassis=0,slot=0 \
        -device cxl-upstream,bus=rp0,id=us0 \
        -device cxl-downstream,port=0,bus=us0,id=ds0,chassis=1,slot=1 \
        -device cxl-downstream,port=1,bus=us0,id=ds1,chassis=2,slot=2 \
        -device cxl-downstream,port=2,bus=us0,id=ds2,chassis=3,slot=3 \
        -device cxl-type3,bus=ds0,persistent-memdev=cxl-mem0,lsa=cxl-lsa0,id=cxl-pmem0,sn=0x1 \
        -device cxl-type3,bus=ds1,persistent-memdev=cxl-mem1,lsa=cxl-lsa1,id=cxl-pmem1,sn=0x2 \
        -device cxl-type3,bus=ds2,persistent-memdev=cxl-mem2,lsa=cxl-lsa2,id=cxl-pmem2,sn=0x3 \
        \
        -M cxl-fmw.0.targets.0=cxl.1,cxl-fmw.0.size=${fmw_size},cxl-fmw.0.interleave-granularity=4k
}

# Launch Qemu
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "expanded" ]]; then
        prepare_backing_files_expanded
        run_phase2 "expanded"
    else
        prepare_backing_files_advanced
        run_phase2 "basic"
    fi
fi