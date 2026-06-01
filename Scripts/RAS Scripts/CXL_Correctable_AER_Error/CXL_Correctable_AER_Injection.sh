#!/usr/bin/env bash

# CXL Correctable AER Error Injection — mem-data-ecc

# STEP 1 (HOST TERMINAL) - Load KVM and start QEMU
sudo modprobe kvm
sudo modprobe kvm_intel

cd ~/cxl && ./start-cxl.sh


# STEP 2 (GUEST TERMINAL) - Create CXL region and turn on tracing
sudo su
cxl create-region -d decoder0.0 -m mem1 -s 512M -t ram

echo 1 > /sys/kernel/debug/tracing/tracing_on
echo 1 > /sys/kernel/debug/tracing/events/cxl/enable


# STEP 3 (QMP TERMINAL - open a new host window) - Connect to QEMU
nc 127.0.0.1 4444
{"execute": "qmp_capabilities"}


# STEP 4 (QMP TERMINAL) - Inject mem-data-ecc correctable error
# mem-data-ecc = Memory Data ECC error on CXL.mem that hardware detected and corrected
# Maps to CXL RAS Correctable Error Status bit 1 and PCIe AER bit 14 (PCI_ERR_COR_INTERNAL)

{"execute": "cxl-inject-correctable-error",
 "arguments": {"path": "/machine/peripheral/cxl1",
               "type": "mem-data-ecc"}}


# STEP 5 (GUEST TERMINAL) - Check IRQ 25 count went up by 1
cat /proc/interrupts | grep -E "24|25"

dmesg | grep -iE "aer|correctable" | tail -10

# Expected: severity=Correctable, [14] CorrIntErr, no link reset needed
# No register clearing needed
