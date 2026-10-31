# RISC-V IOMMU — I/O Memory Management Unit

A synthesisable IOMMU (I/O Memory Management Unit) in SystemVerilog, targeting
the RISC-V ecosystem. Implements Sv32 address translation for DMA device
isolation, following the architectural principles of the RISC-V IOMMU
specification.

**Author**: Brendan Lynskey 2025
**Simulator**: Icarus Verilog (`iverilog -g2012`)
**Verification**: SystemVerilog task-based testbenches + CocoTB

## What is an IOMMU?

An IOMMU sits on the system bus between DMA-capable I/O devices and main memory.
It intercepts device-initiated memory transactions, translates the device's
virtual (or guest-physical) address to a host physical address using per-device
page tables, and forwards the translated transaction to memory — or blocks it if
translation fails.

### IOMMU vs CPU MMU

| Aspect | CPU MMU | IOMMU |
|--------|---------|-------|
| Sits between | CPU pipeline ↔ Memory | I/O device ↔ Memory |
| Triggered by | CPU load/store/fetch | Device DMA read/write |
| Indexed by | ASID (Address Space ID) | Device ID |
| Fault delivery | Synchronous exception | Fault queue + interrupt |
| Invalidation | `SFENCE.VMA` instruction | Software command (register write) |
| Interface | Pipeline signals | AXI4 bus |

### Why Device Isolation Matters

Without an IOMMU, any DMA device can read or write any physical memory address.
A compromised network card could read encryption keys from kernel memory. A
malicious USB device could overwrite the page tables of any process. The IOMMU
enforces per-device memory isolation — each device can only access the physical
pages explicitly mapped in its page table.

In virtualisation, the IOMMU enables safe device pass-through: a guest VM gets
direct access to a physical device (for near-native I/O performance) while the
hypervisor's IOMMU page tables ensure the VM cannot escape its memory sandbox.

## Architecture

- **Sv32 two-level page table walker** (same format as CPU MMU)
- **IOTLB**: Fully-associative translation cache (default 16 entries, LRU)
- **Device context cache**: Per-device configuration cache (default 8 entries)
- **AXI4 slave** (device side): Accepts DMA transactions
- **AXI4 master** (memory side): Forwards translated transactions + PTW reads
- **Register-based fault queue**: Logs translation failures, raises interrupt
- **Memory-mapped register interface**: CPU configuration and control

## Module Hierarchy

```
rtl/
├── iommu_pkg.sv               # Parameters, types, structs, fault cause codes
├── lru_tracker.sv             # LRU tracking — pseudo-LRU or true LRU (reuse from MMU)
├── iotlb.sv                   # IO Translation Lookaside Buffer
├── device_context_cache.sv    # Small fully-associative cache for device contexts
├── io_ptw.sv                  # IO Page Table Walker (Sv32 two-level)
├── io_permission_checker.sv   # Permission checking for device accesses
├── fault_handler.sv           # Fault recording into register-based queue
├── iommu_reg_file.sv          # Memory-mapped configuration registers
├── iommu_core.sv              # Datapath: ties IOTLB + PTW + DC cache + perm checker + fault handler
└── iommu_axi_wrapper.sv       # AXI4 slave + AXI4 master + register interface + top-level
```

`iommu_axi_wrapper.sv` is the true top-level instantiated by the SoC. It wraps
`iommu_core.sv` and handles AXI protocol. The core instantiates the IOTLB, PTW,
device context cache, permission checker, and fault handler.

## Quick Start

```bash
# Compile-only check (no simulation)
bash scripts/compile.sh

# Run all SystemVerilog tests
bash scripts/run_all_sv.sh

# Run all CocoTB tests
bash scripts/run_all_cocotb.sh

# Run everything
bash scripts/run_all.sh
```

## Test Summary

| Module | SV Tests | CocoTB Tests |
|--------|----------|--------------|
| `lru_tracker` | 6 | 4 |
| `iotlb` | 10 | 6 |
| `device_context_cache` | 7 | 4 |
| `io_ptw` | 10 | 6 |
| `io_permission_checker` | 8 | 4 |
| `fault_handler` | 7 | 4 |
| `iommu_reg_file` | 9 | 5 |
| `iommu_core` | 10 | 6 |
| `iommu_axi_wrapper` | 8 | 6 |
| **Total** | **75** | **45** |

## File Structure

```
RISCV_IOMMU/
├── README.md
├── LICENSE
├── rtl/
│   ├── iommu_pkg.sv
│   ├── lru_tracker.sv
│   ├── iotlb.sv
│   ├── device_context_cache.sv
│   ├── io_ptw.sv
│   ├── io_permission_checker.sv
│   ├── fault_handler.sv
│   ├── iommu_reg_file.sv
│   ├── iommu_core.sv
│   └── iommu_axi_wrapper.sv
├── tb/
│   ├── sv/
│   │   ├── tb_lru_tracker.sv
│   │   ├── tb_iotlb.sv
│   │   ├── tb_device_context_cache.sv
│   │   ├── tb_io_ptw.sv
│   │   ├── tb_io_permission_checker.sv
│   │   ├── tb_fault_handler.sv
│   │   ├── tb_iommu_reg_file.sv
│   │   ├── tb_iommu_core.sv
│   │   └── tb_iommu_axi_wrapper.sv
│   └── cocotb/
│       ├── test_lru_tracker/
│       │   ├── test_lru_tracker.py
│       │   └── Makefile
│       ├── test_iotlb/
│       │   ├── test_iotlb.py
│       │   └── Makefile
│       ├── test_device_context_cache/
│       │   ├── test_device_context_cache.py
│       │   └── Makefile
│       ├── test_io_ptw/
│       │   ├── test_io_ptw.py
│       │   └── Makefile
│       ├── test_io_permission_checker/
│       │   ├── test_io_permission_checker.py
│       │   └── Makefile
│       ├── test_fault_handler/
│       │   ├── test_fault_handler.py
│       │   └── Makefile
│       ├── test_iommu_reg_file/
│       │   ├── test_iommu_reg_file.py
│       │   └── Makefile
│       ├── test_iommu_core/
│       │   ├── test_iommu_core.py
│       │   └── Makefile
│       └── test_iommu_axi_wrapper/
│           ├── test_iommu_axi_wrapper.py
│           └── Makefile
├── scripts/
│   ├── run_all_sv.sh           # Compile and run all SV testbenches
│   ├── run_all_cocotb.sh       # Run all CocoTB tests
│   ├── run_all.sh              # Run both SV and CocoTB
│   └── compile.sh              # Compile-only (check for syntax errors)
└── docs/
    └── RISCV_IOMMU_Technical_Report.md
```

## Related Projects

- [RISCV_MMU](https://github.com/BrendanJamesLynskey/RISCV_MMU) — CPU-side Sv32 MMU with TLB and hardware page table walker

## Limitations

- Single-stage translation only (no two-stage / nested virtualisation)
- Single-beat AXI transfers only (no burst support)
- PTW does not set A/D bits (pre-set in page table entries)
- No command queue (invalidation via register writes only)
- No MSI remapping or ATS/PRI support

## How this was built

This IOMMU was written quickly with AI assistance (Claude Code) in March 2026, from a written specification, as one
of a set of SoC components. Its testbenches pass as described above, but unlike the
[5-stage core](https://github.com/BrendanJamesLynskey/RISCV_RV32IMC_5stage), which I have since reviewed line by line
and re-verified, it has not had that review: treat it as a working sketch rather than verified IP.

## License

MIT
