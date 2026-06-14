# CXL Memory Module Event Injection 

## STEP 1 (HOST TERMINAL) - Loading KVM and starting QEMU

```bash
sudo modprobe kvm
sudo modprobe kvm_intel

cd ~/cxl_lab/cxl && ./start-cxl.sh
```

## STEP 2 (GUEST TERMINAL)

```bash
sudo su
cxl create-region -d decoder0.0 -m mem1 -s 512M -t ram

echo 1 > /sys/kernel/debug/tracing/tracing_on
echo 1 > /sys/kernel/debug/tracing/events/cxl/enable
```

## STEP 3 (QMP TERMINAL) - Connect to QEMU

```bash
nc 127.0.0.1 4444
{"execute": "qmp_capabilities"}
```

## STEP 4 (QMP TERMINAL) - Inject memory module event

> Memory module events carry a full device health snapshot at time of error  
> Travel through CXL Event Log path -> MSI-X IRQ 38  
> Kernel reads via Get Event Records (CCI 0x0100), clears via 0x0101

```json
{"execute": "cxl-inject-memory-module-event", "arguments": {"path": "/machine/peripheral/cxl1", "log": "informational", "flags": 0, "type": 0, "health-status": 0, "media-status": 0, "additional-status": 0, "life-used": 50, "temperature": 35, "dirty-shutdown-count": 0, "corrected-volatile-error-count": 5, "corrected-persistent-error-count": 0}}

{"execute": "cxl-inject-memory-module-event", "arguments": {"path": "/machine/peripheral/cxl1", "log": "warning", "flags": 0, "type": 0, "health-status": 1, "media-status": 0, "additional-status": 0, "life-used": 75, "temperature": 85, "dirty-shutdown-count": 2, "corrected-volatile-error-count": 120, "corrected-persistent-error-count": 0}}

{"execute": "cxl-inject-memory-module-event", "arguments": {"path": "/machine/peripheral/cxl1", "log": "failure", "flags": 0, "type": 0, "health-status": 3, "media-status": 1, "additional-status": 0, "life-used": 90, "temperature": 95, "dirty-shutdown-count": 5, "corrected-volatile-error-count": 500, "corrected-persistent-error-count": 10}}

{"execute": "cxl-inject-memory-module-event", "arguments": {"path": "/machine/peripheral/cxl1", "log": "fatal", "flags": 0, "type": 0, "health-status": 7, "media-status": 3, "additional-status": 1, "life-used": 99, "temperature": 105, "dirty-shutdown-count": 10, "corrected-volatile-error-count": 9999, "corrected-persistent-error-count": 50}}
```

## STEP 5 (GUEST TERMINAL) - Check IRQ 38 incremented and trace entry appeared

```bash
cat /proc/interrupts | grep "0e:00"

cat /sys/kernel/debug/tracing/trace | grep "cxl_memory_module"

cat /sys/kernel/debug/tracing/trace | grep "cxl_memory_module" | fold -w 200     # wraps long lines at 200 characters so the output doesn't get cut off at terminal edge.
```

> **Expected:** IRQ 38 +1 per injection, cxl_memory_module trace entry, no link reset
