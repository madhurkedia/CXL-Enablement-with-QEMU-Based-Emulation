#!/usr/bin/env bash
# CXL Poison Validation 
[[ $EUID -ne 0 ]] && { echo "run as root"; exit 1; }

T="/sys/kernel/debug/tracing"
echo 1 > "$T/events/cxl/enable" 2>/dev/null; echo 1 > "$T/tracing_on"; echo > "$T/trace"
echo 1 > /sys/bus/cxl/devices/mem0/trigger_poison_list; sleep 2

state=$(cxl list -R 2>/dev/null | grep -oP '(?<="decode_state":")[^"]+' || echo "none")
records=$(grep "cxl_poison" "$T/trace" 2>/dev/null || true)
count=$(echo "$records" | grep -c "cxl_poison" 2>/dev/null || true); count=${count:-0}

echo "Region : $state | Poison : $count record(s)"
echo "$records" | while IFS= read -r line; do
    dpa=$(echo "$line" | grep -oP '(?<=dpa=)0x[0-9a-fA-F]+' || true)
    len=$(echo "$line" | grep -oP '(?<=dpa_length=)0x[0-9a-fA-F]+' || true)
    hpa=$(echo "$line" | grep -oP '(?<=hpa=)0x[0-9a-fA-F]+' || true)
    [[ -n "$dpa" ]] && echo "  DPA=$dpa len=$len HPA=$hpa"
done
echo "Driver : $(readlink -f /sys/bus/cxl/devices/mem0/driver 2>/dev/null || echo none)"
[[ "$count" -gt 0 && "$state" == "commit" ]] && echo "Result : PASS" || echo "Result : FAIL"
