# CXL-Enablement-with-QEMU-Based-Emulation

## Project Overview

As data-intensive workloads like AI/ML and In-Memory Databases outpace traditional DRAM scaling, the industry faces a critical **"Memory Wall."** This project delivers a high-fidelity **CXL (Compute Express Link)** Emulation Environment engineered to bridge the gap between architectural theory and hardware availability.

By leveraging **QEMU**, we have developed a virtualized ecosystem that replicates the complex signaling and protocol logic of **CXL Type-3 (Memory Expansion)** devices. This framework enables the validation of memory pooling and cache coherency strategies without physical silicon, facilitating the early-stage development of CXL-aware kernels and drivers.

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

## Acknowledgements

This project was developed as part of the **HPE CPP3 Program**, representing a collaborative effort in advanced systems research and CXL enablement. 

---

## Team Members

| Name | GitHub Profile |
| :--- | :--- |
| **Aadhar Bindal** | [@Aadharbindal](https://github.com/Aadharbindal)
| **Madhur Kedia** | [@madhurkedia](https://github.com/madhurkedia) 
| **Ronak Khandelwal** | [@ronakKhandelwal](https://github.com/ronakKhandelwal)
| **Virendra Singh Rathore** | [@virendrasinghrathore](https://github.com/virendrasinghrathore1412) 
| **Vishwas Saini** | [@vishwassaini](https://github.com/noonecanseeusall-ship-it) 

---
