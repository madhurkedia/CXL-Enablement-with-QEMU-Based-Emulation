# Description : Read-only verification of CXL topology, kernel, and hardware

set -euo pipefail

# Colour helpers
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

guest_mount_hostshare() {
    info "Mounting VirtFS host-share inside guest..."
    mkdir -p /mnt/hostshare
    mount -t 9p -o trans=virtio hostshare /mnt/hostshare || warn "Hostshare not available, continuing locally."
}

guest_verify_kernel() {
    info "Verifying guest kernel version..."
    uname -r
}

guest_enumerate_cxl_topology() {
    info "--- CXL FULL TOPOLOGY (Bus + Memdev + Port + Decoder) ---"
    cxl list -BMPD
    info "--- CXL MEMDEVS ---"; cxl list -M
    info "--- CXL BUSES ---"; cxl list -B
    info "--- CXL PORTS ---"; cxl list -P
    info "--- CXL DECODERS ---"; cxl list -D
    info "--- CXL REGIONS ---"; cxl list -R
}

guest_verify_pci_topology() {
    info "--- PCIe device tree ---"
    lspci -tv
    info "--- CXL PCI capabilities (verbose) ---"
    lspci -vvv | grep -i cxl || true
}

guest_verify_cxl_kernel_modules() {
    info "--- Loaded CXL kernel modules ---"
    lsmod | grep -E '^cxl' || true
    info "--- Module details ---"
    for mod in cxl_core cxl_pci cxl_mem cxl_pmem cxl_port; do
        if lsmod | grep -q "$mod"; then
            echo ">> ${mod}:"
            modinfo "${mod}" 2>/dev/null | grep -E 'description|parm' || true
        fi
    done
}

guest_verify_sysfs_cxl_tree() {
    info "--- sysfs CXL device tree ---"
    ls -la /sys/bus/cxl/devices/ || true
    info "--- CXL iomem window ---"
    grep -i cxl /proc/iomem || true
}

guest_numa_topology() {
    info "=== NUMA topology ==="
    numactl --hardware || warn "numactl not installed"
}

guest_dmesg_cxl() {
    info "=== Key CXL dmesg entries ==="
    dmesg | grep -iE 'cxl|acpi0016|_osc|pci0000:0c|pmem|nvdimm|linear.cache|MCE' | head -80 || true
}

guest_meminfo() {
    info "=== Guest /proc/meminfo (CXL-relevant entries) ==="
    grep -E 'MemTotal|MemFree|MemAvailable|HugePages|Hugepagesize' /proc/meminfo
}

guest_write_capture_script() {
    info "Writing proof-capture script to /root/cxl_capture.sh ..."
    cat > /root/cxl_capture.sh << 'CAPTURE_EOF'
#!/usr/bin/env bash
REPORT="/root/cxl_proof_$(date +%Y%m%d_%H%M%S).txt"
{
    echo "=============================="
    echo "CXL EMULATION PROOF REPORT"
    echo "Date: $(date)"
    echo "=============================="
    echo -e "\n--- KERNEL ---" && uname -a
    echo -e "\n--- CXL FULL TOPOLOGY ---" && cxl list -BMPD
    echo -e "\n--- PCIe DEVICE TREE ---" && lspci -tv
    echo -e "\n--- sysfs CXL DEVICES ---" && ls -la /sys/bus/cxl/devices/
    echo -e "\n--- NUMA TOPOLOGY ---" && numactl --hardware
    echo -e "\n--- KEY DMESG (CXL) ---" && dmesg | grep -iE 'cxl|acpi0016|pmem'
} > "${REPORT}"
echo "Report saved to: ${REPORT}"
CAPTURE_EOF
    chmod +x /root/cxl_capture.sh
    success "Capture script written."
}

# Main Execution Controller

info "Starting Read-Only CXL Verification..."

guest_mount_hostshare
guest_verify_kernel
guest_enumerate_cxl_topology
guest_verify_pci_topology
guest_verify_cxl_kernel_modules
guest_verify_sysfs_cxl_tree
guest_numa_topology
guest_dmesg_cxl
guest_meminfo
guest_write_capture_script

info "Running final proof capture..."
/root/cxl_capture.sh

success "Verification and proof capture complete."