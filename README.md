# CXL-Enablement-with-QEMU-Based-Emulation

## Project Overview
Automated Linux-based framework for emulating CXL Type-3 memory devices, validating RAS workflows, and performing runtime fault injection and kernel-level error analysis using QEMU virtualization.

---

## Background
Modern data-center, cloud, and AI workloads are scaling memory demand faster than traditional architectures can keep up — the so-called **"Memory Wall."** Compute Express Link (CXL) is a cache-coherent interconnect over PCIe that enables memory expansion, pooling, and disaggregation. This project focuses on **CXL Type-3** devices, which target memory expansion and disaggregated memory architectures. For a deeper treatment, see [`CXL_Emulation_Technical_Report.pdf`](Documentation/CXL%20Emulation/CXL_Emulation_Technical_Report.pdf).

---

## Features

| Feature | Description |
| :--- | :--- |
| **Volatile & Persistent Memory** | Emulates both DRAM-like volatile backends (system RAM expansion) and Storage-Class Memory (SCM) with host-backed `.raw` files and LSA persistence. |
| **Dual-Switch Topology** | Two independent CXL switch hierarchies, each with one upstream and two downstream ports, providing two isolated memory pools for independent region and namespace management. |
| **Hot-Plug Support** | Simulates dynamic insertion/removal of CXL devices to test kernel-level event handling. |
| **Dynamic BAR Configuration** | Implements Base Address Registers for seamless host discovery of device control registers. |
| **HDM Decoder Orchestration** | Host-managed Device Memory decoding for precise memory interleaving across pools. |
| **DAX Filesystem Support** | Persistent memory pools formatted as `ext4` and mounted with Direct Access (`-o dax`), bypassing the page cache for wire-speed I/O. |
| **RAM Spillover Validation** | Volatile mode demonstrates CXL capacity absorption via a 1.5 GiB `stress-ng` overallocation on a 1 GiB base-RAM guest. |
| **PCIe-to-CXL Transition** | Emulates "Flex Bus" logic, transitioning from standard PCIe to CXL via DVSEC negotiation. |
| **CEDT Verification** | OVMF generates a valid CXL Early Discovery Table at boot; verified via `acpidump` / `iasl` disassembly showing correct host bridge and Fixed Memory Window structures. |
| **Native Tool Support** | Compatible with industry-standard tools: `cxl-cli`, `ndctl`, and `libnvdimm`. |
| **Deep Inspection** | Runtime debugging using `lspci -vvv`, `dmesg`, and sysfs walks. |

---

## Architecture

The project uses a Linux-based QEMU virtualization environment to emulate CXL Type-3 memory devices and validate kernel-level RAS workflows.

| Stage | Description |
| :--- | :--- |
| **Host Linux Environment** | Ubuntu host system running Linux Kernel, KVM, and QEMU virtualization stack. |
| **QEMU Virtual Machine** | Creates an isolated virtual platform for CXL experimentation and validation. |
| **OVMF / EDK2 Firmware** | UEFI firmware compiled from EDK2 source; generates the CEDT (CXL Early Discovery Table) and ACPI namespace entries required for kernel CXL enumeration. |
| **Guest Linux Kernel** | Linux guest environment with native CXL subsystem and driver support enabled. |
| **Dual-Switch CXL Topology** | Two independent `pxb-cxl` root ports, each backed by an upstream switch with two downstream ports and two CXL Type-3 devices — forming two isolated memory pools. |
| **CXL Type-3 Memory Device** | Emulates expandable CXL memory devices in both persistent (`cxl-pmem`) and volatile (`cxl-type3 volatile-memdev`) modes. |
| **HDM Decoder & Region Configuration** | `cxl create-region` programs decoder hierarchy; interleave width and granularity are tunable per pool. |
| **QMP-Based Fault Injection** | Injects poison and runtime memory faults using QEMU Machine Protocol via `/tmp/qmp-sock`. |
| **AER Error Detection** | Detects runtime PCIe/CXL error events using Advanced Error Reporting mechanisms. |
| **Kernel-Level Error Handling** | Triggers Linux kernel fault handling and recovery workflows for validation. |
| **RAS Validation & Analysis** | Verifies Reliability, Availability, and Serviceability (RAS) behavior during runtime failures. |
| **Runtime Debugging & Monitoring** | Uses `dmesg`, `cxl-cli`, `ndctl`, and `lspci` for runtime inspection and analysis. |

---

## Repository Layout

```
.
├── Documentation/
│   ├── CXL Emulation/                         # Setup, build, and emulation reports (PDF)
│   ├── RAS/                                   # RAS architecture, validation, mistakes & solutions
│   └── PPT/                                   # Project presentations
├── Scripts/
│   ├── CXL Emulation Scripts/
│   │   ├── Persistent Memory/                 # PMEM emulation + operations
│   │   └── Volatile Memory/                   # VMEM emulation + operations
│   ├── CXL_Complete_Setup_Script/             # End-to-end launcher (CXL_Complete_Setup.sh)
│   └── RAS Scripts/
│       ├── AER Injection/                     # AER-based error injection
│       │   ├── AER_Inject_Correctable/        # Correctable AER injection script
│       │   └── AER_Inject_Uncorrectable_Fatal/# Uncorrectable fatal AER injection script
│       ├── Automated_Poison_Error_Pipeline/   # Automated memory-poison pipeline
│       ├── CCI-Based Error Injection/         # CCI-based raw poison injection
│       │   └── CXL_Raw_Poison_CCI/           # CCI poison injection script
│       ├── Debugfs-Based Error Injection/     # Debugfs-based injection
│       │   └── CXL_Poison_Debugfs/           # Debugfs poison injection script
│       └── QMP-Based Error Injections/        # Six QMP-driven injection guides + reference
│           ├── CXL_Correctable_AER_Error/
│           ├── CXL_DRAM_Injection/
│           ├── CXL_General_Media_Injection/
│           ├── CXL_Memory_Module_Injection/
│           ├── CXL_Poison_Injection/
│           └── CXL_Uncorrectable_AER_Error/
├── LICENSE
└── README.md
```

---

## Emulation Modes

### Persistent Memory (PMEM)
Emulates Storage-Class Memory using host-backed `.raw` files and Label Storage Areas (LSA). Data survives guest reboots. The full OS pipeline — region creation → namespace provisioning → `ext4` formatting → DAX mount — is automated via [`Persistent Memory/operations.sh`](Scripts/CXL%20Emulation%20Scripts/Persistent%20Memory/operations.sh).

### Volatile Memory (VMEM)
Emulates transparent System RAM expansion. The guest boots with 1 GiB of base RAM; four 1 GiB CXL volatile devices extend the address space. Memory blocks are brought online via sysfs (`echo online > .../state`) and absorbed by the Linux kernel as a new NUMA node. A 1.5 GiB `stress-ng` allocation — exceeding base RAM — proves active spillover into CXL capacity without OOM. Automation lives in [`Volatile Memory/operations.sh`](Scripts/CXL%20Emulation%20Scripts/Volatile%20Memory/operations.sh).

---

## Tech Stack

| Component | Technology |
| :--- | :--- |
| **Emulation Engine** | QEMU |
| **Protocol Layer** | CXL 2.0 (with selective 3.x features) |
| **Host/Guest OS** | Ubuntu 22.04 LTS / 24.04 LTS |
| **Guest Kernel** | Linux v6.18+ with native CXL subsystem |
| **Firmware** | OVMF built from EDK2 source (Tianocore upstream), no-secboot 4 MB variant |
| **Analysis Tools** | `cxl-cli`, `ndctl`, `lspci`, `dmesg` |


---

## System Configuration

The following hardware specifications are recommended for running the CXL emulation environment. Both platforms have been validated; native Ubuntu provides better KVM performance, while WSL2 offers accessibility on Windows hosts.

### Native Ubuntu (Recommended)

| Resource | Recommended Specification |
| :--- | :--- |
| **CPU** | x86_64, 8+ cores (Intel VT-x / AMD-V required) |
| **RAM** | 16 GB minimum (32 GB recommended) |
| **Disk** | 100 GB+ free (SSD strongly preferred) |
| **OS** | Ubuntu 22.04 LTS or 24.04 LTS |
| **Kernel** | Custom-compiled Linux v6.18+ with CXL subsystem enabled |
| **KVM** | Native KVM acceleration required (`/dev/kvm` must be available) |

### WSL2 (Windows Subsystem for Linux)

| Resource | Recommended Specification |
| :--- | :--- |
| **Host CPU** | x86_64, 8+ cores (Intel VT-x / AMD-V required, enabled in BIOS) |
| **Host RAM** | 16 GB minimum (32 GB recommended) |
| **WSL2 RAM** | 8 GB+ allocated via `.wslconfig` (`memory=8GB` or higher) |
| **Disk** | 100 GB+ free on the Windows host (SSD strongly preferred) |
| **Host OS** | Windows 10 (Build 19041+) or Windows 11 |
| **WSL2 Distro** | Ubuntu 22.04 LTS or 24.04 LTS |
| **Kernel** | Custom-compiled WSL2 kernel v6.18+ with CXL and KVM modules enabled |
| **KVM** | Nested virtualization must be enabled (`nestedVirtualization=true` in `.wslconfig`) |

> **Note:** On WSL2, ensure your `.wslconfig` (located at `C:\Users\<user>\.wslconfig`) allocates sufficient resources. Example:
> ```ini
> [wsl2]
> memory=12GB
> processors=8
> nestedVirtualization=true
> ```

---

## Prerequisites

To ensure protocol stability and high-fidelity emulation, the environment requires the following:

* **CPU**: x86_64 architecture with **Intel VT-x** or **AMD-V** virtualization enabled.
* **Host RAM**: **16 GB+** (enough to back the host plus the guest's CXL memory mapping on Ubuntu).
* **Kernel**: Linux **v6.18+** custom-compiled with `CONFIG_CXL_BUS`, `CONFIG_CXL_MEM`, `CONFIG_CXL_PMEM`, `CONFIG_CXL_REGION`, and `CONFIG_DEV_DAX_CXL` enabled.
* **Packages**: `qemu-system-x86`, `cxl-cli`, `ndctl`, `python3`, `stress-ng`, `acpica-tools`.
* **Firmware**: **OVMF** built from **EDK2 source** (Tianocore upstream) — required for CEDT generation and CXL host-bridge enumeration. SeaBIOS cannot generate the CEDT and must not be used. Build steps are documented in [`Building UEFI Firmware using EDK2.pdf`](Documentation/CXL%20Emulation/Building%20UEFI%20Firmware%20using%20EDK2.pdf).

---

## Quick Start

The setup script initializes the QEMU-based CXL emulation environment, configures the virtual topology, and launches the guest VM for validation and testing.

```bash
# Step 1: Enter the setup directory
cd "Scripts/CXL_Complete_Setup_Script"

# Step 2: Grant execution permissions
chmod +x CXL_Complete_Setup.sh

# Step 3: Launch the complete CXL emulation environment
./CXL_Complete_Setup.sh
```

---

## CXL Error Injection Guide

Six QMP-based injection workflows are documented under [`Scripts/RAS Scripts/QMP-Based Error Injections/`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections), each with a step-by-step guide and terminal screenshots:

| Injection Type | Guide |
| :--- | :--- |
| **Memory Poison** | [`CXL_Poison_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_Poison_Injection/CXL_Poison_Injection.md) |
| **DRAM Error** | [`CXL_DRAM_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_DRAM_Injection/CXL_DRAM_Injection.md) |
| **General Media Error** | [`CXL_General_Media_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_General_Media_Injection/CXL_General_Media_Injection.md) |
| **Memory Module Event** | [`CXL_Memory_Module_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_Memory_Module_Injection/CXL_Memory_Module_Injection.md) |
| **Correctable AER Error** | [`CXL_Correctable_AER_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_Correctable_AER_Error/CXL_Correctable_AER_Injection.md) |
| **Uncorrectable AER Error** | [`CXL_Uncorrectable_AER_Injection.md`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/CXL_Uncorrectable_AER_Error/CXL_Uncorrectable_AER_Injection.md) |

Reference commands and expected logs for end-to-end runs are collected in [`QMP_Injection_Reference.txt`](Scripts/RAS%20Scripts/QMP-Based%20Error%20Injections/QMP_Injection_Reference.txt).

### Memory Poison Automation Pipeline
An end-to-end automated pipeline that performs environment checks, device discovery, strategy selection, injection, detection, and reporting:

* Driver: [`Memory_Poison_Automation_Pipeline.sh`](Scripts/RAS%20Scripts/Poison_Error_Pipeline/Memory_Poison_Automation_Pipeline.sh)
* Host helpers: [`inject_poison.py`](Scripts/RAS%20Scripts/Memory_poison/Host/inject_poison.py), [`detect_poison.sh`](Scripts/RAS%20Scripts/Memory_poison/Host/detect_poison.sh), [`validate_poison.sh`](Scripts/RAS%20Scripts/Memory_poison/Host/validate_poison.sh)

### Additional Injection Tooling
* **Debugfs-based injection**: [`Debugfs.sh`](Scripts/RAS%20Scripts/Debugfs/Debugfs.sh)
* **General media (Python)**: [`general_media_inject.py`](Scripts/RAS%20Scripts/General_Media_Error/general_media_inject.py)

---

## Documentation

Detailed PDF references are organized under `Documentation/`:

### CXL Emulation
* [Building UEFI Firmware using EDK2](Documentation/CXL%20Emulation/Building%20UEFI%20Firmware%20using%20EDK2.pdf)
* [CXL Emulation Technical Report](Documentation/CXL%20Emulation/CXL_Emulation_Technical_Report.pdf)
* [CXL Emulation on Ubuntu](Documentation/CXL%20Emulation/CXL_Emulation_Ubuntu.pdf)
* [CXL Emulation on WSL2](Documentation/CXL%20Emulation/CXL_Emulation_WSL2.pdf)

### RAS
* [RAS Overview](Documentation/RAS/RAS%20Overview.pdf)
* [RAS Architectural Framework](Documentation/RAS/RAS%20Architectural%20Framework.pdf)
* [CXL RAS Architecture and Emulation Validation](Documentation/RAS/CXL%20RAS%20Architecture%20and%20Emulation%20Validation.pdf)
* [CXL RAS Setup Guide](Documentation/RAS/CXL_RAS_Setup_Guide.pdf)
* [CXL RAS Mistakes and Solutions](Documentation/RAS/CXL_RAS_Mistakes_and_Solutions.pdf)

---

## Acknowledgements
This project was developed as part of the **Hewlett Packard Enterprise (HPE) CPP3 Program**, representing a collaborative effort in advanced systems research and CXL enablement.

---

## Team Members

| Name | GitHub Profile |
| :--- | :--- |
| **Aadhar Bindal** | [@Aadharbindal](https://github.com/Aadharbindal) |
| **Madhur Kedia** | [@madhurkedia](https://github.com/madhurkedia) |
| **Ronak Khandelwal** | [@ronakKhandelwal](https://github.com/Ronak-Khandelwal) |
| **Virendra Singh Rathore** | [@virendrasinghrathore](https://github.com/virendrasinghrathore1412) |
| **Vishwas Saini** | [@vishwassaini](https://github.com/Vishwas-saini-99) |
