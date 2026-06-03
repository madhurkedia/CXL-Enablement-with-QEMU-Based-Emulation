# CXL General Media Event Injection

## STEP 1 (HOST TERMINAL) - Load KVM and start QEMU

```bash
sudo modprobe kvm
sudo modprobe kvm_intel

cd ~/cxl_lab/cxl && ./start-cxl.sh
```

## STEP 2 (GUEST TERMINAL) - Creating CXL region and turning tracing on 

```bash
sudo su
cxl create-region -d decoder0.0 -m mem1 -s 512M -t ram

echo 1 > /sys/kernel/debug/tracing/tracing_on
echo 1 > /sys/kernel/debug/tracing/events/cxl/enable
```

## STEP 3 (QMP TERMINAL) - Connecting to QEMU

```bash
nc 127.0.0.1 4444
{"execute": "qmp_capabilities"}
```

## STEP 4 (QMP TERMINAL) - Inject general media event

> General media events report errors in the persistent or volatile media  
> Travel through CXL Event Log path -> MSI-X IRQ 38  
> Kernel reads via Get Event Records

```json
{"execute": "cxl-inject-general-media-event", "arguments": {"path": "/machine/peripheral/cxl1", "type": 0, "flags": 0, "dpa": 4563402752, "descriptor": 0, "log": "informational", "transaction-type": 0}}

{"execute": "cxl-inject-general-media-event", "arguments": {"path": "/machine/peripheral/cxl1", "type": 0, "flags": 0, "dpa": 4563402752, "descriptor": 0, "log": "warning", "transaction-type": 0}}

{"execute": "cxl-inject-general-media-event", "arguments": {"path": "/machine/peripheral/cxl1", "type": 0, "flags": 0, "dpa": 4563402752, "descriptor": 0, "log": "failure", "transaction-type": 0}}

{"execute": "cxl-inject-general-media-event", "arguments": {"path": "/machine/peripheral/cxl1", "type": 0, "flags": 0, "dpa": 4563402752, "descriptor": 0, "log": "fatal", "transaction-type": 0}}
```

## STEP 5 (GUEST TERMINAL) - Check IRQ 38 incremented and trace entry appeared

```bash
cat /proc/interrupts | grep "0e:00"

cat /sys/kernel/debug/tracing/trace | grep "cxl_general_media"
```

> **Expected:** IRQ 38 +1 per injection, cxl_general_media trace entry, no link reset
