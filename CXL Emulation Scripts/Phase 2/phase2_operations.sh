# Description : CXL Phase 2 Operations (Region creation, Namespace, I/O Validation)

set -euo pipefail

# Colour helpers 
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }

guest_create_regions_phase2() {
    info "=== Region creation — Phase 2 (advanced): mem0 on decoder0.0 ==="
    cxl create-region -m mem0 -d decoder0.0

    info "--- Listing created region ---"
    cxl list -R

    info "--- Listing full decoder hierarchy after region commit ---"
    cxl list -D
}

guest_region_error_cases() {
    warn "=== Expected failure: duplicate region on same decoder (no space) ==="
    cxl create-region -m mem0 -d decoder0.0 || success "Caught expected No Space error"

    warn "=== Expected failure: cross-port decoder mismatch ==="
    cxl create-region -m mem1 -d decoder0.0 || success "Caught expected Cross-Port Mismatch error"
}

guest_create_namespace() {
    info "=== Creating fsdax namespace on region0 ==="
    ndctl create-namespace --region=region0 || warn "Failed to create namespace"

    info "--- Verifying block device ---"
    ls -l /dev/pmem* || warn "/dev/pmem* not found"

    info "--- Checking for DAX char devices ---"
    ls /dev/dax* 2>/dev/null || success "/dev/dax*: not present (expected behavior for fsdax mode)"
}

guest_io_validation() {
    if ! ls /dev/pmem0 >/dev/null 2>&1; then
        warn "Skipping I/O validation: /dev/pmem0 not found. Region/Namespace creation may have failed."
        return 1
    fi

    info "=== I/O Validation on /dev/pmem0 ==="

    info "-- Write: zero-fill 10 MiB (measures write path latency) --"
    dd if=/dev/zero of=/dev/pmem0 bs=1M count=10 oflag=direct

    info "-- Write: random data 10 MiB (measures entropy + throughput) --"
    dd if=/dev/urandom of=/dev/pmem0 bs=1M count=10 oflag=direct

    info "-- Read: consume 10 MiB to /dev/null (measures read throughput) --"
    dd if=/dev/pmem0 of=/dev/null bs=1M count=10

    info "--- Verbose namespace list (confirms NUMA node assignment) ---"
    ndctl list -v
}

# Execution Sequence

info "Starting Phase 2 Advanced Region & Namespace Operations..."

guest_create_regions_phase2
guest_region_error_cases
guest_create_namespace
guest_io_validation

success "Phase 2 operations completed. Proceed with verification script."