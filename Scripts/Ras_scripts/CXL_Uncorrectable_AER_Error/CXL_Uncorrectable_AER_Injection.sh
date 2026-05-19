#!/usr/bin/env bash

# CXL Uncorrectable AER Error Injection — mem-data-ecc (Fatal)

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


# STEP 4 (GUEST TERMINAL) - Clear PCIe AER registers we have to do this before every injection
# Skipping this causes silent failure on second and subsequent injections
setpci -s 0000:0e:00.0 0x204.l=0xffffffff
setpci -s 0000:0e:00.0 0x208.l=0x00000000


# STEP 5 (QMP TERMINAL) - Inject the error
{"execute": "cxl-inject-uncorrectable-errors",
 "arguments": {"path": "/machine/peripheral/cxl1",
   "errors": [{"type": "mem-data-ecc",
     "header": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]}}


# STEP 6 (GUEST TERMINAL) - Check IRQ 25 went up and dmesg shows fatal + recovery
cat /proc/interrupts | grep -E "24|25"
dmesg | grep -iE "aer|uncor|fatal" | tail -10
# Expected: Uncorrectable (Fatal), Root Port link has been reset, device recovery successful

# STEP 7 (GUEST TERMINAL) - Re-injection sequence after every fatal error
# Fatal errors reset the PCIe link which tears down the CXL region so we recreate it first
cxl create-region -d decoder0.0 -m mem1 -s 512M -t ram

setpci -s 0000:0e:00.0 0x204.l=0xffffffff
setpci -s 0000:0e:00.0 0x208.l=0x00000000
# Then go back to Step 5 to inject again
