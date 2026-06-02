# CXL-Enablement-with-QEMU-Based-Emulation

## Project Overview
Automated Linux-based framework for emulating CXL memory devices, validating RAS workflows, and performing runtime fault injection and kernel-level error analysis using QEMU virtualization.

---

## The Problem
* Modern data-center, cloud, and AI workloads are rapidly increasing memory demands, making traditional memory architectures difficult to scale efficiently.
* This growing limitation, often referred to as the **"Memory Wall,"** creates challenges in achieving scalable, low-latency, and high-capacity memory expansion.
* Compute Express Link (CXL) was introduced as a high-speed cache-coherent interconnect standard designed to enable memory expansion, memory pooling, and efficient communication between processors and devices over PCIe infrastructure.
* CXL Type-3 devices specifically focus on memory expansion and disaggregated memory architectures.

---

## Features

| Feature | Description |
| :--- | :--- |
| **Volatile & Persistent Memory** | Full support for emulating both DRAM-like volatile backends and Storage-Class Memory (SCM).
| **Hot-Plug Support** | Simulate dynamic insertion/removal of CXL devices to test kernel-level event handling. 
| **Dynamic BAR Configuration** | Implements Base Address Registers for seamless host discovery of device control registers.
| **HDM Decoder Orchestration** | Advanced Host-managed Device Memory decoding for precise memory interleaving.
| **PCIe-to-CXL Transition** | Emulates "Flex Bus" logic, transitioning from standard PCIe to CXL via DVSEC negotiation.
| **Native Tool Support** | Fully compatible with industry-standard tools: `cxl-cli`, `ndctl`, and `libnvdimm`.
| **Deep Inspection** | Optimized for hardware-level debugging using `lspci -vvv` and kernel-log analysis.

---

## Architecture

The project uses a Linux-based QEMU virtualization environment to emulate CXL Type-3 memory devices and validate kernel-level RAS workflows.

| Stage | Description |
| :--- | :--- |
| **Host Linux Environment** | Ubuntu host system running Linux Kernel, KVM, and QEMU virtualization stack. |
| **QEMU Virtual Machine** | Creates an isolated virtual platform for CXL experimentation and validation. |
| **Guest Linux Kernel** | Linux guest environment with native CXL subsystem and driver support enabled. |
| **CXL Root Port Configuration** | Establishes the virtual CXL topology and device communication path. |
| **CXL Type-3 Memory Device** | Emulates expandable CXL memory devices inside the virtual machine. |
| **QMP-Based Fault Injection** | Injects poison and runtime memory faults using QEMU Machine Protocol (QMP). |
| **AER Error Detection** | Detects runtime PCIe/CXL error events using Advanced Error Reporting mechanisms. |
| **Kernel-Level Error Handling** | Triggers Linux kernel fault handling and recovery workflows for validation. |
| **RAS Validation & Analysis** | Verifies Reliability, Availability, and Serviceability (RAS) behavior during runtime failures. |
| **Runtime Debugging & Monitoring** | Uses `dmesg`, `cxl-cli`, `ndctl`, and `lspci` for runtime inspection and analysis. |

---

## Tech Stack

| Component | Technology |
| :--- | :--- |
| **Emulation Engine** | QEMU
| **Protocol Layer** | CXL 2.x / 3.x
| **Host/Guest OS** | Ubuntu 22.04 LTS / 24.04 LTS 
| **Analysis Tools** | `cxl-cli`, `ndctl`, `lspci`, `dmesg` 
| **Firmware** | OVMF (Open Virtual Machine Firmware)

---

## Prerequisites

To ensure protocol stability and high-fidelity emulation, the environment requires the following specifications:

* **CPU**: x86_64 architecture with **Intel VT-x** or **AMD-V** virtualization enabled.

* **RAM**: **16GB+** (Allocated for concurrent Host and CXL Guest memory mapping on Ubuntu).

* **Kernel**: Linux **v6.18** + Custom compiled for CXL subsystems (Required for native `CONFIG_CXL` driver support).
  
* **Packages**: `qemu-system-x86`, `cxl-cli`, and `ndctl`.
  
* **Firmware**: **OVMF** (Open Virtual Machine Firmware) to enable UEFI boot support. 

---

## Quick Start

The setup script automatically initializes the QEMU-based CXL emulation environment, configures the virtual topology, and launches the guest virtual machine for validation and testing.

```bash
# Step 1: Grant execution permissions to the setup script
chmod +x CXL_Complete_Setup.sh

# Step 2: Launch the complete CXL emulation environment
./CXL_Complete_Setup.sh
```
---

## CXL Error Injection Guide

This section provides reference commands and logs for injecting various CXL error types in the QEMU-based emulation environment.

- `CXL_Injection_Reference.txt`

---

## Acknowledgements

This project was developed as part of the **HPE CPP3 Program**, representing a collaborative effort in advanced systems research and CXL enablement. 

---

## Team Members

| Name | GitHub Profile |
| :--- | :--- |
| **Aadhar Bindal** | [@Aadharbindal](https://github.com/Aadharbindal)
| **Madhur Kedia** | [@madhurkedia](https://github.com/madhurkedia)
| **Ronak Khandelwal** | [@ronakKhandelwal](https://github.com/Ronak-Khandelwal)
| **Virendra Singh Rathore** | [@virendrasinghrathore](https://github.com/virendrasinghrathore1412) 
| **Vishwas Saini** | [@vishwassaini](https://github.com/Vishwas-saini-99) 

---
