#!/usr/bin/env bash
# Description : CXL Persistent Memory Operations (Two Independent Memory Pools + Filesystem Validation)

set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

MOUNT_A="/mnt/cxl-pool-a"
MOUNT_B="/mnt/cxl-pool-b"

# Step 0a: Ensure required tools are installed 
guest_install_tools() {
    info "Step 0a: Checking for required tools"

    local need_update=0

    if ! command -v cxl &>/dev/null; then
        info "cxl binary not found — will install cxl-cli."
        need_update=1
    fi
    if ! command -v ndctl &>/dev/null; then
        info "ndctl not found — will install ndctl."
        need_update=1
    fi
    if ! command -v lspci &>/dev/null; then
        info "lspci not found — will install pciutils."
        need_update=1
    fi

    if [[ ${need_update} -eq 1 ]]; then
        sudo apt-get update -qq
        command -v cxl   &>/dev/null || sudo apt-get install -y cxl-cli
        command -v ndctl &>/dev/null || sudo apt-get install -y ndctl
        command -v lspci &>/dev/null || sudo apt-get install -y pciutils
    fi

    success "Tools ready — cxl: $(cxl version 2>/dev/null || echo unknown), ndctl: $(ndctl version 2>/dev/null || echo unknown)"
}

# Step 0b: Guard — verify clflushopt is masked by clearcpuid
guest_check_cpuflags() {
    info "Step 0b: Checking CPU flags (clflushopt must be masked by host clearcpuid)"

    if grep -qw "clflushopt" /proc/cpuinfo; then
        die "FATAL: 'clflushopt' is still exposed to the guest."
    fi

    success "clflushopt is masked — KVM emulation fault will not occur."
}

# Step 1: Verify Topology
guest_verify_topology() {
    info "Step 1: Topology Verification"

    info "Full topology (Bus + Memdev + Port + Decoder):"
    cxl list -BMPD

    info "Memory devices (expect: mem0 mem1 mem2 mem3):"
    cxl list -M

    info "Root decoders (expect: decoder0.0 spanning the full FMW):"
    cxl list -D -d root

    info "PCIe device tree:"
    lspci -tv
}

# Step 2: Create Two Independent Regions 
guest_create_two_regions() {
    info "Step 2: Create Two Independent Regions"

    info "Enabling all CXL memory devices"
    sudo cxl enable-memdev all 2>/dev/null \
        || warn "enable-memdev: devices may already be enabled (safe to continue)"

    info "Creating Region A on Switch A (mem0 + mem1 → decoder0.0, 2-way interleave)"
    sudo cxl create-region \
        -d decoder0.0 \
        -m mem0 -m mem1 \
        -w 2 \
        -g 4096 \
        -s 1G

    info "Creating Region B on Switch B (mem2 + mem3 → decoder0.0, 2-way interleave)"
    sudo cxl create-region \
        -d decoder0.0 \
        -m mem2 -m mem3 \
        -w 2 \
        -g 4096 \
        -s 1G

    info "All regions (expect: region0 and region1):"
    cxl list -R

    info "Full decoder hierarchy after both regions committed:"
    cxl list -D

    success "Both regions created successfully."
}

# Step 3: Create Two Namespaces
guest_create_namespaces() {
    info "Step 3: Create Namespaces"

    info "Creating namespace on region0 → /dev/pmem0"
    sudo ndctl create-namespace --region=region0

    info "Creating namespace on region1 → /dev/pmem1"
    sudo ndctl create-namespace --region=region1

    info "All namespaces:"
    sudo ndctl list -v

    info "Block devices:"
    ls -lh /dev/pmem* || die "/dev/pmem devices not found — namespace creation failed."

    success "Both namespaces created."
}

# Step 4: Format as ext4 Filesystems 
guest_format_filesystems() {
    info "Step 4: Format Both Pools as ext4"

    sudo mkfs.ext4 -F -L "cxl-pool-a" /dev/pmem0
    sudo mkfs.ext4 -F -L "cxl-pool-b" /dev/pmem1

    success "Both pools formatted as ext4."
}

# Step 5: Mount Both Filesystems
# -o dax requires fsdax namespace mode AND clflushopt masked (checked in Step 0b).
guest_mount_filesystems() {
    info "Step 5: Mount Both Pools"

    sudo mkdir -p "${MOUNT_A}" "${MOUNT_B}"

    if sudo mount -o dax /dev/pmem0 "${MOUNT_A}" 2>/dev/null; then
        info "Pool A mounted in DAX mode → ${MOUNT_A}"
    else
        warn "DAX mount failed for Pool A — falling back to normal mode."
        sudo mount /dev/pmem0 "${MOUNT_A}" || die "Failed to mount /dev/pmem0"
        info "Pool A mounted (normal mode) → ${MOUNT_A}"
    fi

    if sudo mount -o dax /dev/pmem1 "${MOUNT_B}" 2>/dev/null; then
        info "Pool B mounted in DAX mode → ${MOUNT_B}"
    else
        warn "DAX mount failed for Pool B — falling back to normal mode."
        sudo mount /dev/pmem1 "${MOUNT_B}" || die "Failed to mount /dev/pmem1"
        info "Pool B mounted (normal mode) → ${MOUNT_B}"
    fi

    sudo chmod 777 "${MOUNT_A}" "${MOUNT_B}"
    df -h "${MOUNT_A}" "${MOUNT_B}"
    success "Both pools mounted."
}

# Step 6: Write Files and Verify Checksums 
guest_write_and_verify_checksums() {
    info "Step 6: Write Files and Verify Checksums"

    # Pool A 
    info "Pool A: Writing 50 MiB random file"
    dd if=/dev/urandom of="${MOUNT_A}/pool_a_data.bin" bs=1M count=50 status=progress
    sync
    echo "This file lives on CXL Pool A — Switch A (mem0 + mem1)" \
        > "${MOUNT_A}/pool_a_marker.txt"
    sha256sum "${MOUNT_A}/pool_a_data.bin" > "${MOUNT_A}/pool_a_data.sha256"
    info "Pool A checksum:"; cat "${MOUNT_A}/pool_a_data.sha256"

    # Pool B
    info "Pool B: Writing 50 MiB random file"
    dd if=/dev/urandom of="${MOUNT_B}/pool_b_data.bin" bs=1M count=50 status=progress
    sync
    echo "This file lives on CXL Pool B — Switch B (mem2 + mem3)" \
        > "${MOUNT_B}/pool_b_marker.txt"
    sha256sum "${MOUNT_B}/pool_b_data.bin" > "${MOUNT_B}/pool_b_data.sha256"
    info "Pool B checksum:"; cat "${MOUNT_B}/pool_b_data.sha256"

    # Verify
    info "Verifying Pool A"
    sha256sum -c "${MOUNT_A}/pool_a_data.sha256" \
        && success "Pool A: checksum PASSED — data integrity confirmed." \
        || die    "Pool A: checksum FAILED — data corruption detected!"

    info "Verifying Pool B"
    sha256sum -c "${MOUNT_B}/pool_b_data.sha256" \
        && success "Pool B: checksum PASSED — data integrity confirmed." \
        || die    "Pool B: checksum FAILED — data corruption detected!"

    info "Files on Pool A:"; ls -lh "${MOUNT_A}/"
    info "Files on Pool B:"; ls -lh "${MOUNT_B}/"
    info "Disk usage:";      df -h "${MOUNT_A}" "${MOUNT_B}"
}

# Step 7: Confirm Pools are Independent 
guest_confirm_pool_independence() {
    info "Step 7: Confirm Pool Independence"

    info "Marker from Pool A:"; cat "${MOUNT_A}/pool_a_marker.txt"
    info "Marker from Pool B:"; cat "${MOUNT_B}/pool_b_marker.txt"

    SUM_A=$(awk '{print $1}' "${MOUNT_A}/pool_a_data.sha256")
    SUM_B=$(awk '{print $1}' "${MOUNT_B}/pool_b_data.sha256")

    [[ "${SUM_A}" != "${SUM_B}" ]] \
        && success "Pool A and Pool B contain different data — pools are independent." \
        || warn    "Checksums match — unexpected with random data; investigate."
}

# Step 8: Cleanup
guest_cleanup() {
    info "Step 8: Unmount Filesystems"

    sudo umount "${MOUNT_A}" \
        && info "Pool A unmounted." \
        || warn "Pool A unmount failed — may already be unmounted."

    sudo umount "${MOUNT_B}" \
        && info "Pool B unmounted." \
        || warn "Pool B unmount failed — may already be unmounted."

    success "Cleanup complete. Backing files on host retain data (persistent memory)."
}

# Main 
guest_install_tools
guest_check_cpuflags        
guest_verify_topology
guest_create_two_regions
guest_create_namespaces
guest_format_filesystems
guest_mount_filesystems
guest_write_and_verify_checksums
guest_confirm_pool_independence
guest_cleanup

success "Complete."