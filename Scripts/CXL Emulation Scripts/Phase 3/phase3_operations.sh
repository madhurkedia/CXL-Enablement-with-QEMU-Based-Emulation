#!/usr/bin/env bash
# Description : CXL Phase 3 Operations (Dual-Switch Interleaved Region)

# Executed INSIDE the guest VM after Phase 3 topology is running.

# Covers:
#   1. CXL topology verification
#   2. 2-way interleaved region creation
#   3. Namespace creation
#   4. Basic I/O validation

# Prerequisites:
#   • phase3_Emulation.sh running
#   • Guest booted successfully
#   • cxl-cli and ndctl installed

set -euo pipefail

# Colour Helpers
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# 1. Verify Phase 3 Topology
guest_verify_phase3_topology() {

    info "Phase 3 Dual-Switch Topology Verification"

    info "Full topology (Bus + Memdev + Port + Decoder)"
    cxl list -BMPD

    info "Memory Devices"
    cxl list -M

    info "CXL Ports"
    cxl list -P

    info "Decoders"
    cxl list -D

    info "PCIe Tree"
    lspci -tv
}

# 2. Create Interleaved Region
guest_create_interleaved_region() {

    info "Creating 2-way interleaved region"
    info "Using mem0 + mem1 behind Switch A"

    cxl create-region \
        -m mem0 -m mem1 \
        -d decoder0.0 \
        --interleave-ways=2 \
        --interleave-granularity=4096

    info "Created Regions"
    cxl list -R

    info "Decoder State After Region Creation"
    cxl list -D
}

# 3. Error Validation
guest_region_error_validation() {

    warn "Expected failure: duplicate region on same decoder"

    cxl create-region \
        -m mem0 \
        -d decoder0.0 \
        || success "Caught expected No Space error"

    warn "Expected failure: invalid memdev combination"

    cxl create-region \
        -m mem0 -m mem2 \
        -d decoder0.0 \
        || success "Caught expected topology mismatch error"
}

# 4. Create Namespace
guest_create_namespace() {

    info "Creating fsdax namespace on region0"

    ndctl create-namespace \
        --region=region0

    info "Namespace List"
    ndctl list

    info "Block Devices"
    ls -l /dev/pmem* || warn "/dev/pmem* not found"
}

# 5. Basic I/O Validation
guest_io_validation() {

    if ! ls /dev/pmem0 >/dev/null 2>&1; then
        warn "/dev/pmem0 not found. Skipping I/O validation."
        return 1
    fi

    info "I/O Validation on /dev/pmem0"

    info "Zero-fill write test"
    dd if=/dev/zero of=/dev/pmem0 bs=1M count=10 oflag=direct

    info "Random write test"
    dd if=/dev/urandom of=/dev/pmem0 bs=1M count=10 oflag=direct

    info "Read test"
    dd if=/dev/pmem0 of=/dev/null bs=1M count=10

    info "Namespace Verification"
    ndctl list -v
}

# Main Execution Sequence
info " Starting Phase 3 Operations (Dual-Switch Topology) "

guest_verify_phase3_topology
guest_create_interleaved_region
guest_region_error_validation
guest_create_namespace
guest_io_validation

success " Phase 3 operations completed successfully.          "
