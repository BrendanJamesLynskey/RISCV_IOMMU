# RISC-V IOMMU — Technical Report

**Author**: Brendan Lynskey 2025

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background and Motivation](#2-background-and-motivation)
3. [Relationship to the CPU MMU](#3-relationship-to-the-cpu-mmu)
4. [Architecture Overview](#4-architecture-overview)
5. [Module-by-Module Design Description](#5-module-by-module-design-description)
6. [AXI Protocol Handling](#6-axi-protocol-handling)
7. [Fault Queue Design: Register-Based vs Memory-Resident](#7-fault-queue-design-register-based-vs-memory-resident)
8. [IOTLB Design](#8-iotlb-design)
9. [Device Context Cache Design](#9-device-context-cache-design)
10. [Page Table Walker Design](#10-page-table-walker-design)
11. [Translation Pipeline and Core FSM](#11-translation-pipeline-and-core-fsm)
12. [Memory-Mapped Register Interface](#12-memory-mapped-register-interface)
13. [Verification Strategy](#13-verification-strategy)
14. [Performance Considerations](#14-performance-considerations)
15. [Stretch Goal Analysis](#15-stretch-goal-analysis)
16. [Limitations and Future Work](#16-limitations-and-future-work)
17. [Conclusion](#17-conclusion)

---

## 1. Introduction

This document describes the architecture, design decisions, implementation
trade-offs, verification strategy, and performance considerations for a
synthesisable RISC-V IOMMU (I/O Memory Management Unit) implemented in
SystemVerilog. The design follows the Sv32 page table format from the RISC-V
Privileged Specification and adapts the architectural principles of the RISC-V
IOMMU specification for a base implementation targeting Icarus Verilog
simulation.

The IOMMU provides hardware-enforced memory isolation for DMA-capable I/O
devices. It intercepts device-initiated memory transactions on the system bus,
translates device virtual addresses (DVAs) to host physical addresses (HPAs)
using per-device page tables, and either forwards the translated transaction to
memory or blocks it and logs a fault record.

### 1.1 Scope

The base implementation covers:

- Single-stage Sv32 address translation for device DMA transactions
- A fully-associative IOTLB with pseudo-LRU replacement
- A device context cache for per-device configuration
- An Sv32 two-level hardware page table walker
- AXI4 slave (device side) and AXI4 master (memory side) interfaces
- A register-based fault queue with interrupt support
- Memory-mapped configuration registers
- Comprehensive verification with 75 SystemVerilog tests and 45 CocoTB tests

### 1.2 Design Philosophy

The design prioritises correctness and clarity over maximum throughput. Key
principles:

1. **Sequential translation pipeline**: One transaction at a time, fully
   completing translation before accepting the next device request. This avoids
   the complexity of out-of-order translation and memory port arbitration at
   the cost of throughput.

2. **Reuse from CPU MMU**: The IOTLB, PTW FSM, and permission checking logic
   are architectural adaptations of the CPU-side Sv32 MMU modules. The same
   page table format, walk algorithm, and LRU tracker are used.

3. **Register-based fault queue**: Faults are stored in flip-flop-based
   registers inside the IOMMU rather than written to a memory-resident ring
   buffer. This eliminates the need for the fault handler to share the AXI
   master port with the PTW.

4. **Minimal AXI complexity**: Single-beat transfers only, one outstanding
   transaction, fixed 32-bit data width. This makes the AXI wrapper tractable
   for verification while still demonstrating correct protocol handling.

---

## 2. Background and Motivation

### 2.1 The DMA Security Problem

Direct Memory Access (DMA) allows I/O devices to read and write system memory
without CPU intervention, achieving high throughput for bulk data transfers.
However, without hardware address translation, DMA devices operate on physical
addresses and can access any memory location. This creates severe security
vulnerabilities:

- **Kernel memory corruption**: A compromised network controller could
  overwrite kernel data structures, escalating privileges or crashing the
  system.
- **Data exfiltration**: A malicious PCIe device could read encryption keys,
  passwords, or other secrets from any process's memory.
- **Virtualisation escape**: A device passed through to a guest VM could
  access memory belonging to the hypervisor or other VMs.

The IOMMU solves this by interposing a hardware translation layer between every
device and main memory. Each device is assigned its own page table (indexed by
a device ID), and the IOMMU translates every device-issued address through
that page table before allowing the memory access. Unmapped or permission-
violating accesses are blocked and logged.

### 2.2 IOMMU in the RISC-V Ecosystem

The RISC-V IOMMU specification (ratified by RISC-V International) defines a
standard interface for I/O address translation. It supports:

- Single-stage translation (DVA to HPA) for bare-metal device isolation
- Two-stage translation (DVA to GPA to HPA) for virtualised device
  pass-through
- Memory-resident command and fault queues
- MSI (Message Signaled Interrupt) remapping
- ATS/PRI (Address Translation Services / Page Request Interface) for
  PCIe devices

This project implements the single-stage translation subset, which is the
foundation on which all other features build.

### 2.3 Use Cases

The primary use cases for this IOMMU design are:

1. **Device isolation in embedded SoCs**: An FPGA-based SoC with multiple DMA
   controllers (Ethernet, USB, DMA engine) uses the IOMMU to confine each
   controller to its assigned memory region.

2. **Educational platform**: The design serves as a teaching tool for
   understanding I/O virtualisation hardware, page table walks, and bus
   protocol translation.

3. **Foundation for virtualisation**: The base implementation can be extended
   with two-stage translation to support hypervisor-managed device
   pass-through.

---

## 3. Relationship to the CPU MMU

### 3.1 Shared Architectural Concepts

The IOMMU and CPU MMU share fundamental architectural concepts but differ in
their triggering, context, and fault delivery mechanisms.

| Concept | CPU MMU | IOMMU |
|---------|---------|-------|
| Page table format | Sv32 two-level | Sv32 two-level (identical) |
| PTE format | 32-bit, V/R/W/X/U/G/A/D bits | 32-bit, same format |
| TLB | Fully-associative + LRU | IOTLB — same architecture, keyed by `{device_id, vpn}` |
| PTW FSM | L1_REQ to L1_WAIT to L1_CHECK to L0_REQ... | Identical FSM, triggered by IOTLB miss |
| Permission check | R/W/X + U/S privilege | R/W/X (no U/S — device privilege from context) |
| Interface | CPU pipeline signals | AXI4 slave + AXI4 master |
| Miss handling | Stall pipeline | Stall device via AXI backpressure |
| Fault delivery | Synchronous exception to CPU | Asynchronous fault queue + interrupt |
| Invalidation | `SFENCE.VMA` instruction | Register-write-triggered invalidation |
| Indexing | ASID (Address Space ID) | Device ID |

### 3.2 Module Reuse

The following modules are direct adaptations from the CPU MMU project:

- **`lru_tracker.sv`**: Identical implementation. The pseudo-LRU tree tracker
  is parameterised by depth and works for both the 16-entry IOTLB and the
  8-entry device context cache.

- **`iotlb.sv`**: Adapted from the CPU TLB. The key difference is the tag:
  the CPU TLB uses `{asid, vpn}` while the IOTLB uses `{device_id, vpn1, vpn0}`.
  The storage structure (valid, tag, PPN, permissions) is identical.

- **`io_ptw.sv`**: Adapted from the CPU PTW. The walk algorithm (L1_REQ
  through L0_CHECK) is identical. The difference is the memory interface: the
  CPU PTW reads from the memory hierarchy via pipeline signals, while the IO
  PTW uses a valid/ready memory read port that the AXI wrapper connects to
  the master interface.

### 3.3 Key Differences from CPU MMU

1. **No U/S privilege distinction**: Devices do not have user/supervisor
   modes. The U bit in PTEs is ignored. Instead, per-device permissions come
   from the device context table entry (RP, WP bits).

2. **Device context layer**: Before performing a page table walk, the IOMMU
   must look up the device's context to determine the root page table PPN,
   translation mode, and device-level permissions. This adds an extra lookup
   stage not present in the CPU MMU.

3. **Asynchronous fault delivery**: CPU MMU faults are synchronous — the
   faulting instruction traps immediately. IOMMU faults are asynchronous —
   the fault is recorded in a queue and an interrupt is raised. The faulting
   device receives an error response on the bus (AXI SLVERR).

4. **Bus protocol translation**: The CPU MMU operates within the processor
   pipeline. The IOMMU must speak AXI4 on both sides — accepting transactions
   from devices and issuing translated transactions (plus PTW reads) to
   memory.

---

## 4. Architecture Overview

### 4.1 System-Level Position

```
                    ┌─────────────────────┐
                    │       CPU           │
                    │   (with CPU MMU)    │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │   System Bus /      │
                    │   Interconnect      │
                    └───┬──────────┬──────┘
                        │          │
            ┌───────────▼───┐  ┌──▼────────────┐
            │   Memory      │  │   IOMMU       │
            │   Controller  │  │               │
            └───────────────┘  └───┬───────┬───┘
                                   │       │
                          AXI Master  AXI Slave
                          (to mem)    (from devices)
                                   │       │
                        ┌──────────┘       └──────────┐
                        │                             │
                ┌───────▼───────┐            ┌────────▼───────┐
                │   DRAM /      │            │  DMA Devices   │
                │   Memory      │            │  (NIC, USB,    │
                │               │            │   DMA engine)  │
                └───────────────┘            └────────────────┘
```

The IOMMU sits between DMA devices and the memory system. The CPU configures
the IOMMU via memory-mapped registers (through the system interconnect). When a
device issues a DMA transaction, it arrives at the IOMMU's AXI slave port. The
IOMMU translates the address and forwards the transaction on its AXI master
port, or returns an error to the device.

### 4.2 Internal Block Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                     iommu_axi_wrapper (top-level)                   │
│                                                                     │
│  ┌──────────────┐  ┌──────────────────────────────────────────┐     │
│  │ AXI Slave    │  │           iommu_core                     │     │
│  │ Interface    │──│                                          │     │
│  │ (device side)│  │  ┌──────────┐  ┌────────────────────┐   │     │
│  └──────────────┘  │  │ IOTLB    │  │ Device Context     │   │     │
│                    │  │          │  │ Cache              │   │     │
│  ┌──────────────┐  │  └──────────┘  └────────────────────┘   │     │
│  │ AXI Master   │  │                                          │     │
│  │ Interface    │──│  ┌──────────┐  ┌────────────────────┐   │     │
│  │ (memory side)│  │  │ IO PTW   │  │ IO Permission      │   │     │
│  └──────────────┘  │  │          │  │ Checker            │   │     │
│                    │  └──────────┘  └────────────────────┘   │     │
│  ┌──────────────┐  │                                          │     │
│  │ Register     │  │  ┌──────────┐                           │     │
│  │ Interface    │  │  │ Fault    │                           │     │
│  │ (CPU side)   │  │  │ Handler  │                           │     │
│  └──────────────┘  │  └──────────┘                           │     │
│                    └──────────────────────────────────────────┘     │
│  ┌──────────────┐                                                   │
│  │ Register     │                                                   │
│  │ File         │                                                   │
│  └──────────────┘                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.3 Translation Flow

The translation of a single device DMA transaction proceeds as follows:

1. Device issues read/write on AXI slave port with virtual address
2. AXI wrapper latches the transaction, extracts device ID from AXI ID field
3. Core FSM checks if IOMMU is enabled; if not, bypasses translation
4. Core looks up device context in DC cache (or fetches from memory on miss)
5. Permission checker validates device-level permissions (EN, RP, WP, mode)
6. If translation needed, core looks up IOTLB
7. On IOTLB miss, PTW walks the Sv32 page table (two memory reads)
8. PTW result refills IOTLB; physical address is computed
9. AXI wrapper forwards the translated transaction on AXI master port
10. Memory response relayed back to device through AXI slave port

If any step faults (invalid context, permission denied, invalid PTE, misaligned
superpage, memory error), the fault is recorded in the fault queue, an interrupt
is raised (if enabled), and the device receives an AXI SLVERR response.

---

## 5. Module-by-Module Design Description

### 5.1 `iommu_pkg.sv` — Package

The package centralises all parameters, type definitions, structs, and constants.
This ensures consistency across all modules and avoids magic numbers.

**Key parameters:**

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `PADDR_W` | 34 | Sv32 supports up to 34-bit physical addresses |
| `VADDR_W` | 32 | 32-bit virtual address space per Sv32 |
| `PAGE_OFFSET_W` | 12 | 4 KB pages (standard RISC-V page size) |
| `VPN_W` | 10 | Each VPN level is 10 bits (1024 PTEs per table) |
| `PPN_W` | 22 | 34 - 12 = 22-bit physical page number |
| `PTE_W` | 32 | Sv32 PTE is 32 bits |
| `DEVICE_ID_W` | 8 | Up to 256 devices; sufficient for embedded SoCs |
| `IOTLB_DEPTH` | 16 | Fully-associative; 16 entries balances area vs hit rate |
| `DC_CACHE_DEPTH` | 8 | Few devices active simultaneously; 8 entries is adequate |
| `AXI_DATA_W` | 32 | Matches PTE width and simplifies data path |
| `AXI_ADDR_W` | 34 | Equals PADDR_W |
| `AXI_ID_W` | 4 | Lower bits encode device ID |
| `FAULT_QUEUE_DEPTH` | 16 | Power of 2 for efficient pointer arithmetic |

**Structs:**

- `device_context_t` (64 bits): Encodes per-device configuration — enable,
  read/write permissions, fault policy, translation mode, and root page table
  PPN.
- `fault_record_t` (64 bits): Encodes fault information — validity, read/write
  indicators, fault cause code, device ID, and faulting virtual address.

**Fault cause codes**: Nine defined codes covering PTE invalidity, PTE
misalignment, read/write permission denial, context invalidity, context
permission denial, and PTW access faults.

**Translation mode codes**: `MODE_BARE` (passthrough) and `MODE_SV32`
(Sv32 translation). Other values are reserved and treated as invalid.

### 5.2 `lru_tracker.sv` — Pseudo-LRU Tracker

**Purpose**: Identifies the least-recently-used entry in a fully-associative
cache. Used by both the IOTLB and device context cache.

**Algorithm**: Tree-based pseudo-LRU. The tracker maintains `DEPTH-1` bits
arranged as a binary tree. Each internal node has a direction bit indicating
which subtree was accessed more recently. On each access, the tree bits along
the path from root to the accessed leaf are updated to point away from that
leaf. To find the LRU entry, the tree is walked from root to leaf, following
the direction bits.

**Design trade-off**: True LRU requires tracking a full permutation ordering
(`DEPTH!` states), which needs `log2(DEPTH!) ≈ DEPTH * log2(DEPTH)` bits and
complex update logic. Pseudo-LRU uses only `DEPTH-1` bits and has O(log DEPTH)
update and query paths. The approximation is sufficient for small cache depths
(8-16 entries) where the LRU and pseudo-LRU replacement decisions rarely
diverge.

**Interface**: On `access_valid`, the tracker records that entry `access_idx`
was used. The output `lru_idx` continuously indicates which entry should be
evicted next.

### 5.3 `iotlb.sv` — IO Translation Lookaside Buffer

**Purpose**: Caches recent address translations to avoid repeating expensive
page table walks for every device transaction.

**Microarchitecture**:

- **Storage**: Array of `DEPTH` entries. Each entry stores:
  `{valid, device_id, vpn1, vpn0, ppn, perm_r, perm_w, is_superpage}`.
- **Tag**: `{device_id, vpn1, vpn0}` for standard 4 KB pages. For 4 MB
  superpages, `vpn0` is a don't-care during lookup.
- **Lookup**: Fully combinational CAM (content-addressable memory) match.
  All entries are compared in parallel. If a matching valid entry is found,
  `lookup_hit` is asserted in the same cycle as `lookup_valid`, and the
  stored PPN and permissions are output.
- **Refill**: When the PTW completes a successful walk, the IOTLB is refilled
  with the new translation. The refill writes to the LRU slot (identified by
  the `lru_tracker` output), overwriting the least recently used entry.
- **Invalidation**: Software can invalidate entries by device ID (selective)
  or all entries at once (global). Selective invalidation clears the valid
  bits of all entries matching the specified device ID. Global invalidation
  clears all valid bits.
- **Superpage handling**: Superpages (4 MB, leaf PTE at level 1) are stored
  with the `is_superpage` flag set. During lookup, superpage entries match
  on `{device_id, vpn1}` only, ignoring `vpn0`. The final physical address
  computation for superpages includes the original `vpn0` in the page offset.

**Design decision — fully-associative vs set-associative**: A fully-associative
design was chosen because the IOTLB is small (16 entries). At this size, the
area overhead of parallel comparators is modest, and the hit rate is maximised
because any translation can be stored in any slot. For larger IOTLBs (64+
entries), a set-associative organisation would be preferred to reduce comparator
fan-in and critical path length.

**Performance**: The IOTLB provides hit/miss pulse outputs (`perf_hit`,
`perf_miss`) connected to performance counters in the register file. This
allows software to monitor the hit rate and tune page table layouts or IOTLB
size.

### 5.4 `device_context_cache.sv` — Device Context Cache

**Purpose**: Caches device context table entries fetched from main memory.
Each device context encodes the device's translation configuration (root page
table PPN, translation mode, permissions).

**Microarchitecture**: Architecturally identical to the IOTLB but simpler:

- Keyed by `device_id` only (no VPN)
- Stores the full 64-bit `device_context_t` struct
- 8 entries by default (fewer active devices than active translations)
- Own `lru_tracker` instance for replacement

**Design rationale**: The device context table resides in main memory and
must be fetched via AXI reads. Without a cache, every translation would
require two additional memory reads (the context is 64 bits = 2 x 32-bit
words). The cache amortises this cost across multiple translations from
the same device.

The 8-entry depth was chosen because embedded SoCs typically have fewer than
8 concurrently active DMA devices. If more devices are active, the cache
will thrash, but correctness is maintained — only performance degrades.

### 5.5 `io_ptw.sv` — IO Page Table Walker

**Purpose**: Performs Sv32 two-level page table walks when the IOTLB misses.
Reads page table entries from memory and produces a translated PPN or a
fault.

**FSM states**:

```
PTW_IDLE → PTW_L1_REQ → PTW_L1_WAIT → PTW_L1_CHECK
                                           │
                              ┌─────────────┤
                              │ (leaf at L1) │ (non-leaf)
                              ▼              ▼
                          PTW_DONE      PTW_L0_REQ → PTW_L0_WAIT → PTW_L0_CHECK
                                                                        │
                                                                        ▼
                                                                    PTW_DONE
```

**Walk algorithm** (identical to CPU MMU):

1. **L1_REQ**: Compute level-1 PTE address as
   `{pt_root_ppn, 12'b0} + {vpn1, 2'b0}`. Issue memory read request.
2. **L1_WAIT**: Wait for memory response (`mem_rd_resp_valid`).
3. **L1_CHECK**: Examine the PTE:
   - V=0: fault (CAUSE_PTE_INVALID)
   - Leaf (R|W|X != 0): superpage. Check PPN[0] alignment. Check permissions.
   - Non-leaf (R=W=X=0): proceed to L0.
   - W=1, R=0: always invalid per Sv32 spec.
4. **L0_REQ**: Compute level-0 PTE address as
   `{pte_ppn, 12'b0} + {vpn0, 2'b0}`. Issue memory read.
5. **L0_WAIT**: Wait for memory response.
6. **L0_CHECK**: Must be a leaf. Apply same validity and permission checks.
7. **PTW_DONE**: Output result (translated PPN and permissions, or fault cause).

**Permission checking during walk**: The PTW checks the leaf PTE's R and W bits
against the transaction type. If the transaction is a read and R=0, the fault
cause is `CAUSE_READ_DENIED`. If the transaction is a write and W=0, the fault
cause is `CAUSE_WRITE_DENIED`. If the PTE has W=1 but R=0, this is an invalid
encoding and causes a fault.

**Memory interface**: The PTW uses a simple valid/ready request/response port.
The core FSM ensures that this port is not shared concurrently — device context
fetches and PTW walks are mutually exclusive because the core serialises them.

**A/D bit handling**: The PTW does **not** update the Accessed (A) and Dirty
(D) bits in page table entries. Updating these bits would require memory write
operations during the walk, significantly complicating the FSM and the AXI
master arbitration (the PTW would need write access, not just read). For the
base implementation, testbenches pre-set A=1 and D=1 in all PTEs. This is a
documented limitation.

**Memory error handling**: If the AXI master returns a bus error during a PTE
read (`mem_rd_error` asserted), the PTW produces a `CAUSE_PTW_ACCESS_FAULT`
fault. This covers scenarios such as reading from unmapped physical memory.

### 5.6 `io_permission_checker.sv` — Permission Checker

**Purpose**: Validates device-level permissions from the device context before
initiating a page table walk. This is a purely combinational module.

**Logic**:

- `ctx.en == 0`: Device translation is disabled. Fault with
  `CAUSE_CTX_INVALID`.
- `ctx.en == 1` and `is_read == 1` and `ctx.rp == 0`: Device is not permitted
  to read. Fault with `CAUSE_CTX_READ_DENIED`.
- `ctx.en == 1` and `is_write == 1` and `ctx.wp == 0`: Device is not permitted
  to write. Fault with `CAUSE_CTX_WRITE_DENIED`.
- `ctx.mode == MODE_BARE`: No translation needed (passthrough).
- `ctx.mode == MODE_SV32`: Translation required.
- `ctx.mode` is any other value: Invalid mode. Fault with `CAUSE_CTX_INVALID`.

**Design decision — combinational vs registered**: The permission checker is
combinational because its inputs (device context fields, transaction type) are
stable for the duration of the core FSM's DC_CHECK state. No pipeline register
is needed. This reduces latency by one cycle compared to a registered design.

**Two-level permission model**: Device permissions are checked at two levels:

1. **Context level** (this module): Coarse-grained per-device R/W permissions.
   A device can be completely barred from reading or writing memory.
2. **PTE level** (in the PTW): Fine-grained per-page R/W permissions. Even
   if the context permits reads, a specific page's PTE may deny read access.

Both levels must pass for a translation to succeed.

### 5.7 `fault_handler.sv` — Fault Queue Manager

**Purpose**: Manages the register-based circular fault queue. Accepts fault
records from the core and stores them in internal registers for software to
read.

**Microarchitecture**:

- Circular buffer of `FAULT_QUEUE_DEPTH` (default 16) fault records, stored
  in flip-flops (not memory).
- **Head pointer** (read index): Incremented by software via register write.
  Points to the next record for software to read.
- **Tail pointer** (write index): Incremented by hardware when a new fault
  is recorded. Points to the next slot for hardware to write.
- **Full condition**: `(tail + 1) % DEPTH == head`. When full, `fault_ready`
  is deasserted, causing the core to stall until software drains the queue.
- **Empty condition**: `tail == head`. No pending faults.
- **`fault_pending`**: Asserted when `tail != head`.

**Handshake**: The core presents a fault record on `fault_valid` and waits for
`fault_ready`. If the queue is full, `fault_ready` stays low, and the core's
FSM remains in the FAULT state until software reads and acknowledges at least
one record.

### 5.8 `iommu_reg_file.sv` — Memory-Mapped Registers

**Purpose**: Provides the CPU-facing configuration and status interface. The
CPU reads and writes IOMMU registers via a simple valid/ready bus (not full
AXI — the register file has a simplified interface; the AXI wrapper or SoC
interconnect translates).

**Register map** (256-byte region, all 32-bit):

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | IOMMU_CAP | RO | Capability register |
| 0x04 | IOMMU_CTRL | RW | Control (enable, fault IRQ enable) |
| 0x08 | IOMMU_STATUS | R/W1C | Status (fault pending — write 1 to clear) |
| 0x0C | DCT_BASE | RW | Device context table base PPN |
| 0x10 | FQ_BASE | RW | Fault queue base PPN (reserved for stretch) |
| 0x14 | FQ_HEAD | RO | Fault queue head pointer |
| 0x18 | FQ_TAIL | RO | Fault queue tail pointer |
| 0x1C | FQ_HEAD_INC | WO | Increment head pointer |
| 0x20 | FQ_SIZE_LOG2 | RW | Log2 of fault queue depth |
| 0x24 | IOTLB_INV | WO | IOTLB invalidation trigger |
| 0x28 | DC_INV | WO | DC cache invalidation trigger |
| 0x2C | PERF_IOTLB_HIT | RO | IOTLB hit counter |
| 0x30 | PERF_IOTLB_MISS | RO | IOTLB miss counter |
| 0x34 | PERF_FAULT_CNT | RO | Total fault counter |
| 0x38 | FQ_READ_DATA_LO | RO | Fault record at head — low 32 bits |
| 0x3C | FQ_READ_DATA_HI | RO | Fault record at head — high 32 bits |

**Implementation details**:

- Single-cycle read/write with no wait states. `reg_wr_ready` and
  `reg_rd_ready` are always asserted.
- Write to IOTLB_INV pulses `iotlb_inv_valid` for one cycle. The device ID
  and all-flag are extracted from the write data.
- Write to DC_INV similarly pulses `dc_inv_valid`.
- Write to FQ_HEAD_INC pulses `head_inc` to the fault handler.
- Performance counters increment on pulse inputs from the core/IOTLB.
- IRQ output: `irq_fault = fault_pending & fault_irq_en`.

### 5.9 `iommu_core.sv` — Central Datapath

**Purpose**: Orchestrates the full translation pipeline. Instantiates and
connects the IOTLB, device context cache, PTW, permission checker, and fault
handler. Implements the core FSM that processes one transaction at a time.

**Core FSM states**:

```
CORE_IDLE
  │
  ├── (IOMMU disabled) ──→ CORE_BYPASS ──→ CORE_DONE
  │
  └── (IOMMU enabled) ──→ CORE_DC_LOOKUP
                               │
                    ┌──────────┤
                    │ (hit)    │ (miss)
                    ▼          ▼
              CORE_DC_CHECK  CORE_DC_FETCH_REQ ──→ CORE_DC_FETCH_WAIT_W0
                    │              ──→ CORE_DC_FETCH_REQ_W1
                    │              ──→ CORE_DC_FETCH_WAIT_W1
                    │              ──→ CORE_DC_CHECK
                    │
         ┌──────────┼──────────┐
         │ (fault)  │ (bare)   │ (sv32)
         ▼          ▼          ▼
    CORE_FAULT  CORE_DONE  CORE_IOTLB_LOOKUP
                               │
                    ┌──────────┤
                    │ (hit)    │ (miss)
                    ▼          ▼
            CORE_TRANSLATE  CORE_PTW_WALK ──→ CORE_PTW_WAIT
                    │              │
                    │              ├── (fault) ──→ CORE_FAULT
                    │              └── (done) ──→ CORE_TRANSLATE
                    │
                    ▼
               CORE_DONE ──→ CORE_IDLE
```

**Memory read arbitration**: The core has a single memory read port shared
between:
- Device context fetches (2 reads per miss: word 0 and word 1)
- Page table walks (up to 2 reads: L1 PTE and L0 PTE)

These are never concurrent because the FSM serialises them: DC fetch happens
before the PTW walk, and the PTW walk happens only after the DC check passes.

**Physical address computation**:
- Standard 4 KB page: `{ppn[21:0], vaddr[11:0]}`
- Superpage 4 MB: `{ppn[21:10], vaddr[21:0]}`

### 5.10 `iommu_axi_wrapper.sv` — Top-Level AXI Wrapper

**Purpose**: The true top-level module instantiated by the SoC. Wraps the core,
register file, and fault handler. Provides AXI4 slave (device side) and AXI4
master (memory side) interfaces.

**AXI slave transaction handling**:

1. Accept address phase (AR or AW channel) into a holding register
2. Deassert ready to stall further transactions (one at a time)
3. For writes, accept the W channel data into a buffer
4. Extract device ID from the AXI ID field
5. Present the transaction to `iommu_core`
6. Wait for translation result
7. On success: forward to AXI master with translated address
8. On fault: return SLVERR to the device
9. Re-assert ready for the next transaction

**AXI master port sharing**: The master port is time-multiplexed between:
- Core memory reads (PTW and DC fetch) — via the core's `mem_rd_*` interface
- Device transaction forwarding (post-translation)

These never overlap because translation completes before forwarding begins.

**Simplified AXI constraints**:
- Single-beat transfers only (`awlen = 0`, `arlen = 0`)
- Fixed size = 4 bytes (`awsize/arsize = 3'b010`)
- INCR burst type only
- One outstanding transaction at a time

---

## 6. AXI Protocol Handling

### 6.1 AXI4 Protocol Overview

AXI4 (Advanced eXtensible Interface) is an ARM AMBA bus protocol widely used in
SoC interconnects. It defines five independent channels:

- **Write address (AW)**: Master sends write address and control signals
- **Write data (W)**: Master sends write data and strobes
- **Write response (B)**: Slave sends write acknowledgement
- **Read address (AR)**: Master sends read address and control signals
- **Read data (R)**: Slave sends read data and response

Each channel uses a valid/ready handshake. A transfer occurs when both valid
and ready are high on the rising clock edge.

### 6.2 Device-Side AXI Slave

The IOMMU's AXI slave port accepts DMA transactions from devices. The
implementation handles each transaction sequentially:

**Read transaction flow**:
1. Device drives AR channel (ARVALID, ARADDR, ARID, etc.)
2. IOMMU accepts with ARREADY, latches address and ID
3. IOMMU translates the address (may take many cycles for PTW)
4. If translation succeeds: issue translated read on master port, relay data
   back on R channel
5. If translation fails: respond with RRESP = SLVERR (2'b10)

**Write transaction flow**:
1. Device drives AW channel and W channel
2. IOMMU accepts both, latches address, ID, data, and strobes
3. IOMMU translates the address
4. If translation succeeds: issue translated write on master port, relay
   response back on B channel
5. If translation fails: respond with BRESP = SLVERR (2'b10)

### 6.3 Memory-Side AXI Master

The IOMMU's AXI master port issues transactions to the memory system:

- **Forwarded device transactions**: After successful translation, the device's
  read or write is issued with the translated physical address.
- **PTW reads**: During page table walks, the PTW requests PTE reads through
  the master port.
- **DC fetches**: Device context cache misses trigger reads through the master
  port.

The master port is managed by a state machine in the AXI wrapper that
serialises all three types of access. The core FSM guarantees that PTW reads
and DC fetches complete before device forwarding begins, so no concurrent
arbitration is needed.

### 6.4 Design Trade-offs in AXI Handling

**Single-beat only**: Supporting AXI burst transfers would require buffering
multiple beats, tracking burst progress, and handling address generation for
INCR/WRAP/FIXED burst types. For the base implementation, restricting to
single-beat transfers (`AWLEN=0`, `ARLEN=0`) dramatically simplifies the
wrapper logic. Burst support is a natural extension.

**One outstanding transaction**: Allowing multiple outstanding transactions
would require a reorder buffer or tagged tracking structure to match responses
to requests. The single-outstanding-transaction constraint means the wrapper
needs only one holding register for the in-flight transaction.

**Device ID encoding**: The device ID is extracted from the lower bits of the
AXI ID field. This is a simplification — in a real SoC, a separate lookup
table or source ID decoder might map AXI master IDs to device IDs. The current
encoding is simple and sufficient for verification.

---

## 7. Fault Queue Design: Register-Based vs Memory-Resident

### 7.1 The Design Choice

The RISC-V IOMMU specification defines a memory-resident fault queue: a
circular buffer in DRAM that the IOMMU writes fault records to and software
reads from. This project instead uses a register-based fault queue where fault
records are stored in flip-flops inside the IOMMU.

### 7.2 Rationale for Register-Based Queue

**Simplified AXI master arbitration**: The primary motivation is avoiding the
need for the fault handler to issue memory writes on the AXI master port.
With a memory-resident queue, the fault handler would need to write 64-bit
fault records (two 32-bit AXI writes) to DRAM. This creates a three-way
arbitration problem on the AXI master port:

1. PTW reads (during page table walks)
2. DC fetches (during device context cache misses)
3. Fault record writes (on translation faults)

Arbitrating three sources, especially when a fault may be generated during a
PTW walk (which is itself using the master port for reads), creates complex
FSM interactions. Can the fault handler interrupt a PTW walk to write its
record? Must it wait? What if the PTW generates a fault while the fault handler
is still writing the previous fault?

The register-based queue sidesteps all of these issues. Fault records are
written to internal registers in a single cycle. No AXI master access is
needed.

**Deterministic fault recording**: With a register-based queue, fault recording
is instantaneous (one clock cycle). With a memory-resident queue, fault
recording takes multiple cycles (AXI write address phase + data phase +
response phase), during which the core may need to stall.

**Predictable latency**: The core FSM can transition from FAULT to DONE in a
fixed number of cycles because the register write is always available (unless
the queue is full). With a memory-resident queue, the latency depends on memory
system response time.

### 7.3 Trade-offs

**Area cost**: Storing 16 fault records x 64 bits = 1024 flip-flops. For a
16-entry queue, this is modest. For larger queues (256+ entries), the flip-flop
cost becomes prohibitive, and a memory-resident queue would be essential.

**Limited capacity**: The register-based queue is limited to `FAULT_QUEUE_DEPTH`
entries (default 16). If software does not drain the queue fast enough, the
queue fills, and the core must stall on subsequent faults. A memory-resident
queue could be arbitrarily large (limited only by DRAM).

**Software interface**: Software reads fault records via dedicated registers
(`FQ_READ_DATA_LO` and `FQ_READ_DATA_HI`), which return the record at the
head pointer. This is different from the memory-resident model where software
directly reads DRAM. The register-based model is actually simpler for software
— no DMA buffer management required.

### 7.4 Migration Path

The `FQ_BASE` register is reserved in the register map. A future implementation
could add a memory-resident queue mode, selected by a control bit, while
retaining the register-based queue as a fallback. The `FQ_BASE` register would
then specify the physical address of the DRAM-resident ring buffer.

---

## 8. IOTLB Design

### 8.1 Organisation

The IOTLB is a fully-associative cache with 16 entries (configurable via
`IOTLB_DEPTH`). Each entry stores:

| Field | Width | Description |
|-------|-------|-------------|
| `valid` | 1 | Entry validity |
| `device_id` | 8 | Owning device ID |
| `vpn1` | 10 | Virtual page number level 1 |
| `vpn0` | 10 | Virtual page number level 0 |
| `ppn` | 22 | Physical page number |
| `perm_r` | 1 | Read permission |
| `perm_w` | 1 | Write permission |
| `is_superpage` | 1 | Superpage flag |
| **Total** | **54** | Per entry |

Total IOTLB storage: 16 x 54 = 864 bits (plus LRU tracker).

### 8.2 Lookup Mechanism

Lookup is fully combinational. On `lookup_valid`, all entries are compared in
parallel:

```
For each entry i (0..DEPTH-1):
  if entry[i].valid:
    if entry[i].is_superpage:
      match = (entry[i].device_id == lookup_device_id) &&
              (entry[i].vpn1 == lookup_vpn1)
    else:
      match = (entry[i].device_id == lookup_device_id) &&
              (entry[i].vpn1 == lookup_vpn1) &&
              (entry[i].vpn0 == lookup_vpn0)
```

If any entry matches, `lookup_hit` is asserted and the entry's PPN and
permissions are output. If no entry matches, `lookup_hit` is deasserted
(`lookup_miss` is implied).

The combinational lookup means the hit/miss result is available in the same
cycle as the lookup request, enabling the core FSM to make immediate decisions
without waiting.

### 8.3 Superpage Handling

Sv32 supports 4 MB superpages (leaf PTE at level 1). The IOTLB handles
superpages by:

1. **Storage**: Setting `is_superpage = 1` in the entry. The `vpn0` field is
   still stored but is not used during lookup.
2. **Lookup**: Superpage entries match on `{device_id, vpn1}` only, ignoring
   `vpn0`. This means a single superpage entry covers the entire 4 MB region.
3. **Address computation**: The core computes the physical address differently
   for superpages: `{ppn[21:10], vaddr[21:0]}` instead of
   `{ppn[21:0], vaddr[11:0]}`.

### 8.4 Replacement Policy

The IOTLB uses pseudo-LRU replacement via the `lru_tracker` module. The LRU
tracker is updated on every lookup hit (`access_valid = lookup_hit`). On
refill, the entry at `lru_idx` is overwritten.

### 8.5 Invalidation

Two invalidation modes:

1. **By device ID**: Clears all entries matching a specific device ID. Used
   when a device's page table is modified.
2. **Global**: Clears all entries. Used when the IOMMU is reconfigured.

Invalidation is triggered by register writes to `IOTLB_INV`. The invalidation
takes effect on the next clock edge (single-cycle operation on the register
array).

---

## 9. Device Context Cache Design

### 9.1 Purpose and Structure

The device context cache is a small fully-associative cache that stores
device context table entries fetched from DRAM. Each entry is the full 64-bit
`device_context_t` struct:

| Field | Width | Description |
|-------|-------|-------------|
| `en` | 1 | Translation enable |
| `rp` | 1 | Read permission |
| `wp` | 1 | Write permission |
| `fp` | 1 | Fault policy |
| `mode` | 4 | Translation mode |
| `rsv` | 2 | Reserved |
| `pt_root_ppn` | 22 | Root page table PPN |
| `reserved_w1` | 32 | Reserved (for two-stage) |
| **Total** | **64** | Per context |

With an 8-bit device ID tag, each cache entry is 72 bits. Total storage:
8 x 72 = 576 bits.

### 9.2 Cache Miss Handling

On a DC cache miss, the core FSM fetches the device context from DRAM:

1. Compute entry address: `{dct_base_ppn, 12'b0} + (device_id * 8)`
2. Read word 0 (lower 32 bits) via AXI master
3. Read word 1 (upper 32 bits) via AXI master
4. Assemble `device_context_t` and refill the cache

This requires two AXI read transactions (the context is 64 bits but the AXI
data bus is 32 bits wide).

### 9.3 Coherency

The DC cache does not implement hardware coherency with DRAM. If software
modifies a device context table entry in memory, it must explicitly invalidate
the DC cache entry via the `DC_INV` register. This is analogous to the
software-managed TLB coherency model used throughout RISC-V.

---

## 10. Page Table Walker Design

### 10.1 Sv32 Page Table Structure

Sv32 uses a two-level page table:

```
Level 1 (root):  1024 PTEs x 4 bytes = 4 KB page table
Level 0:         1024 PTEs x 4 bytes = 4 KB page table
```

A 32-bit virtual address is decomposed as:

```
┌──────────┬──────────┬──────────────┐
│ VPN[1]   │ VPN[0]   │ Page Offset  │
│ (10 bits)│ (10 bits)│ (12 bits)    │
└──────────┴──────────┴──────────────┘
```

VPN[1] indexes into the root page table. If the entry is a non-leaf pointer,
VPN[0] indexes into the second-level page table. If the entry at level 1 is a
leaf, the translation covers a 4 MB superpage.

### 10.2 PTE Format

```
┌────────────┬────────────┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
│  PPN[1]    │  PPN[0]    │RS│RS│ D│ A│ G│ U│ X│ W│ R│ V│
│  (12 bits) │  (10 bits) │W │V │  │  │  │  │  │  │  │  │
└────────────┴────────────┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
 31        20 19        10  9  8  7  6  5  4  3  2  1  0
```

**Classification rules**:
- V=0: Invalid PTE
- V=1, R=0, W=0, X=0: Non-leaf (pointer to next-level table)
- V=1, R|W|X != 0: Leaf (translation mapping)
- V=1, W=1, R=0: Always invalid encoding

### 10.3 Walk Latency

Best case (IOTLB hit): 1 cycle (combinational lookup)
L1 leaf (superpage): 2 cycles (memory read) + FSM overhead
Full two-level walk: 4 cycles (two memory reads) + FSM overhead

The actual wall-clock time depends on AXI master latency to memory. Each memory
read takes at minimum 2 cycles (address phase + data phase) but may take more
if the memory system has wait states.

### 10.4 Error Handling

The PTW handles several error conditions:

1. **Invalid PTE** (V=0): `CAUSE_PTE_INVALID`
2. **Misaligned superpage**: Level-1 leaf with PPN[0] != 0. Per the Sv32 spec,
   the unused PPN bits must be zero for a properly aligned superpage.
   `CAUSE_PTE_MISALIGNED`
3. **Read permission denied**: Leaf PTE R=0 on a read transaction.
   `CAUSE_READ_DENIED`
4. **Write permission denied**: Leaf PTE W=0 (or D=0) on a write transaction.
   `CAUSE_WRITE_DENIED`
5. **Invalid PTE encoding**: W=1, R=0. This is defined as invalid by the
   Sv32 spec. Treated as `CAUSE_PTE_INVALID`.
6. **Non-leaf at level 0**: A level-0 PTE that is non-leaf has no further
   levels to traverse. Treated as invalid.
7. **Memory error**: AXI bus error during PTE read.
   `CAUSE_PTW_ACCESS_FAULT`

---

## 11. Translation Pipeline and Core FSM

### 11.1 Pipeline Stages

The translation pipeline is fully sequential (one transaction at a time):

| Stage | Operation | Cycles (best case) |
|-------|-----------|-------------------|
| Accept | Latch AXI transaction | 1 |
| Bypass check | IOMMU enabled? | 1 |
| DC lookup | Device context cache query | 1 |
| DC fetch | Fetch context from DRAM (on miss) | 4+ |
| DC check | Permission check | 1 |
| IOTLB lookup | Translation cache query | 1 |
| PTW walk | Two-level page table walk (on miss) | 4+ |
| Translate | Compute physical address | 1 |
| Forward | Issue translated AXI transaction | 2+ |

**Best-case latency** (IOMMU enabled, DC hit, IOTLB hit):
Accept + Bypass + DC lookup + DC check + IOTLB lookup + Translate + Forward
= ~7 cycles + AXI forwarding overhead.

**Worst-case latency** (DC miss + IOTLB miss + two-level walk):
Adds ~8+ cycles for DC fetch and ~4+ cycles for PTW walk.

### 11.2 Stall Mechanism

When the IOMMU is translating a device transaction, it deasserts `ARREADY` and
`AWREADY` on the AXI slave port. This backpressures the device, preventing it
from issuing additional transactions. The device perceives this as normal AXI
flow control — no special error handling is needed on the device side.

### 11.3 Throughput Analysis

With a sequential pipeline (one transaction at a time), the throughput is:

- **IOTLB hit**: ~1 transaction per 7-10 cycles
- **IOTLB miss**: ~1 transaction per 15-25 cycles (depending on memory latency)

This is adequate for embedded SoCs with low-bandwidth DMA devices (e.g., UART
DMA, SPI DMA). For high-bandwidth devices (NIC, GPU), a pipelined IOMMU with
multiple outstanding translations would be needed.

---

## 12. Memory-Mapped Register Interface

### 12.1 Register Access Protocol

The register file uses a simple valid/ready handshake, not full AXI4-Lite.
This simplification keeps the register file compact and avoids nesting an
AXI4-Lite decoder inside the AXI wrapper. The SoC interconnect is responsible
for bridging CPU register accesses to this interface.

**Read path**: CPU asserts `reg_rd_valid` with `reg_rd_addr`. Register file
responds with `reg_rd_data` and `reg_rd_ready` (always asserted — single-cycle
reads).

**Write path**: CPU asserts `reg_wr_valid` with `reg_wr_addr` and `reg_wr_data`.
Register file applies the write and asserts `reg_wr_ready` (always asserted).

### 12.2 Special Register Behaviours

**Write-only registers** (IOTLB_INV, DC_INV, FQ_HEAD_INC): Writes to these
registers produce side effects (invalidation pulses, head pointer increment)
but do not store a value. Reading these addresses returns zero.

**Read-only registers** (IOMMU_CAP, FQ_HEAD, FQ_TAIL, performance counters,
FQ_READ_DATA): Writes to these addresses are silently ignored.

**W1C register** (IOMMU_STATUS): The `fault_pending` bit is set by hardware
and cleared by writing 1 to it. Writing 0 has no effect. This is the standard
"write-1-to-clear" pattern used in interrupt status registers.

### 12.3 Performance Counters

Three 32-bit performance counters:

- **PERF_IOTLB_HIT**: Incremented on every IOTLB hit. Wraps on overflow.
- **PERF_IOTLB_MISS**: Incremented on every IOTLB miss. Wraps on overflow.
- **PERF_FAULT_CNT**: Incremented on every fault recorded. Wraps on overflow.

Software can compute hit rate as `HIT / (HIT + MISS)` and use this to evaluate
page table layout effectiveness or IOTLB sizing.

### 12.4 Interrupt Generation

The IOMMU generates a single interrupt signal (`irq_fault`):

```
irq_fault = fault_pending & fault_irq_en
```

This is a level-triggered interrupt. It remains asserted as long as there are
unread fault records and the interrupt is enabled. Software clears the interrupt
by reading all fault records (advancing the head pointer until it equals the
tail pointer).

---

## 13. Verification Strategy

### 13.1 Bottom-Up Verification

The project follows a strict bottom-up verification approach: each module is
fully verified in isolation before being used as a component of a higher-level
module. This ensures that integration-level bugs are true integration issues,
not masked unit-level bugs.

**Verification order**:

1. `lru_tracker` — pure combinational/sequential logic, no dependencies
2. `iotlb` — depends on `lru_tracker`
3. `device_context_cache` — depends on `lru_tracker`
4. `io_ptw` — standalone FSM with memory interface
5. `io_permission_checker` — pure combinational logic
6. `fault_handler` — standalone circular buffer
7. `iommu_reg_file` — depends on `fault_handler`
8. `iommu_core` — integrates items 2-7
9. `iommu_axi_wrapper` — integrates `iommu_core` + `iommu_reg_file`

### 13.2 SystemVerilog Testbenches

Each module has a dedicated SV testbench following a consistent template:

- Task-based tests (`task automatic test_xxx()`)
- `[PASS]`/`[FAIL]` annotation for every test
- `$stop` on first failure (fail-fast)
- Final summary with pass/fail counts
- VCD dump for waveform debugging

**Test categories per module**:

| Category | Description | Example |
|----------|-------------|---------|
| Reset | Verify initial state after reset | All valid bits 0 |
| Functional | Core operation | Refill + lookup = hit |
| Boundary | Edge cases | Queue full, capacity eviction |
| Error | Fault conditions | Invalid PTE, permission denied |
| Performance | Counter verification | Hit/miss counters increment |
| Integration | Multi-step flows | DC miss → fetch → PTW → translate |

### 13.3 CocoTB Testbenches

CocoTB tests provide an independent verification vector using Python-based
stimulus generation. Each CocoTB test directory contains a Python test file
and a Makefile that invokes Icarus Verilog as the simulator.

CocoTB tests complement the SV tests by:
- Using different stimulus generation (Python random, loops)
- Testing from a different abstraction level
- Providing a cross-check against the SV testbench

### 13.4 Memory Model

The PTW and core testbenches include a simple memory model:

```systemverilog
logic [31:0] mem [0:1023];  // 1024 x 32-bit words (4 KB)
```

Page table entries and device context entries are pre-loaded into this memory
array before each test. The memory model responds to PTW read requests with
one-cycle latency, providing deterministic test behaviour.

### 13.5 AXI Testbench

The AXI wrapper testbench is the most complex, requiring:

- An **AXI master driver** (device side): Generates read/write transactions
  with specific addresses and IDs.
- An **AXI slave responder** (memory side): Responds to forwarded transactions
  and PTW reads with data from a memory model.
- A **register driver**: Configures the IOMMU via register writes and reads
  status/fault information.

These are implemented as SystemVerilog tasks (`axi_read`, `axi_write`,
`reg_write`, `reg_read`) that drive the appropriate channel signals and wait
for handshake completion.

### 13.6 Test Count Summary

| Module | SV Tests | CocoTB Tests | Total |
|--------|----------|--------------|-------|
| `lru_tracker` | 6 | 4 | 10 |
| `iotlb` | 10 | 6 | 16 |
| `device_context_cache` | 7 | 4 | 11 |
| `io_ptw` | 10 | 6 | 16 |
| `io_permission_checker` | 8 | 4 | 12 |
| `fault_handler` | 7 | 4 | 11 |
| `iommu_reg_file` | 9 | 5 | 14 |
| `iommu_core` | 10 | 6 | 16 |
| `iommu_axi_wrapper` | 8 | 6 | 14 |
| **Total** | **75** | **45** | **120** |

---

## 14. Performance Considerations

### 14.1 Critical Path Analysis

The longest combinational path in the design is the IOTLB lookup:

```
lookup_valid → CAM comparators (all DEPTH entries in parallel) →
  priority encoder (select matching entry) → mux (output PPN/permissions)
```

For 16 entries with 28-bit tags (8-bit device_id + 10-bit vpn1 + 10-bit vpn0),
this involves 16 parallel 28-bit comparators, a 16:1 priority encoder, and a
16:1 mux for the output fields. In a modern FPGA, this path should close at
100+ MHz. In ASIC (28nm), it would likely close at 500+ MHz.

The PTW FSM has no long combinational paths — each state involves at most an
address computation (addition) and a PTE field extraction (bit slicing).

### 14.2 Area Estimates

| Component | Storage (bits) | Approximate Area |
|-----------|---------------|------------------|
| IOTLB (16 entries x 54 bits) | 864 | Small — comparable to a 16-entry register file |
| DC cache (8 entries x 72 bits) | 576 | Smaller than IOTLB |
| Fault queue (16 entries x 64 bits) | 1024 | Comparable to IOTLB |
| LRU trackers (15 + 7 bits) | 22 | Negligible |
| Register file | ~384 | Small |
| FSM state registers | ~20 | Negligible |
| **Total flip-flop storage** | **~2870** | Modest for any FPGA |

The AXI wrapper and core FSM logic adds combinational area but no significant
storage. Overall, the IOMMU is a small design — less than 1% of a modern FPGA.

### 14.3 Throughput Bottlenecks

1. **Sequential translation**: The biggest throughput limiter. Only one
   transaction is in flight at a time. A high-bandwidth device (e.g., Gigabit
   Ethernet) would be limited to ~100-200 MB/s assuming 10-cycle translations.

2. **IOTLB miss penalty**: An IOTLB miss triggers a full PTW walk (4+ memory
   reads including DC fetch). This can take 10-20 cycles depending on memory
   latency.

3. **AXI forwarding overhead**: After translation, the device transaction must
   be forwarded through the AXI master port, adding at least 2 cycles per
   transaction.

### 14.4 Potential Optimisations

For higher throughput, the following optimisations could be applied:

1. **Pipelined translation**: Process multiple translations concurrently using
   a pipeline with hazard detection.
2. **Larger IOTLB**: Increasing to 32 or 64 entries reduces miss rate. Would
   need set-associative organisation for timing.
3. **PTW prefetch**: Speculatively walk page tables for addresses near recent
   misses.
4. **Write buffer**: Buffer translated writes and process them in the
   background while accepting the next transaction.
5. **Multiple outstanding AXI transactions**: Allow multiple in-flight master
   transactions with tag tracking.

---

## 15. Stretch Goal Analysis

### 15.1 Two-Stage Translation (Virtualisation)

**What it is**: Two-stage translation enables hardware-assisted I/O
virtualisation. Stage 1 translates the device virtual address (DVA) to a
guest physical address (GPA) using the guest OS's page table. Stage 2
translates the GPA to a host physical address (HPA) using the hypervisor's
page table.

**Why it matters**: Without two-stage translation, the hypervisor must
software-trap and emulate every device DMA access, imposing unacceptable
performance overhead. With two-stage translation, the device can be passed
through to the guest VM with near-native DMA performance while maintaining
memory isolation.

**Implementation requirements**:

1. **Device context extension**: The `reserved_w1` field (32 bits) in the
   device context would store the Stage-2 root page table PPN. A new mode
   value (e.g., `4'b0010` for Sv32 two-stage) would be added.

2. **Nested PTW**: The most complex change. During a Stage-1 walk, each PTE
   read address is itself a GPA that must be translated through Stage 2.
   This means:
   - Stage-1 L1 PTE address (GPA) → Stage-2 walk to get HPA → read PTE
   - Stage-1 L0 PTE address (GPA) → Stage-2 walk to get HPA → read PTE
   - Final GPA from Stage-1 → Stage-2 walk to get HPA

   Each Stage-2 walk is itself a two-level Sv32 walk, requiring up to 2
   memory reads. In the worst case, a two-stage translation requires:
   - 2 reads for Stage-2 walk of L1 PTE address
   - 1 read for Stage-1 L1 PTE
   - 2 reads for Stage-2 walk of L0 PTE address
   - 1 read for Stage-1 L0 PTE
   - 2 reads for Stage-2 walk of final GPA
   = **8 memory reads** in the worst case (vs 2 for single-stage).

3. **IOTLB changes**: The IOTLB would store the final HPA, so no changes
   are needed for cache hits. However, the refill path must supply the
   HPA from the two-stage walk.

4. **Fault reporting**: Faults during Stage-2 walks need different cause
   codes to distinguish them from Stage-1 faults, so software knows which
   page table to fix.

**Complexity assessment**: High. The nested walk significantly complicates
the PTW FSM. The PTW would need a sub-FSM (or a recursive invocation
mechanism) for Stage-2 walks during Stage-1 walks. The number of FSM states
roughly doubles. Testing also doubles in complexity because all single-stage
fault scenarios must be re-tested at both stages.

**Estimated effort**: 2-3x the current PTW complexity. ~500 additional lines
of RTL, ~20 additional SV tests, ~10 additional CocoTB tests.

### 15.2 Command Queue

**What it is**: A memory-resident ring buffer where software writes
invalidation and synchronisation commands. The IOMMU reads commands from the
queue and processes them. This replaces the simple register-based invalidation
mechanism.

**Why it matters**: In a high-performance system with frequent page table
updates, writing individual invalidation register commands is inefficient.
A command queue allows software to batch many invalidation commands and have
the IOMMU process them autonomously. It also enables fence commands that
ensure all prior invalidations have taken effect before proceeding.

**Command format** (32 bits):

| Field | Bits | Description |
|-------|------|-------------|
| opcode | 7:0 | Command type |
| device_id | 15:8 | Target device |
| reserved | 31:16 | Reserved |

**Opcodes**:
- `0x01`: Invalidate IOTLB by device ID
- `0x02`: Invalidate IOTLB entry by device ID + VPN
- `0x03`: Invalidate all IOTLB entries
- `0x04`: Invalidate device context cache by device ID
- `0xFF`: Fence — wait for all prior commands

**Implementation requirements**:

1. A command queue reader FSM that polls the command queue in memory via the
   AXI master port
2. Command queue base address and head/tail pointer registers
3. Arbitration of the AXI master port between the command reader, PTW, DC
   fetch, and device forwarding
4. Fence implementation (stall new translations until all invalidations
   complete)

**Complexity assessment**: Medium. The command reader itself is straightforward
(read 32-bit words from memory, decode opcode, trigger invalidation). The
main challenge is AXI master port arbitration — the command reader needs to
read from memory, but the PTW also reads from memory. A priority scheme is
needed:
- PTW has highest priority (translations in progress should complete quickly)
- Command reader has lower priority (can be delayed)
- The command reader must not starve (bounded latency guarantee)

**Estimated effort**: ~300 additional lines of RTL, ~10 additional tests.

### 15.3 MSI Remapping

**What it is**: Message Signaled Interrupts (MSIs) are delivered by writing
to special memory-mapped addresses (typically in the range `0xFEE0_xxxx`).
MSI remapping allows the IOMMU to intercept these writes and translate the
interrupt destination and vector according to an MSI page table, preventing
a device from injecting arbitrary interrupts.

**Why it matters**: Without MSI remapping, a compromised device could:
- Send interrupts to the wrong CPU core, disrupting performance
- Inject spurious interrupts to the wrong guest VM
- Overwhelm the system with interrupt storms

MSI remapping is essential for complete I/O virtualisation security.

**Implementation requirements**:

1. **MSI address detection**: The IOMMU must recognise writes to the MSI
   address range. This is typically a fixed address range comparison.

2. **MSI page table**: A separate page table that maps `{device_id, interrupt_index}`
   to `{destination_cpu, vector}`. The format is defined by the RISC-V
   IOMMU spec.

3. **MSI write rewriting**: Instead of forwarding the device's MSI write
   as-is, the IOMMU rewrites the destination address and data fields
   according to the MSI page table lookup.

4. **Integration with translation pipeline**: MSI writes bypass the normal
   address translation path and go through the MSI remapping path instead.
   The IOMMU must detect which path to use based on the target address.

**Complexity assessment**: Medium-high. The MSI page table introduces a
parallel translation mechanism. The main challenge is the address range
detection logic and the MSI-specific page table format, which differs from
the address translation page table.

**Estimated effort**: ~400 additional lines of RTL, ~15 additional tests.

### 15.4 ATS/PRI (Address Translation Services / Page Request Interface)

**What it is**: PCIe-defined protocols that allow devices to proactively
request address translations from the IOMMU (ATS) and to request that the
OS page in missing pages (PRI).

**ATS**: The device sends a Translation Request to the IOMMU. The IOMMU
performs the page table walk and returns a Translation Completion with the
translated address. The device caches the translation in its own ATC (Address
Translation Cache) and subsequently issues DMA with the translated address.
The IOMMU can then pass these "translated" transactions through without
re-translating.

**PRI**: When the IOMMU encounters a page fault during translation, instead
of immediately failing the transaction, it can send a Page Request to the
OS. The OS pages in the missing page, installs the PTE, and sends a Page
Response. The IOMMU then retries the translation. This enables demand-paged
DMA — devices can reference virtual addresses for pages not yet in physical
memory.

**Why it matters**: ATS reduces IOMMU overhead for devices that issue many
DMA transactions to the same addresses — the device's local ATC serves the
translation without IOMMU involvement. PRI enables shared virtual memory
(SVM) where devices and CPU processes share the same virtual address space,
including on-demand paging.

**Implementation requirements**:

1. **ATS**:
   - Translation request/completion protocol on a dedicated interface
   - Device-side ATC invalidation protocol (IOMMU must invalidate device ATCs
     when page tables change)
   - "Translated" transaction passthrough mode in the AXI wrapper
   - Trust model: the IOMMU must verify that a device's "translated" access
     is within the range previously granted by an ATS completion

2. **PRI**:
   - Page request/response protocol
   - Integration with OS page fault handler
   - Request queue in the IOMMU for pending page requests
   - Retry mechanism for deferred translations

**Complexity assessment**: Very high. ATS and PRI are complex protocols with
many edge cases (completion timeouts, request cancellation, invalidation
during pending requests). They also require changes to the OS kernel
(page fault handler, IOMMU driver) and device firmware/hardware.

**Estimated effort**: 1000+ additional lines of RTL, 30+ additional tests.
This would roughly double the complexity of the entire IOMMU.

### 15.5 Stretch Goal Priority

If extending the design, the recommended priority order is:

1. **Command queue** — Medium complexity, high value for software usability
2. **Two-stage translation** — High complexity, essential for virtualisation
3. **MSI remapping** — Medium-high complexity, essential for virtualisation security
4. **ATS/PRI** — Very high complexity, important for high-performance I/O

---

## 16. Limitations and Future Work

### 16.1 Current Limitations

1. **Single-stage translation only**: The IOMMU supports only DVA-to-HPA
   translation. Two-stage (DVA to GPA to HPA) translation for virtualisation
   is not implemented. See Section 15.1 for analysis.

2. **Single-beat AXI transfers**: Only single-beat (non-burst) AXI transfers
   are supported. Burst transfers (`AWLEN > 0`, `ARLEN > 0`) are not handled.
   This limits throughput for devices that naturally use burst DMA (e.g.,
   DMA engines, GPUs).

3. **PTW does not set A/D bits**: The Page Table Walker does not update the
   Accessed and Dirty bits in page table entries. Software (or the
   initialising testbench) must pre-set these bits. In a production IOMMU,
   A/D bit management is important for OS page replacement algorithms and
   copy-on-write.

4. **No command queue**: Invalidation is triggered by individual register
   writes. Batched or queued invalidation is not supported. See Section 15.2.

5. **No MSI remapping**: MSI writes from devices are not intercepted or
   remapped. See Section 15.3.

6. **No ATS/PRI**: Devices cannot proactively request translations or page-in
   operations. See Section 15.4.

7. **Sequential translation pipeline**: Only one device transaction is in
   flight at a time. This limits throughput for high-bandwidth devices.

8. **Register-based fault queue**: The fault queue is limited to
   `FAULT_QUEUE_DEPTH` entries in flip-flops. A memory-resident queue would
   be needed for production use. See Section 7.

9. **No burst support on AXI master**: PTW and DC fetch reads are single-beat.
   For a two-stage translation that reads multiple PTEs, burst reads could
   reduce latency.

10. **32-bit AXI data bus**: Limited to 4-byte transfers. A 64-bit or 128-bit
    data bus would double or quadruple effective bandwidth.

### 16.2 Future Work

**Near-term extensions** (low-medium complexity):

- Add AXI burst support for device transactions
- Implement A/D bit management in the PTW (requires memory write path)
- Add a wider AXI data bus option (64-bit)
- Implement a memory-resident fault queue mode

**Medium-term extensions** (medium-high complexity):

- Implement the command queue
- Add two-stage translation for virtualisation
- Add MSI remapping

**Long-term extensions** (high complexity):

- Implement ATS/PRI
- Add a pipelined translation engine with multiple outstanding translations
- Support multiple page sizes (4 KB, 2 MB, 1 GB with Sv39)
- Add hardware performance monitoring and debug interfaces

---

## 17. Conclusion

This RISC-V IOMMU design demonstrates the core architectural concepts of I/O
address translation: per-device page tables, translation caching (IOTLB),
hardware page table walking, fault recording, and AXI bus protocol translation.
The design reuses Sv32 page table structures from the CPU MMU, showing how
the same fundamental mechanisms apply to both processor-side and I/O-side
address translation.

The base implementation prioritises correctness and clarity over maximum
performance, making it suitable as both a functional hardware IP and an
educational reference. The sequential translation pipeline, register-based
fault queue, and single-beat AXI constraints keep the design tractable for
verification while demonstrating all essential IOMMU operations.

The stretch goal analysis (Section 15) shows that extending the design to
support virtualisation (two-stage translation), batched invalidation (command
queue), interrupt security (MSI remapping), and device-initiated translation
(ATS/PRI) is architecturally feasible but involves significant additional
complexity, particularly for two-stage nested walks and ATS/PRI protocols.

The 120-test verification suite (75 SV + 45 CocoTB) provides comprehensive
coverage across unit tests, integration tests, and AXI protocol tests,
following a strict bottom-up methodology that ensures each module is
independently verified before integration.
