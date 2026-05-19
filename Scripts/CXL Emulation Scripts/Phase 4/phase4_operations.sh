# Description : CXL Phase 4 Operations (Two Independent Memory Pools + Filesystem Validation)

# Executed INSIDE the guest VM after Phase 4 topology is running.

# What this script demonstrates (and how to explain it):
#  Phase 3 showed we can interleave memory across a dual-switch topology.
#  Phase 4 proves that memory is genuinely usable:

#   Pool A  (Switch A, decoder0.0) → mem0 + mem1, 2-way interleave
#            → namespace → /dev/pmem0 → ext4 → /mnt/cxl-pool-a

#   Pool B  (Switch B, decoder1.0) → mem2 + mem3, 2-way interleave
#            → namespace → /dev/pmem1 → ext4 → /mnt/cxl-pool-b

#  We then write real files onto both filesystems and verify each file's
#  checksum to prove data integrity — something dd tests alone cannot show.

# New concepts introduced (all standard Linux, nothing CXL-specific):
#   mkfs.ext4  — format a block device as an ext4 filesystem
#   mount      — attach the filesystem to a directory
#   sha256sum  — generate and verify a checksum

# Prerequisites:
#   • phase4_Emulation.sh running, guest booted
#   • cxl-cli and ndctl installed in the guest

set -euo pipefail

# Colour Helpers
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Mount Points 
MOUNT_A="/mnt/cxl-pool-a"
MOUNT_B="/mnt/cxl-pool-b"

# Step 1: Verify Topology 
# Confirm all four memory devices and both decoders are visible.
# This is the same check from Phase 3 — familiar ground.
guest_verify_topology() {
    info " Step 1: Topology Verification"

    info "Full topology (Bus + Memdev + Port + Decoder)"
    cxl list -BMPD

    info "Memory devices (expect: mem0 mem1 mem2 mem3)"
    cxl list -M

    info "Decoders (expect: decoder0.0 for Switch A, decoder1.0 for Switch B)"
    cxl list -D

    info "PCIe device tree"
    lspci -tv
}

# Step 2: Create Two Independent Regions 
# Region A → Switch A's decoder (decoder0.0), using mem0 + mem1, 2-way interleave
# Region B → Switch B's decoder (decoder1.0), using mem2 + mem3, 2-way interleave

# In Phase 3 we created one region. Here we create two simultaneously,
# each on a separate switch. This is the key hardware-level advancement.
guest_create_two_regions() {
    info " Step 2: Create Two Independent Regions"

    info "Creating Region A on Switch A (mem0 + mem1 → decoder0.0, 2-way interleave)"
    cxl create-region \
        -m mem0 -m mem1 \
        -d decoder0.0 \
        --interleave-ways=2 \
        --interleave-granularity=4096

    info "Creating Region B on Switch B (mem2 + mem3 → decoder1.0, 2-way interleave)"
    cxl create-region \
        -m mem2 -m mem3 \
        -d decoder1.0 \
        --interleave-ways=2 \
        --interleave-granularity=4096

    info "Listing all created regions (expect: region0 and region1)"
    cxl list -R

    info "Decoder state after both regions committed"
    cxl list -D

    success "Both regions created successfully."
}

# Step 3: Create Two Namespaces 
# A namespace turns a CXL region into a block device (/dev/pmem*).
# One namespace per region → /dev/pmem0 (Pool A) and /dev/pmem1 (Pool B).
# This is the same ndctl command used in Phases 2 and 3 — nothing new here.
guest_create_namespaces() {
    info " Step 3: Create Namespaces"

    info "Creating namespace on region0 → will become /dev/pmem0"
    ndctl create-namespace --region=region0

    info "Creating namespace on region1 → will become /dev/pmem1"
    ndctl create-namespace --region=region1

    info "All namespaces:"
    ndctl list -v

    info "Block devices created:"
    ls -lh /dev/pmem* || die "/dev/pmem devices not found — namespace creation failed."

    success "Both namespaces created."
}

# Step 4: Format as ext4 Filesystems 
# This is new compared to Phases 2 and 3 where we only used raw dd.
# mkfs.ext4 formats the raw block device into a real filesystem.
# The -F flag is needed because mkfs asks for confirmation on block devices.
guest_format_filesystems() {
    info " Step 4: Format Both Pools as ext4"

    info "Formatting /dev/pmem0 (Pool A — Switch A memory)"
    mkfs.ext4 -F -L "cxl-pool-a" /dev/pmem0

    info "Formatting /dev/pmem1 (Pool B — Switch B memory)"
    mkfs.ext4 -F -L "cxl-pool-b" /dev/pmem1

    success "Both pools formatted as ext4."
}

# Step 5: Mount Both Filesystems 
# After formatting, we mount both filesystems at separate directories.
# The -o dax flag enables Direct Access mode — reads/writes bypass the
# page cache and go directly to CXL memory. This is what makes CXL
# memory different from a regular disk.
guest_mount_filesystems() {
    info " Step 5: Mount Both Pools"

    mkdir -p "${MOUNT_A}" "${MOUNT_B}"

    info "Mounting Pool A → ${MOUNT_A} (dax mode)"
    mount -o dax /dev/pmem0 "${MOUNT_A}"

    info "Mounting Pool B → ${MOUNT_B} (dax mode)"
    mount -o dax /dev/pmem1 "${MOUNT_B}"

    info "Mounted filesystems:"
    df -h "${MOUNT_A}" "${MOUNT_B}"

    success "Both pools mounted."
}

# Step 6: Write Files and Verify Checksums
# This is the main new demonstration in Phase 4.
# We write different files to each pool, compute their checksums,
# then read back and re-verify. A matching checksum proves:
#   1. Data was written correctly to CXL memory
#   2. Data was read back correctly from CXL memory
#   3. The two pools are independent (different data, different location)
#
# In Phases 2 and 3, dd only proved throughput, not correctness.
# sha256sum proves correctness.
guest_write_and_verify_checksums() {
    info " Step 6: Write Files and Verify Checksums"

    # Pool A
    info "Pool A: Writing test files..."

    # Write a 50 MiB file of random data to Pool A
    dd if=/dev/urandom of="${MOUNT_A}/pool_a_data.bin" bs=1M count=50 status=progress

    # Write a simple text marker so we can visually confirm pool identity
    echo "This file lives on CXL Pool A — Switch A (mem0 + mem1)" \
        > "${MOUNT_A}/pool_a_marker.txt"

    # Compute and save checksum of the binary file
    sha256sum "${MOUNT_A}/pool_a_data.bin" > "${MOUNT_A}/pool_a_data.sha256"

    info "Pool A checksum recorded:"
    cat "${MOUNT_A}/pool_a_data.sha256"

    # Pool B
    info "Pool B: Writing test files..."

    # Write a 50 MiB file of random data to Pool B (different data than Pool A)
    dd if=/dev/urandom of="${MOUNT_B}/pool_b_data.bin" bs=1M count=50 status=progress

    echo "This file lives on CXL Pool B — Switch B (mem2 + mem3)" \
        > "${MOUNT_B}/pool_b_marker.txt"

    sha256sum "${MOUNT_B}/pool_b_data.bin" > "${MOUNT_B}/pool_b_data.sha256"

    info "Pool B checksum recorded:"
    cat "${MOUNT_B}/pool_b_data.sha256"

    # Verification
    info "Verifying Pool A data integrity..."
    if sha256sum -c "${MOUNT_A}/pool_a_data.sha256"; then
        success "Pool A: checksum PASSED — data integrity confirmed."
    else
        die "Pool A: checksum FAILED — data corruption detected!"
    fi

    info "Verifying Pool B data integrity..."
    if sha256sum -c "${MOUNT_B}/pool_b_data.sha256"; then
        success "Pool B: checksum PASSED — data integrity confirmed."
    else
        die "Pool B: checksum FAILED — data corruption detected!"
    fi

    # Show pool contents
    info "Files on Pool A (${MOUNT_A}):"
    ls -lh "${MOUNT_A}/"

    info "Files on Pool B (${MOUNT_B}):"
    ls -lh "${MOUNT_B}/"

    # Show disk usage 
    info "Disk usage summary (both CXL pools):"
    df -h "${MOUNT_A}" "${MOUNT_B}"
}

# Step 7: Confirm Pools are Independent
# Read back the marker text from each pool to confirm they are separate
# memory regions and not the same underlying storage.
guest_confirm_pool_independence() {
    info " Step 7: Confirm Pool Independence"

    info "Marker from Pool A:"
    cat "${MOUNT_A}/pool_a_marker.txt"

    info "Marker from Pool B:"
    cat "${MOUNT_B}/pool_b_marker.txt"

    # Confirm checksums of the two data files are different
    # (they should be, since we wrote random data to each)
    SUM_A=$(awk '{print $1}' "${MOUNT_A}/pool_a_data.sha256")
    SUM_B=$(awk '{print $1}' "${MOUNT_B}/pool_b_data.sha256")

    if [[ "${SUM_A}" != "${SUM_B}" ]]; then
        success "Pool A and Pool B contain different data — pools are independent."
    else
        warn "Checksums are identical — unexpected, but may occur with non-random data."
    fi
}

# Step 8: Cleanup 
# Unmount cleanly. The data in the .raw backing files persists on the host
# even after unmount, which demonstrates the "persistent" in CXL Type-3
# persistent memory.
guest_cleanup() {
    info " Step 8: Unmount Filesystems"

    umount "${MOUNT_A}" && info "Pool A unmounted."
    umount "${MOUNT_B}" && info "Pool B unmounted."

    success "Cleanup complete. Backing files on host retain data (persistent memory)."
}

# Main Execution Sequence 
info " CXL Phase 4 — Two Independent Memory Pools "

guest_verify_topology
guest_create_two_regions
guest_create_namespaces
guest_format_filesystems
guest_mount_filesystems
guest_write_and_verify_checksums
guest_confirm_pool_independence
guest_cleanup

success " Phase 4 complete. "