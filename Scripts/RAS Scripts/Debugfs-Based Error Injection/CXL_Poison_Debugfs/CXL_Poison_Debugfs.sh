#!/bin/bash
#
# Description:
#   Injects poison at a target DPA via the kernel's debugfs CCI mailbox helper
#   (Inject Poison, opcode 0x4301), then triggers a "Get Poison List" CCI
#   command (opcode 0x4100) and confirms the event in kernel tracing.
#

set -e

TARGET_DEV="mem0"
TARGET_DPA="0x10000000"

CXL_DEBUG_INJECT="/sys/kernel/debug/cxl/$TARGET_DEV/inject_poison"
CXL_DEBUG_CLEAR="/sys/kernel/debug/cxl/$TARGET_DEV/clear_poison"
CXL_SYS_TRIGGER="/sys/bus/cxl/devices/$TARGET_DEV/trigger_poison_list"
TRACE_BUFFER="/sys/kernel/debug/tracing/trace"
TRACE_ENABLE="/sys/kernel/debug/tracing/events/cxl/cxl_poison/enable"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: Please run this script as root."
    exit 1
fi

echo "[+] Step 1: Configuring OS kernel tracing infrastructure"
echo 1 > "$TRACE_ENABLE"
echo 0 > "$TRACE_BUFFER"

echo "[+] Step 2: Injecting CXL Media Error via CCI Mailbox (Opcode 0x4301)"
if [ -f "$CXL_DEBUG_INJECT" ]; then
    echo "$TARGET_DPA" > "$CXL_DEBUG_INJECT"
    echo " -> Successfully sent Inject Poison payload for DPA $TARGET_DPA"
else
    echo "[-] Error: CCI injection interface missing. Check kernel configuration."
    exit 1
fi

echo "[+] Step 3: Triggering Hardware 'Get Poison List' over CCI (Opcode 0x4100)"
if [ -f "$CXL_SYS_TRIGGER" ]; then
    echo 1 > "$CXL_SYS_TRIGGER"
    # Allow a split second for hardware mailbox handling
    sleep 0.5
else
    echo "[-] Warning: Standard trigger missing, attempting fallback region walk"
    cat /sys/bus/cxl/devices/region*/poison > /dev/null 2>&1 || true
fi

echo "[+] Step 4: Extracting hardware-reported telemetry..."
if grep -q "dpa=$TARGET_DPA" "$TRACE_BUFFER"; then
    echo ""
    echo " SUCCESS: Hardware CCI confirmed error state persistence!"
    echo ""
    grep "dpa=$TARGET_DPA" "$TRACE_BUFFER"
else
    echo "[-] Error: Injected address not found in hardware poison logs."
    exit 1
fi

# Optional Step 5: Cleanup/Clear Poison
# echo "[+] Step 5: Cleaning up hardware state via CCI Clear Poison (Opcode 0x4102)..."
# echo "$TARGET_DPA" > "$CXL_DEBUG_CLEAR"

echo "[+] Done."
