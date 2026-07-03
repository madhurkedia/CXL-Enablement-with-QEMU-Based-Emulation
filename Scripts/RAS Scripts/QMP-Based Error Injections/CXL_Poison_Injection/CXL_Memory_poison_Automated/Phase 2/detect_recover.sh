#!/bin/bash

set -e

# Colour helpers 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_phase()   { echo -e "\n${BOLD}$1${NC}"; }

CXL_DEVICE="mem0"
TRACE_PATH="/sys/kernel/debug/tracing/trace"
POISON_TRIGGER="/sys/bus/cxl/devices/${CXL_DEVICE}/trigger_poison_list"
CLEAR_POISON_PATH="/sys/kernel/debug/cxl/${CXL_DEVICE}/clear_poison"
POISON_DPA="0x1000"

# Root check 


if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo $0"
    exit 1
fi
log_success "Running as root."

# Helper: path existence check 
check_path() {
    local path="$1"
    local label="$2"
    if [ ! -e "$path" ]; then
        log_error "$label not found at: $path"
        log_warn  "Is the CXL kernel module loaded? Try: modprobe cxl_core"
        exit 1
    fi
    log_success "$label found."
}

# Validate required paths 
log_info "Validating required kernel/sysfs paths..."
check_path "$TRACE_PATH"         "Kernel trace buffer"
check_path "$POISON_TRIGGER"     "Poison list trigger"
check_path "$CLEAR_POISON_PATH"  "Clear poison interface"

# cxl tool check 
CXL_TOOL_AVAILABLE=false
if command -v cxl &>/dev/null; then
    CXL_TOOL_AVAILABLE=true
    log_success "cxl userspace tool found: $(cxl --version 2>/dev/null || echo 'version unknown')"
else
    log_warn "cxl tool not found — skipping alert-config step."
    log_warn "Install with: apt install ndctl  OR  build from source."
fi


# PHASE 3 — Detection & Diagnosis

log_phase "PHASE 3: Detection & Diagnosis"

# Step 3.1 — Clear trace buffer before capture
log_info "Clearing existing trace buffer"
echo > "$TRACE_PATH"
log_success "Trace buffer cleared."

# Step 3.2 — Trigger OS audit of hardware poison list
log_info "Triggering OS audit of CXL hardware poison list"
echo 1 > "$POISON_TRIGGER"
sleep 1   # give the kernel a moment to process
log_success "Poison list trigger fired."

# Step 3.3 — Read trace log for poison detection events
log_info "Reading kernel trace log for CXL poison events"
echo ""
echo "CXL_poison trace output"
TRACE_OUTPUT=$(cat "$TRACE_PATH" | grep cxl_poison || true)
if [ -n "$TRACE_OUTPUT" ]; then
    echo "$TRACE_OUTPUT" | sed 's/^/  │  /'
    log_success "Poison event(s) detected in trace log."
else
    log_warn "No cxl_poison events found in trace log."
    log_warn "Injection may not have landed yet — re-run inject_poison.sh first."
fi
echo ""

# Step 3.4 — Hardware telemetry (optional, if cxl tool present)
if [ "$CXL_TOOL_AVAILABLE" = true ]; then
    log_info "Extracting hardware telemetry and alert thresholds"
    echo ""
    echo "CXL list --memdevs --alert-config"
    cxl list --memdevs --alert-config 2>/dev/null | sed 's/^/  │  /' || \
        log_warn "cxl list returned no output or an error."
    echo ""
else
    log_warn "Skipping cxl telemetry (tool not available)."
fi


# PHASE 4 — Hardware Recovery & Scrubbing

log_phase "PHASE 4: Hardware Recovery & Scrubbing"

# Step 4.1 — Clear trace buffer for clean recovery capture
log_info "Clearing trace buffer (clean slate for recovery event)"
echo > "$TRACE_PATH"
log_success "Trace buffer cleared."

# Step 4.2 — Dispatch Clear Poison command (Opcode 4301h) to DPA 0x1000
log_info "Dispatching Clear Poison (Opcode 4301h) to DPA $POISON_DPA "
echo "$POISON_DPA" > "$CLEAR_POISON_PATH"
sleep 1
log_success "Clear Poison command sent to $POISON_DPA."

# Step 4.3 — Re-audit hardware to confirm poison is cleared
log_info "Re-triggering hardware audit to verify recovery"
echo 1 > "$POISON_TRIGGER"
sleep 1
log_success "Post-recovery audit triggered."

# Step 4.4 — Read trace log to confirm recovery event
log_info "Reading kernel trace log for recovery confirmation"
echo ""
echo "Post-recovery cxl_poison trace output"
RECOVERY_TRACE=$(cat "$TRACE_PATH" | grep cxl_poison || true)
if [ -n "$RECOVERY_TRACE" ]; then
    echo "$RECOVERY_TRACE" | sed 's/^/  │  /'
    log_warn "Poison entries still present — scrubbing may need more time or the address persists."
else
    log_success "No poison events in trace log — memory successfully scrubbed and recovered."
fi
echo ""


echo -e "${BOLD}  Summary${NC}"
echo ""
log_info "Device       : $CXL_DEVICE"
log_info "Target DPA   : $POISON_DPA"
log_info "Trace path   : $TRACE_PATH"
log_info "Clear poison : $CLEAR_POISON_PATH"
echo ""
log_success "All phases complete. CXL memory poison test cycle finished."
echo ""
