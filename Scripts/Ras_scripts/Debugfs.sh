#!/bin/bash
# =============================================================================
# CXL RAS Test Suite (QEMU / Debugfs Based)
# Tests: Media Error (Poison) + Stress + Kernel Observation + Recovery
# =============================================================================
set -uo pipefail

REPORT_DIR="/root/cxl_ras_results"
LOG="$REPORT_DIR/cxl_ras_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$REPORT_DIR"
exec > >(tee -a "$LOG") 2>&1

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $*"; ((PASS++)); }
fail() { echo "[FAIL] $*"; ((FAIL++)); }
skip() { echo "[SKIP] $*"; ((SKIP++)); }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

echo "══════════════════════════════════════════════"
echo "   CXL RAS TEST SUITE (DEBUGFS BASED)"
echo "══════════════════════════════════════════════"
info "Kernel : $(uname -r)"
info "Host   : $(hostname)"
info "Date   : $(date)"
info "Log    : $LOG"
echo ""

# -----------------------------------------------------------------------------
# Step 0: Mount debugfs if not already mounted
# -----------------------------------------------------------------------------
echo "=== [0] Checking debugfs ==="
if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs debugfs /sys/kernel/debug && pass "debugfs mounted" || { fail "Could not mount debugfs"; exit 1; }
else
    pass "debugfs already mounted"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 1: Detect CXL mem devices
# -----------------------------------------------------------------------------
echo "=== [1] Detecting CXL memory devices ==="
CXL_MEMS=$(ls /sys/bus/cxl/devices/ 2>/dev/null | grep -E "^mem[0-9]+" || true)
if [[ -z "$CXL_MEMS" ]]; then
    fail "No CXL mem devices found in /sys/bus/cxl/devices/"
    exit 1
fi
pass "Found CXL mem devices:"
echo "$CXL_MEMS"
echo ""

MEM="mem0"
DBG="/sys/kernel/debug/cxl/$MEM"

if [[ ! -d "$DBG" ]]; then
    fail "Debugfs path not found: $DBG"
    exit 1
fi
pass "Using debugfs device: $MEM at $DBG"
echo ""

# -----------------------------------------------------------------------------
# Step 2: Baseline state
# -----------------------------------------------------------------------------
echo "=== [2] Baseline kernel state ==="
info "CXL-related dmesg at baseline:"
dmesg | grep -iE "cxl|pmem|nvdimm" | tail -20 || true
echo ""

# -----------------------------------------------------------------------------
# Step 3: Provision CXL namespace (required for /dev/pmem0)
# -----------------------------------------------------------------------------
echo "=== [3] Provisioning CXL region and namespace ==="
if command -v cxl &>/dev/null; then
    info "Attempting to create region..."
    cxl create-region -m "$MEM" -d decoder0.0 2>/dev/null && pass "Region created" || warn "Region creation skipped (may already exist)"

    info "Attempting to create namespace..."
    cxl create-namespace -m "$MEM" 2>/dev/null && pass "Namespace created" || warn "Namespace creation skipped (may already exist)"

    info "Current CXL list:"
    cxl list 2>/dev/null || true
else
    skip "cxl tool not available - skipping namespace provisioning"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 4: Inject media poison
# -----------------------------------------------------------------------------
echo "=== [4] Injecting CXL poison (media error simulation) ==="
if [[ -f "$DBG/inject_poison" ]]; then
    if echo 0x0 > "$DBG/inject_poison" 2>/dev/null; then
        pass "Poison injected at address 0x0"
    else
        fail "Poison injection failed (write error)"
    fi
else
    fail "inject_poison interface not found at $DBG/inject_poison"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 5: Verify poison list
# -----------------------------------------------------------------------------
echo "=== [5] Verifying poison list ==="
if [[ -f "$DBG/poison_list" ]]; then
    POISON_OUT=$(cat "$DBG/poison_list" 2>/dev/null || true)
    if [[ -n "$POISON_OUT" ]]; then
        pass "Poison list contents:"
        echo "$POISON_OUT"
    else
        warn "Poison list is empty (injection may not have taken effect)"
    fi
else
    skip "poison_list interface not available"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 6: Memory stress test
# -----------------------------------------------------------------------------
echo "=== [6] Memory access stress test ==="
PMEM="/dev/pmem0"
if [[ -b "$PMEM" ]]; then
    info "Writing stress pattern to $PMEM..."
    if dd if=/dev/zero of="$PMEM" bs=4k count=1024 oflag=direct 2>/dev/null; then
        pass "Write stress completed"
    else
        warn "Write stress encountered errors (expected with poison)"
    fi

    info "Reading stress pattern from $PMEM..."
    if dd if="$PMEM" of=/dev/null bs=4k count=1024 iflag=direct 2>/dev/null; then
        pass "Read stress completed"
    else
        warn "Read stress encountered errors (expected with poison)"
    fi
else
    skip "$PMEM not found - namespace may not be provisioned"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 7: Kernel RAS observation
# -----------------------------------------------------------------------------
echo "=== [7] Kernel RAS log observation ==="
info "CXL / RAS / error related dmesg:"
dmesg | grep -iE "cxl|poison|error|mce|ndctl|pmem|nvdimm|hardware" | tail -60 || true
echo ""

# -----------------------------------------------------------------------------
# Step 8: CXL event summary via cxl tool
# -----------------------------------------------------------------------------
echo "=== [8] CXL event and poison summary ==="
if command -v cxl &>/dev/null; then
    info "cxl list -P -v (poison list):"
    cxl list -P -v 2>/dev/null || warn "cxl list -P failed"
    echo ""
    info "cxl list -M (memory devices):"
    cxl list -M 2>/dev/null || true
else
    skip "cxl tool not available"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 9: Clear poison (recovery test)
# -----------------------------------------------------------------------------
echo "=== [9] Clearing poison (recovery) ==="
if [[ -f "$DBG/clear_poison" ]]; then
    if echo 0x0 > "$DBG/clear_poison" 2>/dev/null; then
        pass "Poison cleared at address 0x0"
    else
        fail "Poison clear failed"
    fi
else
    skip "clear_poison interface not available"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 10: Post-recovery validation
# -----------------------------------------------------------------------------
echo "=== [10] Post-recovery access validation ==="
if [[ -b "$PMEM" ]]; then
    if dd if=/dev/zero of="$PMEM" bs=4k count=512 oflag=direct 2>/dev/null; then
        pass "Post-recovery write access succeeded"
    else
        fail "Post-recovery write access failed"
    fi
    if dd if="$PMEM" of=/dev/null bs=4k count=512 iflag=direct 2>/dev/null; then
        pass "Post-recovery read access succeeded"
    else
        fail "Post-recovery read access failed"
    fi
else
    skip "$PMEM not available for post-recovery test"
fi
echo ""

# -----------------------------------------------------------------------------
# Step 11: Final dmesg snapshot
# -----------------------------------------------------------------------------
echo "=== [11] Final dmesg snapshot ==="
dmesg | grep -iE "cxl|poison|error|mce" | tail -30 || true
echo ""

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
echo "══════════════════════════════════════════════"
echo "   RAS TEST COMPLETE"
echo "══════════════════════════════════════════════"
echo ""
echo "[RESULTS]"
echo "  PASS : $PASS"
echo "  FAIL : $FAIL"
echo "  SKIP : $SKIP"
echo ""
echo "[STEPS COVERED]"
echo "  0.  debugfs mount check"
echo "  1.  CXL device detection"
echo "  2.  Baseline kernel state"
echo "  3.  CXL namespace provisioning"
echo "  4.  Media poison injection"
echo "  5.  Poison list verification"
echo "  6.  Memory stress (dd)"
echo "  7.  Kernel RAS log observation"
echo "  8.  CXL event summary"
echo "  9.  Poison clear / recovery"
echo "  10. Post-recovery validation"
echo "  11. Final dmesg snapshot"
echo ""
echo "NOTE: This validates the MEDIA ERROR RAS path (debugfs based)."
echo "      AER/UCE injection requires additional kernel + QEMU support."
echo ""
info "Log saved to: $LOG"
echo "══════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
