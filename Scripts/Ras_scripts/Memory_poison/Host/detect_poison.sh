# CXL Poison Detector - GUEST SIDE
# What it does: Asks kernel to check for poison, reads the trace log

# Step 1: Turn on kernel tracing for CXL events
echo 1 > /sys/kernel/debug/tracing/events/cxl/enable
echo 1 > /sys/kernel/debug/tracing/tracing_on

# Step 2: Clear old traces
echo > /sys/kernel/debug/tracing/trace

# Step 3: Tell kernel "go check the CXL device for poison"
echo 1 > /sys/bus/cxl/devices/mem0/trigger_poison_list

# Step 4: Wait for kernel to finish
sleep 1

# Step 5: Read what kernel found
echo "Poison Records"
grep cxl_poison /sys/kernel/debug/tracing/trace || echo "No poison found"
