# CXL Poison Injection

## STEP 1 (HOST TERMINAL) - Load KVM and start QEMU

```bash
sudo modprobe kvm
sudo modprobe kvm_intel

cd ~/cxl_lab/cxl && ./start-cxl.sh
```

## STEP 2 (GUEST TERMINAL) - Creating CXL region and turning tracing on

```bash
cxl create-region -d decoder0.0 -m mem0 -s 512M -t ram

echo 1 > /sys/kernel/debug/tracing/tracing_on
echo 1 > /sys/kernel/debug/tracing/events/cxl/enable
```

## STEP 3 (QMP TERMINAL) - Connecting to QEMU

```bash
nc 127.0.0.1 4444
{"execute": "qmp_capabilities"}
```

## STEP 4 (QMP TERMINAL) - Inject poison

> Poison marks a DPA range as corrupted on the CXL device  
> No interrupt fired  

```json
{"execute": "cxl-inject-poison", "arguments": {"path": "/machine/peripheral/cxl1", "start": 0, "length": 64}}
```

## STEP 5 (GUEST TERMINAL) - Trigger poison list read then check trace

```bash
echo 1 > /sys/bus/cxl/devices/mem0/trigger_poison_list

cat /sys/kernel/debug/tracing/trace | grep "cxl_poison"
```

> **Expected:** cxl_poison trace entry after trigger, no IRQ fired
