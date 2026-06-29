#!/usr/bin/env bash
# Description : CXL Volatile Operations (1.5GB Over-Allocation Spillover Proof Test)

set -euo pipefail

# Colour Helpers
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Step 1: Verify Hardware Discovery
guest_verify_topology() {
    info "==> Step 1: Topology Verification"
    cxl list -BMPD
    cxl list -M
    cxl list -D
}

# Step 2: Create Contiguous Hardware Regions
guest_create_two_regions() {
    info "Step 2: Tearing down old mappings and provisioning regions"

    sudo cxl disable-region all 2>/dev/null || true
    sudo cxl destroy-region all 2>/dev/null || true
    sleep 2

    info "Programming Contiguous Regions (1-way) to bypass KVM MMIO limitations"

    # We use -w 1 (no interleave) to allow KVM to map direct memory slots.
    # This prevents the KVM Suberror 3 crash when the kernel zeroes the memory.
    sudo cxl create-region -t ram -m mem0 -d decoder0.0 -w 1 -s 1G
    sleep 1
    sudo cxl create-region -t ram -m mem1 -d decoder0.0 -w 1 -s 1G
    sleep 1
    sudo cxl create-region -t ram -m mem2 -d decoder0.0 -w 1 -s 1G
    sleep 1
    sudo cxl create-region -t ram -m mem3 -d decoder0.0 -w 1 -s 1G

    success "Hardware volatile regions provisioned contiguously."
}

# Step 3: Online the Memory Blocks
guest_online_memory() {
    info "==> Step 3: Onlining Memory via sysfs"

    info "Baseline System RAM allocation scale before onlining:"
    free -h

    info "Activating all offline volatile memory extensions natively"

    for mem in /sys/devices/system/memory/memory*/state; do
        if grep -q "offline" "$mem" 2>/dev/null; then
            echo online | sudo tee "$mem" >/dev/null
        fi
    done

    info "Updated global System RAM allocation scale:"
    free -h
}

# Step 4: Map and Verify NUMA Node Topologies
guest_verify_numa_topology() {
    info "==> Step 4: Checking NUMA Hardware Layout Maps"

    if ! command -v numactl &>/dev/null; then
        warn "numactl tool missing. Installing"
        sudo apt-get update
        sudo apt-get install -y numactl
    fi

    info "Displaying logical memory node pools:"
    numactl --hardware
}

# Step 5: 1.5GB Over-Allocation Spillover Test
guest_run_volatile_spillover_test() {
    info "Step 5: Executing 1.5GB Over-Allocation Spillover Verification"

    if ! command -v stress-ng &>/dev/null; then
        warn "stress-ng missing. Installing"
        sudo apt-get update
        sudo apt-get install -y stress-ng
    fi

    info "Temporarily disabling kernel overcommit limits"
    sudo sysctl -w vm.overcommit_memory=1

    info "TEST PRINCIPLE: Base RAM is 1GB. We are requesting 1.5GB."
    info "If CXL volatile memory is failing, this step will OOM/crash."
    info "If CXL is working, memory spills over into CXL RAM."

    sudo stress-ng \
        --vm 1 \
        --vm-bytes 1500m \
        --timeout 20s \
        --metrics-brief

    info "Restoring kernel overcommit policy"
    sudo sysctl -w vm.overcommit_memory=0

    success "Spillover test completed successfully."
}

# Step 6: Summary
guest_volatile_cleanup() {
    info "Step 6: Final Memory State"
    free -h
    numactl --hardware 2>/dev/null || true
}

# Execution Flow
info "Starting CXL Volatile System-RAM Verification Suite"

guest_verify_topology
guest_create_two_regions
guest_online_memory
guest_verify_numa_topology
guest_run_volatile_spillover_test
guest_volatile_cleanup

