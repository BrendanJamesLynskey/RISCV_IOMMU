# CLAUDE_CODE_INSTRUCTIONS_IOMMU.md

> **Repo**: `RISCV_IOMMU`
> **Local directory**: `~/Claude_sandbox/RISCV_IOMMU`
> **GitHub URL**: `https://github.com/BrendanJamesLynskey/RISCV_IOMMU`
> **Author line**: `// Brendan Lynskey 2025` (first line of every `.sv` and `.svh` file)
> **Simulator**: `iverilog -g2012` + `vvp`
> **CocoTB sim**: `SIM=icarus`

---

## 1. Project Overview

### What is an IOMMU?

An IOMMU (I/O Memory Management Unit) is the system-bus counterpart of the CPU-side MMU. While the CPU MMU translates virtual addresses issued by the processor, the IOMMU sits between DMA-capable I/O devices and main memory, translating device-issued addresses (device virtual addresses or guest physical addresses) into host physical addresses before the transaction reaches DRAM.

### Why it matters

Without an IOMMU, any DMA device can read or write any physical address — a single rogue or compromised device can corrupt kernel memory, exfiltrate secrets, or bypass all software isolation. The IOMMU provides:

- **Device isolation**: Each device can only access memory regions mapped in its own page table. A network card cannot touch GPU buffers; a USB controller cannot touch kernel text.
- **Virtualisation support**: A hypervisor gives a guest OS "pass-through" access to a physical device. The IOMMU translates guest-physical addresses to host-physical addresses transparently (two-stage translation), so the guest believes it has direct hardware access while the hypervisor retains memory isolation.
- **Shared virtual memory (SVM)**: Devices can share the same virtual address space as the CPU process that owns them, eliminating pinned-buffer copies and simplifying DMA programming.

### Relationship to the Sv32 MMU project

This project reuses the following from the existing CPU MMU (`RISCV_MMU`):

| Concept | CPU MMU | IOMMU (this project) |
|---|---|---|
| Page table format | Sv32 two-level | Sv32 two-level (identical) |
| PTE format | 32-bit, V/R/W/X/U/G/A/D bits | 32-bit, same format (U bit reinterpreted) |
| TLB | Fully-associative + LRU | IOTLB — same architecture, keyed by `{device_id, vpn}` |
| PTW FSM | L1_REQ → L1_WAIT → L1_CHECK → L0_REQ → ... | Identical FSM, triggered by IOTLB miss instead of CPU request |
| Permission check | R/W/X + U/S privilege | R/W/X (no U/S — device privilege from context) |
| Interface | CPU pipeline signals | AXI4 slave (device side) + AXI4 master (memory side) |
| Miss handling | Stall pipeline | Buffer AXI transaction, stall device with `ARREADY`/`AWREADY` deasserted |
| Fault delivery | Synchronous exception to CPU | Asynchronous — write fault record to memory queue, raise interrupt |
| Invalidation | `SFENCE.VMA` instruction | Command queue (software writes invalidation commands) |
| Indexing | ASID (Address Space ID) | Device ID |

**Key principle**: The IOTLB, PTW, and permission checker are architectural adaptations of the CPU MMU modules — same microarchitecture, different triggering and context.

---

## 2. Architecture Specification

### 2.1 Top-Level Parameters (in `iommu_pkg.sv`)

| Parameter | Default | Description |
|---|---|---|
| `PADDR_W` | 34 | Physical address width (Sv32: up to 34 bits) |
| `VADDR_W` | 32 | Virtual (device) address width |
| `PAGE_OFFSET_W` | 12 | 4 KB page offset |
| `VPN_W` | 10 | VPN field width (each level) |
| `PPN_W` | 22 | Physical page number width (34 − 12) |
| `PTE_W` | 32 | PTE width |
| `DEVICE_ID_W` | 8 | Device ID width (supports up to 256 devices) |
| `IOTLB_DEPTH` | 16 | Number of IOTLB entries |
| `DC_CACHE_DEPTH` | 8 | Number of device context cache entries |
| `AXI_DATA_W` | 32 | AXI data bus width |
| `AXI_ADDR_W` | 34 | AXI address bus width (= `PADDR_W`) |
| `AXI_ID_W` | 4 | AXI ID width |
| `AXI_STRB_W` | 4 | AXI write strobe width (`AXI_DATA_W / 8`) |
| `FAULT_QUEUE_DEPTH` | 16 | Fault queue depth (power of 2, register-based) |

### 2.2 Sv32 PTE Format (identical to CPU MMU)

```
Bit  31        20 19        10 9  8  7  6  5  4  3  2  1  0
    ┌────────────┬────────────┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐
    │  PPN[1]    │  PPN[0]    │RS│RS│ D│ A│ G│ U│ X│ W│ R│ V│
    │  (12 bits) │  (10 bits) │W │V │  │  │  │  │  │  │  │  │
    └────────────┴────────────┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┘
```

- **V** (bit 0): Valid
- **R** (bit 1): Read permission
- **W** (bit 2): Write permission
- **X** (bit 3): Execute permission (not used for DMA — treat as reserved in IOMMU context)
- **U** (bit 4): In IOMMU context, this bit is ignored (devices have no user/supervisor distinction). Alternatively, it can encode a device-specific permission if the device context enables it. **For base implementation: ignore U bit.**
- **G** (bit 5): Global — if set, translation applies to all device IDs (treat as a global mapping)
- **A** (bit 6): Accessed
- **D** (bit 7): Dirty
- **RSW** (bits 9:8): Reserved for software
- **PPN\[0\]** (bits 19:10): Physical page number, level 0
- **PPN\[1\]** (bits 31:20): Physical page number, level 1

**Non-leaf PTE**: V=1, R=0, W=0, X=0 → pointer to next-level page table.
**Leaf PTE**: V=1, at least one of R/W/X is set → translation mapping.
**Invalid combinations**: W=1,R=0 is always invalid. V=0 is invalid.

**Superpage**: If a leaf PTE is found at level 1, it is a 4 MB superpage. PPN\[0\] must be zero (aligned); if not, raise a page fault.

### 2.3 Device Context Table Entry Format

The device context table is an array in memory, indexed by device ID. Each entry is 64 bits (2 × 32-bit words), word-aligned.

**Device Context Table base address** is stored in an IOMMU register (`dct_base_ppn`). The address of entry `i` is:

```
entry_addr = {dct_base_ppn, 12'b0} + (device_id * 8)
```

**Entry format (64 bits, little-endian):**

```
Word 0 (bits 31:0):
Bit  31                      10  9   8   7     4  3    2    1    0
    ┌──────────────────────────┬───┬───┬────────┬────┬────┬────┬────┐
    │    pt_root_ppn (22 bits) │RSV│RSV│  mode  │ FP │ WP │ RP │ EN │
    └──────────────────────────┴───┴───┴────────┴────┴────┴────┴────┘

Word 1 (bits 63:32):
Bit  63                                                         32
    ┌──────────────────────────────────────────────────────────────┐
    │                     reserved (32 bits)                       │
    └──────────────────────────────────────────────────────────────┘
```

| Field | Bits | Width | Description |
|---|---|---|---|
| `EN` | 0 | 1 | Enable translation for this device. 0 = bypass (passthrough). |
| `RP` | 1 | 1 | Read permission — device is allowed to issue reads. |
| `WP` | 2 | 1 | Write permission — device is allowed to issue writes. |
| `FP` | 3 | 1 | Fault policy. 0 = block transaction on fault. 1 = discard silently (log but do not stall). |
| `mode` | 7:4 | 4 | Translation mode. `4'b0000` = bare/passthrough (no translation even if EN=1). `4'b0001` = Sv32 single-stage. Other values reserved. |
| `RSV` | 9:8 | 2 | Reserved, must be zero. |
| `pt_root_ppn` | 31:10 | 22 | Physical page number of root page table for this device. |
| `reserved` | 63:32 | 32 | Reserved for future (two-stage translation root PPN, etc.). |

**Defined as a packed struct in `iommu_pkg.sv`:**

```systemverilog
typedef struct packed {
    logic [31:0]            reserved_w1;    // Word 1 — reserved
    logic [PPN_W-1:0]       pt_root_ppn;    // [31:10] of word 0
    logic [1:0]             rsv;            // [9:8]
    logic [3:0]             mode;           // [7:4]
    logic                   fp;             // [3] fault policy
    logic                   wp;             // [2] write permission
    logic                   rp;             // [1] read permission
    logic                   en;             // [0] enable
} device_context_t;  // 64 bits total
```

### 2.4 Fault Record Format

Each fault record is 64 bits (2 × 32-bit words):

```
Word 0 (bits 31:0):
Bit  31                                    8  7        4  3    2  1    0
    ┌────────────────────────────────────────┬───────────┬────┬───┬────┐
    │            reserved (24 bits)          │ cause(4b) │ W  │ R │ VLD│
    └────────────────────────────────────────┴───────────┴────┴───┴────┘

Word 1 (bits 63:32):
Bit  63                                          40  39              32
    ┌──────────────────────────────────────────────┬──────────────────┐
    │          faulting_addr[31:8] (24 bits)        │ device_id (8b)  │
    └──────────────────────────────────────────────┴──────────────────┘
```

Wait — let me reorganise for clarity. 64 bits total:

```
Bit  63       56 55       32 31        8  7        4  3    2  1    0
    ┌──────────┬────────────┬────────────┬──────────┬────┬───┬────┐
    │device_id │  faulting_addr[31:8]    │ reserved │ cause  │ W  │ R │VLD│
    │ (8 bits) │      (24 bits)          │ (24 bits)│(4 bits)│    │   │   │
    └──────────┴────────────┴────────────┴──────────┴────┴───┴────┘
```

**Final, cleaner layout (64 bits, packed):**

| Field | Bits | Width | Description |
|---|---|---|---|
| `valid` | 0 | 1 | Record valid |
| `is_read` | 1 | 1 | Faulting access was a read |
| `is_write` | 2 | 1 | Faulting access was a write |
| `reserved0` | 3 | 1 | Reserved |
| `cause` | 7:4 | 4 | Fault cause code (see table below) |
| `device_id` | 15:8 | 8 | Faulting device ID |
| `reserved1` | 31:16 | 16 | Reserved |
| `faulting_addr` | 63:32 | 32 | Full 32-bit faulting virtual address |

**Fault cause codes:**

| Code | Name | Description |
|---|---|---|
| `4'h0` | `CAUSE_NONE` | No fault (invalid record) |
| `4'h1` | `CAUSE_PTE_INVALID` | PTE V bit is 0 |
| `4'h2` | `CAUSE_PTE_MISALIGNED` | Superpage with non-zero PPN\[0\] |
| `4'h3` | `CAUSE_READ_DENIED` | Leaf PTE R=0 on a read access |
| `4'h4` | `CAUSE_WRITE_DENIED` | Leaf PTE W=0 on a write access, or D=0 |
| `4'h5` | `CAUSE_CTX_INVALID` | Device context EN=0 or mode invalid |
| `4'h6` | `CAUSE_CTX_READ_DENIED` | Device context RP=0 on a read |
| `4'h7` | `CAUSE_CTX_WRITE_DENIED` | Device context WP=0 on a write |
| `4'h8` | `CAUSE_PTW_ACCESS_FAULT` | Memory error during page table walk |
| `4'hF` | `CAUSE_RESERVED` | Reserved |

**Defined as a packed struct in `iommu_pkg.sv`:**

```systemverilog
typedef struct packed {
    logic [VADDR_W-1:0]     faulting_addr;  // [63:32]
    logic [15:0]            reserved1;      // [31:16]
    logic [DEVICE_ID_W-1:0] device_id;      // [15:8]
    logic [3:0]             cause;          // [7:4]
    logic                   reserved0;      // [3]
    logic                   is_write;       // [2]
    logic                   is_read;        // [1]
    logic                   valid;          // [0]
} fault_record_t;  // 64 bits total
```

### 2.5 Memory-Mapped Register Interface

The IOMMU presents a memory-mapped register block to the CPU for configuration. The register file occupies a 256-byte region. All registers are 32 bits, accessed via a simple valid/ready bus (not full AXI — the register file has its own simplified interface; the AXI wrapper translates).

| Offset | Name | R/W | Reset | Description |
|---|---|---|---|---|
| `0x00` | `IOMMU_CAP` | RO | impl-defined | Capability register. Bit 0: Sv32 supported. Bit 1: two-stage supported (0 for base). Bits 7:4: max device ID width. |
| `0x04` | `IOMMU_CTRL` | RW | `0` | Control register. Bit 0: `enable` — global IOMMU enable. Bit 1: `fault_irq_en` — enable fault interrupt. Bits 31:2: reserved. |
| `0x08` | `IOMMU_STATUS` | R/W1C | `0` | Status register. Bit 0: `fault_pending` — at least one unread fault record. Write 1 to clear. |
| `0x0C` | `DCT_BASE` | RW | `0` | Device context table base PPN (bits 21:0 used, upper bits reserved). Physical address = `{DCT_BASE[21:0], 12'b0}`. |
| `0x10` | `FQ_BASE` | RW | `0` | Fault queue base address PPN. Physical address of the fault queue circular buffer in memory. |
| `0x14` | `FQ_HEAD` | RO | `0` | Fault queue head pointer (index of next record to be read by software). Incremented by software via `FQ_HEAD_INC`. |
| `0x18` | `FQ_TAIL` | RO | `0` | Fault queue tail pointer (index of next record to be written by hardware). |
| `0x1C` | `FQ_HEAD_INC` | WO | — | Write any value to increment the head pointer by 1. Software reads a fault record, then writes here to advance. |
| `0x20` | `FQ_SIZE_LOG2` | RW | `4` | Log2 of fault queue depth (e.g., 4 = 16 entries). Supported range: 2–8 (4–256 entries). |
| `0x24` | `IOTLB_INV` | WO | — | IOTLB invalidation register. Write triggers invalidation. Bits 7:0 = device ID. Bit 8 = `all` (invalidate all entries, ignore device_id). Bits 31:9 = reserved. |
| `0x28` | `DC_INV` | WO | — | Device context cache invalidation. Bits 7:0 = device ID. Bit 8 = `all`. |
| `0x2C` | `PERF_IOTLB_HIT` | RO | `0` | IOTLB hit counter (32-bit, wraps). |
| `0x30` | `PERF_IOTLB_MISS` | RO | `0` | IOTLB miss counter (32-bit, wraps). |
| `0x34` | `PERF_FAULT_CNT` | RO | `0` | Total faults recorded counter. |

**Register file port list (`iommu_reg_file.sv`):**

```systemverilog
module iommu_reg_file
    import iommu_pkg::*;
(
    input  logic                    clk,
    input  logic                    srst,

    // CPU-side register access (simple valid/ready)
    input  logic                    reg_wr_valid,
    output logic                    reg_wr_ready,
    input  logic [7:0]              reg_wr_addr,    // byte address within register block
    input  logic [31:0]             reg_wr_data,

    input  logic                    reg_rd_valid,
    output logic                    reg_rd_ready,
    input  logic [7:0]              reg_rd_addr,
    output logic [31:0]             reg_rd_data,

    // Outputs to IOMMU datapath
    output logic                    iommu_enable,
    output logic                    fault_irq_en,
    output logic [PPN_W-1:0]        dct_base_ppn,
    output logic [PPN_W-1:0]        fq_base_ppn,
    output logic [3:0]              fq_size_log2,

    // Fault queue interface (from fault_handler)
    input  logic                    fq_write_valid,
    output logic                    fq_write_ready,
    input  fault_record_t           fq_write_data,
    output logic                    fault_pending,

    // Fault queue read (for software — head/tail management)
    output logic [7:0]              fq_head,
    output logic [7:0]              fq_tail,

    // Invalidation outputs
    output logic                    iotlb_inv_valid,
    output logic [DEVICE_ID_W-1:0]  iotlb_inv_device_id,
    output logic                    iotlb_inv_all,
    output logic                    dc_inv_valid,
    output logic [DEVICE_ID_W-1:0]  dc_inv_device_id,
    output logic                    dc_inv_all,

    // Performance counter inputs
    input  logic                    perf_iotlb_hit,
    input  logic                    perf_iotlb_miss,
    input  logic                    perf_fault,

    // Interrupt output
    output logic                    irq_fault
);
```

**Note on fault queue implementation**: For the base implementation, the fault queue is **register-based** inside the IOMMU (a circular buffer of `FAULT_QUEUE_DEPTH` entries stored in flip-flops). This avoids the complexity of the PTW and fault handler sharing the AXI master port for memory-resident queues. The `FQ_BASE` register is reserved for the stretch goal (memory-resident fault queue). Head/tail pointers index into the internal register array.

### 2.6 Module Hierarchy

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

`iommu_axi_wrapper.sv` is the true top-level instantiated by the SoC. It wraps `iommu_core.sv` and handles AXI protocol.

### 2.7 Module Specifications

#### 2.7.1 `iommu_pkg.sv`

Contains all parameters (Section 2.1), type definitions, structs (`device_context_t`, `fault_record_t`), and fault cause code localparams.

```systemverilog
// Fault cause codes
localparam logic [3:0] CAUSE_NONE              = 4'h0;
localparam logic [3:0] CAUSE_PTE_INVALID       = 4'h1;
localparam logic [3:0] CAUSE_PTE_MISALIGNED    = 4'h2;
localparam logic [3:0] CAUSE_READ_DENIED       = 4'h3;
localparam logic [3:0] CAUSE_WRITE_DENIED      = 4'h4;
localparam logic [3:0] CAUSE_CTX_INVALID       = 4'h5;
localparam logic [3:0] CAUSE_CTX_READ_DENIED   = 4'h6;
localparam logic [3:0] CAUSE_CTX_WRITE_DENIED  = 4'h7;
localparam logic [3:0] CAUSE_PTW_ACCESS_FAULT  = 4'h8;

// Translation modes
localparam logic [3:0] MODE_BARE = 4'b0000;
localparam logic [3:0] MODE_SV32 = 4'b0001;
```

#### 2.7.2 `lru_tracker.sv`

Pseudo-LRU tracker for both IOTLB and device context cache. Parameterised by depth. Same implementation as the CPU MMU's LRU tracker.

```systemverilog
module lru_tracker #(
    parameter int DEPTH = 16
)(
    input  logic                    clk,
    input  logic                    srst,
    input  logic                    access_valid,
    input  logic [$clog2(DEPTH)-1:0] access_idx,
    output logic [$clog2(DEPTH)-1:0] lru_idx       // index of least-recently-used entry
);
```

**Implementation**: Tree-based pseudo-LRU using `DEPTH-1` bits. On each access, update the tree bits to point away from the accessed entry. `lru_idx` walks the tree to find the LRU entry.

#### 2.7.3 `iotlb.sv`

Fully-associative IOTLB, parameterised by depth. Keyed by `{device_id, vpn[1], vpn[0]}`. Stores `{ppn, perm_r, perm_w, is_superpage, valid}`.

```systemverilog
module iotlb
    import iommu_pkg::*;
#(
    parameter int DEPTH = IOTLB_DEPTH
)(
    input  logic                        clk,
    input  logic                        srst,

    // Lookup interface
    input  logic                        lookup_valid,
    output logic                        lookup_ready,
    input  logic [DEVICE_ID_W-1:0]      lookup_device_id,
    input  logic [VPN_W-1:0]            lookup_vpn1,
    input  logic [VPN_W-1:0]            lookup_vpn0,
    output logic                        lookup_hit,
    output logic [PPN_W-1:0]            lookup_ppn,
    output logic                        lookup_perm_r,
    output logic                        lookup_perm_w,
    output logic                        lookup_is_superpage,

    // Refill interface (from PTW after successful walk)
    input  logic                        refill_valid,
    input  logic [DEVICE_ID_W-1:0]      refill_device_id,
    input  logic [VPN_W-1:0]            refill_vpn1,
    input  logic [VPN_W-1:0]            refill_vpn0,
    input  logic [PPN_W-1:0]            refill_ppn,
    input  logic                        refill_perm_r,
    input  logic                        refill_perm_w,
    input  logic                        refill_is_superpage,

    // Invalidation
    input  logic                        inv_valid,
    input  logic [DEVICE_ID_W-1:0]      inv_device_id,
    input  logic                        inv_all,

    // Performance counters
    output logic                        perf_hit,
    output logic                        perf_miss
);
```

**Microarchitecture**:

- **Storage**: Array of `DEPTH` entries. Each entry: `{valid, device_id, vpn1, vpn0, ppn, perm_r, perm_w, is_superpage}`.
- **Lookup**: Combinational CAM match. For standard pages: match `{device_id, vpn1, vpn0}`. For superpages: match `{device_id, vpn1}` (vpn0 is don't-care). `lookup_hit` is asserted in the same cycle as `lookup_valid`. **Use `always @(*)` for the match logic** (reads submodule LRU output).
- **Refill**: Write to the LRU slot on the next clock edge. Update LRU tracker.
- **Invalidation**: `inv_all` clears all valid bits. Otherwise, clear entries matching `inv_device_id`.
- **LRU**: Instantiate `lru_tracker`. Update on every hit (access_valid = lookup_hit). Refill uses `lru_idx`.

#### 2.7.4 `device_context_cache.sv`

Small fully-associative cache for device context table entries fetched from memory.

```systemverilog
module device_context_cache
    import iommu_pkg::*;
#(
    parameter int DEPTH = DC_CACHE_DEPTH
)(
    input  logic                        clk,
    input  logic                        srst,

    // Lookup interface
    input  logic                        lookup_valid,
    output logic                        lookup_ready,
    input  logic [DEVICE_ID_W-1:0]      lookup_device_id,
    output logic                        lookup_hit,
    output device_context_t             lookup_ctx,

    // Refill interface (from memory read after cache miss)
    input  logic                        refill_valid,
    input  logic [DEVICE_ID_W-1:0]      refill_device_id,
    input  device_context_t             refill_ctx,

    // Invalidation
    input  logic                        inv_valid,
    input  logic [DEVICE_ID_W-1:0]      inv_device_id,
    input  logic                        inv_all
);
```

**Microarchitecture**: Same as IOTLB — fully-associative with LRU. Keyed by `device_id` only. Stores the full `device_context_t`. Instantiates its own `lru_tracker`.

#### 2.7.5 `io_ptw.sv`

IO Page Table Walker. Walks Sv32 two-level page tables. Triggered by IOTLB miss. Reads memory via a simple valid/ready request/response interface (the core or AXI wrapper arbitrates this with forwarded device transactions).

```systemverilog
module io_ptw
    import iommu_pkg::*;
(
    input  logic                        clk,
    input  logic                        srst,

    // Walk request (from iommu_core on IOTLB miss)
    input  logic                        walk_req_valid,
    output logic                        walk_req_ready,
    input  logic [DEVICE_ID_W-1:0]      walk_device_id,
    input  logic [VPN_W-1:0]            walk_vpn1,
    input  logic [VPN_W-1:0]            walk_vpn0,
    input  logic [PPN_W-1:0]            walk_pt_root_ppn,   // from device context
    input  logic                        walk_is_read,
    input  logic                        walk_is_write,

    // Walk result
    output logic                        walk_done,
    output logic                        walk_fault,
    output logic [3:0]                  walk_fault_cause,
    output logic [PPN_W-1:0]            walk_ppn,
    output logic                        walk_perm_r,
    output logic                        walk_perm_w,
    output logic                        walk_is_superpage,

    // Memory read interface (to AXI master arbiter)
    output logic                        mem_rd_req_valid,
    input  logic                        mem_rd_req_ready,
    output logic [PADDR_W-1:0]          mem_rd_addr,
    input  logic                        mem_rd_resp_valid,
    output logic                        mem_rd_resp_ready,
    input  logic [31:0]                 mem_rd_data,
    input  logic                        mem_rd_error
);
```

**FSM states:**

```systemverilog
typedef enum logic [2:0] {
    PTW_IDLE,
    PTW_L1_REQ,         // Issue memory read for level-1 PTE
    PTW_L1_WAIT,        // Wait for memory response
    PTW_L1_CHECK,       // Check level-1 PTE validity
    PTW_L0_REQ,         // Issue memory read for level-0 PTE (if non-leaf at L1)
    PTW_L0_WAIT,        // Wait for memory response
    PTW_L0_CHECK,       // Check level-0 PTE validity
    PTW_DONE            // Output result (hit or fault)
} ptw_state_t;
```

**Walk algorithm (identical to CPU MMU):**

1. **L1_REQ**: Compute level-1 PTE address = `{walk_pt_root_ppn, 12'b0} + (walk_vpn1 * 4)`. Issue memory read.
2. **L1_WAIT**: Wait for `mem_rd_resp_valid`.
3. **L1_CHECK**: Latch PTE. Check V bit. If V=0 → fault (`CAUSE_PTE_INVALID`). If leaf (R|W|X != 0): check alignment (if PPN\[0\] != 0 → `CAUSE_PTE_MISALIGNED`), check permissions → done (superpage). If non-leaf (R=W=X=0): proceed to L0.
4. **L0_REQ**: Compute level-0 PTE address = `{pte_ppn, 12'b0} + (walk_vpn0 * 4)`. Issue memory read.
5. **L0_WAIT**: Wait for `mem_rd_resp_valid`.
6. **L0_CHECK**: Latch PTE. Check V bit. If V=0 → fault. Must be leaf (non-leaf at level 0 is invalid → fault). Check permissions → done.
7. **PTW_DONE**: Assert `walk_done`. If fault, assert `walk_fault` + `walk_fault_cause`. Otherwise, output translated PPN and permissions. Return to IDLE when acknowledged.

**Permission checking during walk**: The PTW checks R/W permission bits on the leaf PTE against `walk_is_read` and `walk_is_write`. If `walk_is_write` and PTE W=0 → `CAUSE_WRITE_DENIED`. If `walk_is_read` and PTE R=0 → `CAUSE_READ_DENIED`. If `mem_rd_error` during any read → `CAUSE_PTW_ACCESS_FAULT`.

**Note on A/D bits**: For the base implementation, the PTW does **not** set A/D bits (that would require a memory write during the walk, adding complexity). The testbench must pre-set A=1, D=1 in PTEs. Document this limitation.

#### 2.7.6 `io_permission_checker.sv`

Checks device context permissions **before** initiating a page table walk. This is a combinational module — no FSM.

```systemverilog
module io_permission_checker
    import iommu_pkg::*;
(
    input  device_context_t             ctx,
    input  logic                        is_read,
    input  logic                        is_write,

    output logic                        ctx_valid,          // context is usable
    output logic                        ctx_fault,          // context-level fault
    output logic [3:0]                  ctx_fault_cause,
    output logic                        needs_translation   // true if mode != BARE
);
```

**Logic:**

- If `ctx.en == 0`: `ctx_fault = 1`, `ctx_fault_cause = CAUSE_CTX_INVALID`.
- If `ctx.en == 1` and `is_read == 1` and `ctx.rp == 0`: `ctx_fault = 1`, `ctx_fault_cause = CAUSE_CTX_READ_DENIED`.
- If `ctx.en == 1` and `is_write == 1` and `ctx.wp == 0`: `ctx_fault = 1`, `ctx_fault_cause = CAUSE_CTX_WRITE_DENIED`.
- If `ctx.mode == MODE_BARE`: `needs_translation = 0` (passthrough).
- If `ctx.mode == MODE_SV32`: `needs_translation = 1`.
- If `ctx.mode` is not `MODE_BARE` and not `MODE_SV32`: `ctx_fault = 1`, `ctx_fault_cause = CAUSE_CTX_INVALID`.

#### 2.7.7 `fault_handler.sv`

Manages the register-based fault queue. Accepts fault records from the datapath and stores them in a circular buffer.

```systemverilog
module fault_handler
    import iommu_pkg::*;
#(
    parameter int DEPTH = FAULT_QUEUE_DEPTH
)(
    input  logic                        clk,
    input  logic                        srst,

    // Fault record input (from iommu_core)
    input  logic                        fault_valid,
    output logic                        fault_ready,
    input  fault_record_t               fault_record,

    // Queue management (from/to register file)
    input  logic                        head_inc,       // software increments head
    output logic [$clog2(DEPTH)-1:0]    head,
    output logic [$clog2(DEPTH)-1:0]    tail,
    output logic                        fault_pending,  // tail != head
    output logic                        queue_full,

    // Performance
    output logic                        perf_fault
);
```

**Microarchitecture:**

- Circular buffer of `DEPTH` fault records in registers.
- **Write** (hardware): On `fault_valid && fault_ready`, write `fault_record` at `tail`, increment `tail`. If queue is full (`(tail + 1) % DEPTH == head`), deassert `fault_ready` — the core must stall.
- **Read advance** (software): On `head_inc`, increment `head` by 1.
- `fault_pending = (tail != head)`.
- `queue_full = ((tail + 1) & (DEPTH-1)) == head`.
- The actual fault record data is not read through this module — software reads fault records via the register file (which maps the queue storage into the register address space at a fixed offset, or provides a `FQ_READ_DATA` register). **Simplification**: Add a `FQ_READ_DATA_LO` (offset `0x38`) and `FQ_READ_DATA_HI` (offset `0x3C`) read-only register in the register file that returns `queue[head]`.

#### 2.7.8 `iommu_reg_file.sv`

Memory-mapped register file. Port list in Section 2.5. Implementation:

- Simple address decode on `reg_wr_addr` / `reg_rd_addr`.
- Single-cycle read/write. `reg_wr_ready` and `reg_rd_ready` always asserted (no wait states).
- Write to `IOTLB_INV` pulses `iotlb_inv_valid` for one cycle.
- Write to `DC_INV` pulses `dc_inv_valid` for one cycle.
- Write to `FQ_HEAD_INC` pulses `head_inc` to fault_handler.
- `irq_fault = fault_pending & fault_irq_en`.
- Performance counters: increment on pulse inputs `perf_iotlb_hit`, `perf_iotlb_miss`, `perf_fault`.

#### 2.7.9 `iommu_core.sv`

The central datapath. Orchestrates the translation pipeline for a single device transaction.

```systemverilog
module iommu_core
    import iommu_pkg::*;
(
    input  logic                        clk,
    input  logic                        srst,

    // Transaction request (from AXI wrapper — one buffered transaction)
    input  logic                        txn_valid,
    output logic                        txn_ready,
    input  logic [DEVICE_ID_W-1:0]      txn_device_id,
    input  logic [VADDR_W-1:0]          txn_vaddr,
    input  logic                        txn_is_read,
    input  logic                        txn_is_write,

    // Translation result (to AXI wrapper)
    output logic                        txn_done,
    output logic                        txn_fault,
    output logic [3:0]                  txn_fault_cause,
    output logic [PADDR_W-1:0]          txn_paddr,       // translated physical address

    // IOMMU enable (from register file)
    input  logic                        iommu_enable,

    // Device context table base (from register file)
    input  logic [PPN_W-1:0]            dct_base_ppn,

    // Memory read interface (to AXI master arbiter — shared with PTW + DC fetch)
    output logic                        mem_rd_req_valid,
    input  logic                        mem_rd_req_ready,
    output logic [PADDR_W-1:0]          mem_rd_addr,
    input  logic                        mem_rd_resp_valid,
    output logic                        mem_rd_resp_ready,
    input  logic [31:0]                 mem_rd_data,
    input  logic                        mem_rd_error,

    // Fault output (to fault handler)
    output logic                        fault_valid,
    input  logic                        fault_ready,
    output fault_record_t               fault_record,

    // Invalidation inputs (from register file)
    input  logic                        iotlb_inv_valid,
    input  logic [DEVICE_ID_W-1:0]      iotlb_inv_device_id,
    input  logic                        iotlb_inv_all,
    input  logic                        dc_inv_valid,
    input  logic [DEVICE_ID_W-1:0]      dc_inv_device_id,
    input  logic                        dc_inv_all,

    // Performance counter outputs
    output logic                        perf_iotlb_hit,
    output logic                        perf_iotlb_miss,
    output logic                        perf_fault
);
```

**Core FSM states:**

```systemverilog
typedef enum logic [3:0] {
    CORE_IDLE,
    CORE_BYPASS,            // IOMMU disabled — pass through
    CORE_DC_LOOKUP,         // Look up device context in cache
    CORE_DC_FETCH_REQ,      // DC cache miss — fetch from memory (word 0)
    CORE_DC_FETCH_WAIT_W0,  // Wait for word 0 response
    CORE_DC_FETCH_REQ_W1,   // Fetch word 1
    CORE_DC_FETCH_WAIT_W1,  // Wait for word 1 response
    CORE_DC_CHECK,          // Check device context permissions
    CORE_IOTLB_LOOKUP,      // Look up in IOTLB
    CORE_PTW_WALK,          // IOTLB miss — trigger PTW
    CORE_PTW_WAIT,          // Wait for PTW completion
    CORE_TRANSLATE,         // Compute final physical address
    CORE_FAULT,             // Record fault
    CORE_DONE               // Signal completion to AXI wrapper
} core_state_t;
```

**Translation pipeline (sequential — one transaction at a time):**

1. **IDLE → BYPASS or DC_LOOKUP**: If `!iommu_enable`, go to BYPASS (output `txn_paddr = {2'b0, txn_vaddr}` zero-extended, `txn_done = 1`). Otherwise, go to DC_LOOKUP.
2. **DC_LOOKUP**: Query device context cache. If hit, go to DC_CHECK. If miss, go to DC_FETCH_REQ.
3. **DC_FETCH_REQ/WAIT_W0/REQ_W1/WAIT_W1**: Read two 32-bit words from memory at `{dct_base_ppn, 12'b0} + (txn_device_id * 8)`. Assemble `device_context_t`. Refill cache. Go to DC_CHECK.
4. **DC_CHECK**: Run `io_permission_checker` on the context. If `ctx_fault`, go to FAULT. If `!needs_translation` (bare mode), go to BYPASS equivalent (pass through). Otherwise, go to IOTLB_LOOKUP.
5. **IOTLB_LOOKUP**: Query IOTLB with `{txn_device_id, vpn1, vpn0}`. If hit, go to TRANSLATE. If miss, go to PTW_WALK.
6. **PTW_WALK/PTW_WAIT**: Trigger `io_ptw` with VPN and `pt_root_ppn` from device context. Wait for `walk_done`. If `walk_fault`, go to FAULT. Otherwise, refill IOTLB and go to TRANSLATE.
7. **TRANSLATE**: Compute `txn_paddr`:
   - Standard page: `{walk_ppn, txn_vaddr[PAGE_OFFSET_W-1:0]}`
   - Superpage (4 MB): `{walk_ppn[PPN_W-1:VPN_W], txn_vaddr[VPN_W+PAGE_OFFSET_W-1:0]}`
   Go to DONE.
8. **FAULT**: Assemble `fault_record_t`, assert `fault_valid`, wait for `fault_ready`. Set `txn_fault = 1`. Go to DONE.
9. **DONE**: Assert `txn_done` for one cycle. Return to IDLE.

**Memory read arbiter**: The core has a single memory read port. The PTW uses it during walks. The DC fetch uses it during context fetches. These are mutually exclusive (the core FSM serialises them). The AXI wrapper must not forward device transactions on the memory master while a PTW or DC fetch is in progress. The AXI wrapper handles this by gating forwarding during translation.

#### 2.7.10 `iommu_axi_wrapper.sv`

Top-level module. Wraps `iommu_core`, `iommu_reg_file`, and `fault_handler`. Provides AXI4 slave and AXI4 master interfaces.

```systemverilog
module iommu_axi_wrapper
    import iommu_pkg::*;
(
    input  logic                        clk,
    input  logic                        srst,

    // ==================== AXI4 Slave Interface (Device Side) ====================
    // Write address channel
    input  logic [AXI_ID_W-1:0]         s_axi_awid,
    input  logic [AXI_ADDR_W-1:0]       s_axi_awaddr,
    input  logic [7:0]                  s_axi_awlen,
    input  logic [2:0]                  s_axi_awsize,
    input  logic [1:0]                  s_axi_awburst,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,

    // Write data channel
    input  logic [AXI_DATA_W-1:0]       s_axi_wdata,
    input  logic [AXI_STRB_W-1:0]       s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,

    // Write response channel
    output logic [AXI_ID_W-1:0]         s_axi_bid,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    // Read address channel
    input  logic [AXI_ID_W-1:0]         s_axi_arid,
    input  logic [AXI_ADDR_W-1:0]       s_axi_araddr,
    input  logic [7:0]                  s_axi_arlen,
    input  logic [2:0]                  s_axi_arsize,
    input  logic [1:0]                  s_axi_arburst,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,

    // Read data channel
    output logic [AXI_ID_W-1:0]         s_axi_rid,
    output logic [AXI_DATA_W-1:0]       s_axi_rdata,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,

    // ==================== AXI4 Master Interface (Memory Side) ====================
    // Write address channel
    output logic [AXI_ID_W-1:0]         m_axi_awid,
    output logic [AXI_ADDR_W-1:0]       m_axi_awaddr,
    output logic [7:0]                  m_axi_awlen,
    output logic [2:0]                  m_axi_awsize,
    output logic [1:0]                  m_axi_awburst,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,

    // Write data channel
    output logic [AXI_DATA_W-1:0]       m_axi_wdata,
    output logic [AXI_STRB_W-1:0]       m_axi_wstrb,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,

    // Write response channel
    input  logic [AXI_ID_W-1:0]         m_axi_bid,
    input  logic [1:0]                  m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready,

    // Read address channel
    output logic [AXI_ID_W-1:0]         m_axi_arid,
    output logic [AXI_ADDR_W-1:0]       m_axi_araddr,
    output logic [7:0]                  m_axi_arlen,
    output logic [2:0]                  m_axi_arsize,
    output logic [1:0]                  m_axi_arburst,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,

    // Read data channel
    input  logic [AXI_ID_W-1:0]         m_axi_rid,
    input  logic [AXI_DATA_W-1:0]       m_axi_rdata,
    input  logic [1:0]                  m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready,

    // ==================== Register Access Interface (CPU side) ====================
    // Directly exposed or decoded from a separate AXI-Lite port — for simplicity,
    // expose as a simple valid/ready register interface. The SoC interconnect bridges
    // the CPU's register access to these signals.
    input  logic                        reg_wr_valid,
    output logic                        reg_wr_ready,
    input  logic [7:0]                  reg_wr_addr,
    input  logic [31:0]                 reg_wr_data,
    input  logic                        reg_rd_valid,
    output logic                        reg_rd_ready,
    input  logic [7:0]                  reg_rd_addr,
    output logic [31:0]                 reg_rd_data,

    // Interrupt output
    output logic                        irq_fault
);
```

**AXI slave transaction buffering strategy:**

The IOMMU processes one device transaction at a time. When a device issues a read (AR channel) or write (AW channel), the AXI wrapper:

1. **Accepts the address phase**: Latches `{arid/awid, araddr/awaddr, arlen/awlen, arsize/awsize, arburst/awburst}` into a holding register. Deasserts `arready`/`awready` to stall further transactions.
2. **For writes**: Also accepts the write data phase (W channel) into a data buffer (up to burst length). For the base implementation, support **single-beat transfers only** (`awlen = 0`). Burst support is a stretch goal.
3. **Extracts device ID**: `txn_device_id = s_axi_arid[DEVICE_ID_W-1:0]` (or `s_axi_awid`). The lower bits of AXI ID encode the device ID. The upper bits are the transaction tag.
4. **Sends to iommu_core**: `txn_valid`, `txn_vaddr`, `txn_device_id`, `txn_is_read`/`txn_is_write`.
5. **Waits for `txn_done`**:
   - If `txn_fault == 0`: Forward the transaction on the AXI master with the translated address. For reads: issue AR on master, relay R data back to device. For writes: issue AW+W on master, relay B response back.
   - If `txn_fault == 1`: Return an error response to the device. Read: `rresp = 2'b10` (SLVERR). Write: `bresp = 2'b10` (SLVERR).
6. **Re-assert `arready`/`awready`** to accept the next transaction.

**AXI master port sharing**: The AXI master port is shared between:
- **Device transaction forwarding** (post-translation reads and writes)
- **PTW memory reads** (during page table walks)
- **Device context fetches** (during DC cache misses)

The `iommu_core` serialises PTW and DC fetches via its FSM. The AXI wrapper multiplexes:
- When `iommu_core.mem_rd_req_valid` is asserted → master AR channel serves the core's memory read.
- When a translated device read needs forwarding → master AR channel serves the forwarded read.
- When a translated device write needs forwarding → master AW+W channels serve the forwarded write.

These never overlap because the core FSM is fully sequential: translation completes before forwarding begins.

**Simplified AXI constraints for base implementation:**
- Single-beat transfers only (`awlen = 0`, `arlen = 0`).
- Fixed size = 4 bytes (`awsize = 3'b010`, `arsize = 3'b010`).
- INCR burst type only.
- One outstanding transaction at a time on the slave side.
- The master side issues one transaction at a time.

---

## 3. Coding Conventions

### 3.1 Language and Simulator

- **SystemVerilog** (`.sv` files), targeting **`iverilog -g2012`**.
- Package file: `.sv` extension (not `.svh`). Import with `import iommu_pkg::*;`.
- Use `always_ff @(posedge clk)` for sequential logic.
- **Use `always @(*)` (not `always_comb`)** for any combinational block that reads signals driven by submodule outputs. This avoids iverilog infinite re-evaluation loops. Use `always_comb` only for purely local combinational logic with no submodule dependencies.
- Use `logic`, `typedef enum`, packages.
- **No `always_latch`**. No latches. All `always_ff` blocks must have a complete reset branch.

### 3.2 Reset

- **Active-high synchronous reset** signal named `srst`.
- Every `always_ff` block: `if (srst)` as the first branch, resetting all state to known values.

### 3.3 FSM Pattern

```systemverilog
typedef enum logic [N:0] {
    STATE_A,
    STATE_B,
    ...
} state_t;

state_t state, state_next;

always_ff @(posedge clk) begin
    if (srst)
        state <= STATE_A;
    else
        state <= state_next;
end

always @(*) begin  // or always_comb if no submodule outputs read
    state_next = state;  // default: hold
    // ... compute state_next and outputs ...
end
```

### 3.4 Handshake Protocol

All inter-module interfaces use `valid`/`ready`:
- **Sender** asserts `valid` and holds data stable until `ready` is sampled high.
- **Receiver** asserts `ready` when it can accept data.
- Transfer occurs on the cycle where both `valid && ready`.

### 3.5 Naming

- `snake_case` for all signals, modules, files.
- Prefix testbench files with `tb_` (e.g., `tb_iotlb.sv`).
- Prefix CocoTB test files with `test_` (e.g., `test_iotlb.py`).
- Module names match file names (e.g., `iotlb` in `iotlb.sv`).

### 3.6 Author Line

First line of every `.sv` file:

```systemverilog
// Brendan Lynskey 2025
```

First line of every `.py` CocoTB file:

```python
# Brendan Lynskey 2025
```

### 3.7 No Vendor Primitives

No Xilinx, Intel/Altera, or other vendor-specific primitives. All code must simulate in `iverilog -g2012` and be technology-portable.

### 3.8 Parameterisation

Use `parameter` in module headers and `localparam` for derived constants. All parameters must have sensible defaults so the module works without explicit override.

---

## 4. File Structure

```
RISCV_IOMMU/
├── CLAUDE_CODE_INSTRUCTIONS_IOMMU.md   # This file
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

---

## 5. Implementation Order

Build and fully verify each module before moving to the next. Bottom-up.

### Phase 1: Foundation Modules

**Step 1: `iommu_pkg.sv`**
- Define all parameters, structs, and constants.
- No testbench needed (it's a package).

**Step 2: `lru_tracker.sv`**
- Implement pseudo-LRU with tree-based tracking.
- **SV tests** (`tb_lru_tracker.sv`): 6 tests minimum.
  1. Reset — LRU index is 0 after reset.
  2. Sequential access — access entries 0..N-1, LRU should cycle.
  3. Repeated access — accessing same entry repeatedly doesn't change LRU.
  4. LRU eviction order — after accessing all but one, LRU points to the unaccessed one.
  5. Wrap-around — access pattern that wraps the full depth.
  6. Parameterisation — instantiate with depth 4 and depth 16, verify both.
- **CocoTB tests** (`test_lru_tracker.py`): 4 tests.
  1. `test_reset`: LRU index after reset.
  2. `test_sequential_access`: Access all entries, verify LRU.
  3. `test_lru_eviction`: Access pattern, check eviction target.
  4. `test_rapid_access`: Back-to-back accesses.

**Step 3: `iotlb.sv`**
- Fully-associative TLB with LRU, keyed by `{device_id, vpn1, vpn0}`.
- **SV tests** (`tb_iotlb.sv`): 10 tests minimum.
  1. Reset — all entries invalid, lookup misses.
  2. Single refill + hit — refill one entry, look it up.
  3. Different device IDs — same VPN, different device IDs are separate entries.
  4. Superpage hit — refill superpage, lookup with any vpn0.
  5. Capacity eviction — fill all entries, add one more, verify LRU eviction.
  6. Invalidate by device ID — refill entries from 2 devices, invalidate one, verify.
  7. Invalidate all — all entries cleared.
  8. Refill overwrites LRU — verify the evicted entry is the LRU one.
  9. Permission fields — verify R/W permissions stored and returned correctly.
  10. Miss returns no hit — lookup on empty TLB or non-matching address.
- **CocoTB tests** (`test_iotlb.py`): 6 tests.
  1. `test_reset_miss`: Lookup after reset returns miss.
  2. `test_refill_and_hit`: Refill then lookup — hit.
  3. `test_device_isolation`: Same VPN, different device IDs are independent.
  4. `test_superpage`: Superpage refill and lookup.
  5. `test_invalidation`: Selective and global invalidation.
  6. `test_capacity_eviction`: Overflow the TLB, check LRU eviction.

### Phase 2: Supporting Modules

**Step 4: `device_context_cache.sv`**
- Same architecture as IOTLB but keyed by `device_id` only, stores `device_context_t`.
- **SV tests** (`tb_device_context_cache.sv`): 7 tests minimum.
  1. Reset — all misses.
  2. Single refill + hit.
  3. Multiple devices — independent entries.
  4. Capacity eviction — fill all entries, add one more.
  5. Invalidate by device ID.
  6. Invalidate all.
  7. Context fields — verify all fields of `device_context_t` round-trip correctly.
- **CocoTB tests** (`test_device_context_cache.py`): 4 tests.
  1. `test_reset_miss`
  2. `test_refill_hit`
  3. `test_invalidation`
  4. `test_capacity_eviction`

**Step 5: `io_ptw.sv`**
- Sv32 two-level page table walker with FSM.
- **SV tests** (`tb_io_ptw.sv`): 10 tests minimum.
  1. Successful two-level walk — valid L1 non-leaf, valid L0 leaf.
  2. Superpage walk — valid L1 leaf with aligned PPN.
  3. L1 PTE invalid — V=0 at level 1, expect `CAUSE_PTE_INVALID`.
  4. L0 PTE invalid — V=0 at level 0, expect `CAUSE_PTE_INVALID`.
  5. Misaligned superpage — L1 leaf with PPN\[0\] != 0, expect `CAUSE_PTE_MISALIGNED`.
  6. Read permission denied — leaf PTE R=0, walk_is_read=1, expect `CAUSE_READ_DENIED`.
  7. Write permission denied — leaf PTE W=0, walk_is_write=1, expect `CAUSE_WRITE_DENIED`.
  8. Invalid PTE encoding — W=1,R=0 at leaf, expect fault.
  9. Memory error during walk — `mem_rd_error` asserted, expect `CAUSE_PTW_ACCESS_FAULT`.
  10. Back-to-back walks — complete one walk, immediately start another.
- **CocoTB tests** (`test_io_ptw.py`): 6 tests.
  1. `test_two_level_walk`: Successful full walk.
  2. `test_superpage`: L1 leaf, aligned superpage.
  3. `test_l1_invalid`: L1 PTE fault.
  4. `test_l0_invalid`: L0 PTE fault.
  5. `test_permission_denied`: R/W permission faults.
  6. `test_memory_error`: Access fault during walk.

**Step 6: `io_permission_checker.sv`**
- Combinational permission checker.
- **SV tests** (`tb_io_permission_checker.sv`): 8 tests minimum.
  1. Context disabled (`en=0`) → `CAUSE_CTX_INVALID`.
  2. Context enabled, read permitted, read access → no fault, needs_translation.
  3. Context enabled, read denied (`rp=0`), read access → `CAUSE_CTX_READ_DENIED`.
  4. Context enabled, write permitted, write access → no fault.
  5. Context enabled, write denied (`wp=0`), write access → `CAUSE_CTX_WRITE_DENIED`.
  6. Bare mode (`mode=0000`) → no fault, `needs_translation=0`.
  7. Sv32 mode (`mode=0001`) → no fault, `needs_translation=1`.
  8. Invalid mode (e.g., `mode=0010`) → `CAUSE_CTX_INVALID`.
- **CocoTB tests** (`test_io_permission_checker.py`): 4 tests.
  1. `test_ctx_disabled`: EN=0 fault.
  2. `test_read_write_permissions`: All R/W combinations.
  3. `test_translation_modes`: Bare, Sv32, invalid mode.
  4. `test_combined`: Context with mixed settings.

### Phase 3: Fault and Register Infrastructure

**Step 7: `fault_handler.sv`**
- Register-based circular fault queue.
- **SV tests** (`tb_fault_handler.sv`): 7 tests minimum.
  1. Reset — empty queue, head=tail=0, no fault_pending.
  2. Single fault write — write one record, tail advances, fault_pending asserted.
  3. Multiple faults — write several, verify tail advances correctly.
  4. Head increment — software advances head, fault_pending deasserted when head catches tail.
  5. Queue full — fill to capacity, verify `fault_ready` deasserted.
  6. Wrap-around — write enough to wrap tail past the end of the buffer.
  7. Fault record integrity — verify all fields of the fault record are stored correctly.
- **CocoTB tests** (`test_fault_handler.py`): 4 tests.
  1. `test_reset_empty`
  2. `test_write_and_pending`
  3. `test_full_queue`
  4. `test_wraparound`

**Step 8: `iommu_reg_file.sv`**
- Memory-mapped registers.
- **SV tests** (`tb_iommu_reg_file.sv`): 8 tests minimum.
  1. Reset — all registers at default values.
  2. Read capability register (read-only).
  3. Write and read CTRL register.
  4. Write and read DCT_BASE.
  5. Write IOTLB_INV — verify pulse output.
  6. Write DC_INV — verify pulse output.
  7. FQ head/tail tracking — write faults, read head/tail, increment head.
  8. Performance counters — pulse inputs, verify increment.
  9. IRQ output — fault_pending && fault_irq_en → irq_fault.
- **CocoTB tests** (`test_iommu_reg_file.py`): 5 tests.
  1. `test_reset_defaults`
  2. `test_read_write_ctrl`
  3. `test_invalidation_pulses`
  4. `test_fault_queue_registers`
  5. `test_irq_generation`

### Phase 4: Integration

**Step 9: `iommu_core.sv`**
- Full datapath integration.
- **SV tests** (`tb_iommu_core.sv`): 10 tests minimum. The testbench must provide a simulated memory model (array) that the core reads via `mem_rd_*`. Pre-load device context entries and page tables into this memory.
  1. Bypass mode — IOMMU disabled, address passes through.
  2. Bare mode — device context with `mode=BARE`, address passes through.
  3. Successful Sv32 translation — full flow: DC lookup → IOTLB miss → PTW → refill → translate.
  4. IOTLB hit — second access to same address hits in IOTLB (no PTW).
  5. Superpage translation — L1 leaf superpage.
  6. Device context fault — EN=0.
  7. Read permission fault — context RP=0.
  8. PTE fault — invalid PTE in page table.
  9. Multiple devices — two different device IDs with different page tables, verify isolation.
  10. IOTLB invalidation — translate, invalidate, translate again (triggers new PTW walk).
- **CocoTB tests** (`test_iommu_core.py`): 6 tests.
  1. `test_bypass`
  2. `test_sv32_translation`
  3. `test_iotlb_hit_after_miss`
  4. `test_superpage`
  5. `test_device_isolation`
  6. `test_fault_recording`

**Step 10: `iommu_axi_wrapper.sv`**
- AXI4 slave/master + register interface.
- **SV tests** (`tb_iommu_axi_wrapper.sv`): 8 tests minimum. The testbench acts as an AXI master (device side) and an AXI slave (memory side, providing page table data and accepting forwarded transactions).
  1. AXI read — bypass mode, read transaction passes through.
  2. AXI write — bypass mode, write transaction passes through.
  3. AXI read with translation — Sv32 translation on read.
  4. AXI write with translation — Sv32 translation on write.
  5. Fault response — invalid translation → SLVERR on AXI slave.
  6. Register access — write and read IOMMU registers.
  7. Back-to-back transactions — two sequential translated reads.
  8. Interrupt assertion — fault triggers IRQ.
- **CocoTB tests** (`test_iommu_axi_wrapper.py`): 6 tests.
  1. `test_axi_read_bypass`
  2. `test_axi_write_bypass`
  3. `test_axi_read_translated`
  4. `test_axi_write_translated`
  5. `test_axi_fault_response`
  6. `test_register_access`

### Test Count Summary

| Module | SV Tests | CocoTB Tests |
|---|---|---|
| `lru_tracker` | 6 | 4 |
| `iotlb` | 10 | 6 |
| `device_context_cache` | 7 | 4 |
| `io_ptw` | 10 | 6 |
| `io_permission_checker` | 8 | 4 |
| `fault_handler` | 7 | 4 |
| `iommu_reg_file` | 8 (+ 1 for IRQ = 9) | 5 |
| `iommu_core` | 10 | 6 |
| `iommu_axi_wrapper` | 8 | 6 |
| **Total** | **75** | **45** |

This exceeds the minimum requirements of 60 SV tests and 41 CocoTB tests.

---

## 6. Verification Requirements

### 6.1 SystemVerilog Testbench Style

Every SV testbench file follows this template:

```systemverilog
// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_<module_name>;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // DUT signals
    // ...

    // DUT instantiation
    <module_name> dut ( .* );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst = 1;
        repeat (4) @(posedge clk);
        srst = 0;
        @(posedge clk);
    endtask

    task automatic check(input string test_name, input logic condition);
        test_count++;
        if (condition) begin
            $display("[PASS] %s", test_name);
            pass_count++;
        end else begin
            $display("[FAIL] %s", test_name);
            fail_count++;
            $stop;
        end
    endtask

    // Test tasks
    task automatic test_reset();
        reset_dut();
        check("Reset — <expected behaviour>", /* condition */);
    endtask

    // ... more test tasks ...

    // Main
    initial begin
        $dumpfile("tb_<module_name>.vcd");
        $dumpvars(0, tb_<module_name>);

        test_reset();
        // ... call other test tasks ...

        $display("\n========================================");
        $display("Results: %0d/%0d passed", pass_count, test_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("%0d TESTS FAILED", fail_count);
        $display("========================================\n");
        $finish;
    end
endmodule
```

**Key rules:**
- `$stop` on first failure (fail-fast).
- `[PASS]`/`[FAIL]` prefix for every test.
- Summary at end with pass/fail counts.
- VCD dump for waveform debug.
- Use `task automatic` for all test tasks.

### 6.2 Memory Model for PTW and Core Testbenches

The `tb_io_ptw.sv` and `tb_iommu_core.sv` testbenches must include a simple memory model:

```systemverilog
// Simple memory model — 4 KB addressable region
logic [31:0] mem [0:1023];  // 1024 x 32-bit words

// Respond to memory read requests from DUT
always_ff @(posedge clk) begin
    if (srst) begin
        mem_rd_resp_valid <= 0;
    end else if (mem_rd_req_valid && mem_rd_req_ready) begin
        mem_rd_data <= mem[mem_rd_addr[11:2]];  // word-aligned
        mem_rd_resp_valid <= 1;
        mem_rd_error <= 0;
    end else begin
        mem_rd_resp_valid <= 0;
    end
end
```

Pre-load page table entries and device context entries into `mem[]` before each test.

### 6.3 CocoTB Test Style

```python
# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

async def reset_dut(dut):
    dut.srst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_reset(dut):
    """Verify state after reset."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    # assertions...
    assert dut.some_signal.value == 0, "Expected 0 after reset"
```

**CocoTB Makefile template:**

```makefile
# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../rtl/iommu_pkg.sv \
                  $(PWD)/../../rtl/<module>.sv
TOPLEVEL = <module>
MODULE = test_<module>
COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
```

### 6.4 AXI Testbench Requirements

For `tb_iommu_axi_wrapper.sv`, the testbench must simulate:
- An **AXI master** (device side) that drives AR/AW/W channels and receives R/B responses.
- An **AXI slave** (memory side) that receives forwarded AR/AW/W and responds with R/B, including a memory model for page table data.
- A **register driver** that writes and reads IOMMU registers.

Use task-based AXI drivers:

```systemverilog
task automatic axi_read(
    input  logic [AXI_ADDR_W-1:0] addr,
    input  logic [AXI_ID_W-1:0]   id,
    output logic [AXI_DATA_W-1:0] rdata,
    output logic [1:0]            rresp
);
    // Drive AR channel
    s_axi_araddr  = addr;
    s_axi_arid    = id;
    s_axi_arlen   = 0;
    s_axi_arsize  = 3'b010;
    s_axi_arburst = 2'b01;
    s_axi_arvalid = 1;
    @(posedge clk);
    while (!s_axi_arready) @(posedge clk);
    s_axi_arvalid = 0;

    // Wait for R channel
    s_axi_rready = 1;
    while (!s_axi_rvalid) @(posedge clk);
    rdata = s_axi_rdata;
    rresp = s_axi_rresp;
    s_axi_rready = 0;
    @(posedge clk);
endtask
```

---

## 7. Simulation & Debug Workflow

### 7.1 Compile and Run a Single SV Testbench

```bash
cd ~/Claude_sandbox/RISCV_IOMMU

# Compile
iverilog -g2012 -o tb_iotlb.vvp \
    rtl/iommu_pkg.sv \
    rtl/lru_tracker.sv \
    rtl/iotlb.sv \
    tb/sv/tb_iotlb.sv

# Run
vvp tb_iotlb.vvp

# View waveforms (optional)
gtkwave tb_iotlb.vcd &
```

### 7.2 Run All SV Testbenches

`scripts/run_all_sv.sh`:

```bash
#!/bin/bash
# Brendan Lynskey 2025
set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RTL_DIR="$PROJ_DIR/rtl"
TB_DIR="$PROJ_DIR/tb/sv"

PASS=0
FAIL=0

# Define compilation units (testbench : required RTL files)
declare -A TESTS
TESTS[tb_lru_tracker]="iommu_pkg.sv lru_tracker.sv"
TESTS[tb_iotlb]="iommu_pkg.sv lru_tracker.sv iotlb.sv"
TESTS[tb_device_context_cache]="iommu_pkg.sv lru_tracker.sv device_context_cache.sv"
TESTS[tb_io_ptw]="iommu_pkg.sv io_ptw.sv"
TESTS[tb_io_permission_checker]="iommu_pkg.sv io_permission_checker.sv"
TESTS[tb_fault_handler]="iommu_pkg.sv fault_handler.sv"
TESTS[tb_iommu_reg_file]="iommu_pkg.sv fault_handler.sv iommu_reg_file.sv"
TESTS[tb_iommu_core]="iommu_pkg.sv lru_tracker.sv iotlb.sv device_context_cache.sv io_ptw.sv io_permission_checker.sv fault_handler.sv iommu_core.sv"
TESTS[tb_iommu_axi_wrapper]="iommu_pkg.sv lru_tracker.sv iotlb.sv device_context_cache.sv io_ptw.sv io_permission_checker.sv fault_handler.sv iommu_reg_file.sv iommu_core.sv iommu_axi_wrapper.sv"

for TB_NAME in "${!TESTS[@]}"; do
    RTL_FILES=""
    for f in ${TESTS[$TB_NAME]}; do
        RTL_FILES="$RTL_FILES $RTL_DIR/$f"
    done

    echo "========================================"
    echo "Compiling $TB_NAME..."
    iverilog -g2012 -o "${TB_NAME}.vvp" $RTL_FILES "$TB_DIR/${TB_NAME}.sv"

    echo "Running $TB_NAME..."
    if vvp "${TB_NAME}.vvp" | tee "${TB_NAME}.log" | grep -q "ALL TESTS PASSED"; then
        echo ">>> $TB_NAME: PASSED"
        ((PASS++))
    else
        echo ">>> $TB_NAME: FAILED"
        ((FAIL++))
    fi
done

echo ""
echo "========================================"
echo "SV Test Summary: $PASS passed, $FAIL failed out of $((PASS+FAIL))"
echo "========================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
```

### 7.3 Run All CocoTB Tests

`scripts/run_all_cocotb.sh`:

```bash
#!/bin/bash
# Brendan Lynskey 2025
set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COCOTB_DIR="$PROJ_DIR/tb/cocotb"

PASS=0
FAIL=0

for TEST_DIR in "$COCOTB_DIR"/test_*/; do
    TEST_NAME=$(basename "$TEST_DIR")
    echo "========================================"
    echo "Running CocoTB: $TEST_NAME..."
    cd "$TEST_DIR"
    if make SIM=icarus 2>&1 | tee "$TEST_NAME.log" | grep -q "passed"; then
        echo ">>> $TEST_NAME: PASSED"
        ((PASS++))
    else
        echo ">>> $TEST_NAME: FAILED"
        ((FAIL++))
    fi
    cd "$PROJ_DIR"
done

echo ""
echo "========================================"
echo "CocoTB Test Summary: $PASS passed, $FAIL failed out of $((PASS+FAIL))"
echo "========================================"

[ $FAIL -eq 0 ] && exit 0 || exit 1
```

### 7.4 Run Everything

`scripts/run_all.sh`:

```bash
#!/bin/bash
# Brendan Lynskey 2025
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Running SystemVerilog Tests ==="
bash "$SCRIPT_DIR/run_all_sv.sh"
SV_RESULT=$?
echo ""
echo "=== Running CocoTB Tests ==="
bash "$SCRIPT_DIR/run_all_cocotb.sh"
COCOTB_RESULT=$?
echo ""
if [ $SV_RESULT -eq 0 ] && [ $COCOTB_RESULT -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED"
    exit 1
fi
```

### 7.5 Compile-Only Check

`scripts/compile.sh`:

```bash
#!/bin/bash
# Brendan Lynskey 2025
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RTL_DIR="$PROJ_DIR/rtl"

echo "Compiling all RTL..."
iverilog -g2012 -o /dev/null \
    "$RTL_DIR/iommu_pkg.sv" \
    "$RTL_DIR/lru_tracker.sv" \
    "$RTL_DIR/iotlb.sv" \
    "$RTL_DIR/device_context_cache.sv" \
    "$RTL_DIR/io_ptw.sv" \
    "$RTL_DIR/io_permission_checker.sv" \
    "$RTL_DIR/fault_handler.sv" \
    "$RTL_DIR/iommu_reg_file.sv" \
    "$RTL_DIR/iommu_core.sv" \
    "$RTL_DIR/iommu_axi_wrapper.sv"

echo "Compilation successful — no syntax errors."
```

---

## 8. README Template

Create `README.md` with the following structure:

```markdown
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

(Include the module tree from Section 2.6)

## Quick Start

```bash
# Run all SystemVerilog tests
bash scripts/run_all_sv.sh

# Run all CocoTB tests
bash scripts/run_all_cocotb.sh

# Run everything
bash scripts/run_all.sh
```

## Test Summary

| Module | SV Tests | CocoTB Tests |
|--------|----------|-------------|
| ... | ... | ... |
| **Total** | **75** | **45** |

## File Structure

(Include the directory tree from Section 4)

## Related Projects

- [RISCV_MMU](https://github.com/BrendanJamesLynskey/RISCV_MMU) — CPU-side Sv32 MMU with TLB and hardware page table walker

## Limitations

- Single-stage translation only (no two-stage / nested virtualisation)
- Single-beat AXI transfers only (no burst support)
- PTW does not set A/D bits (pre-set in page table entries)
- No command queue (invalidation via register writes only)
- No MSI remapping or ATS/PRI support

## License

MIT
```

---

## 9. Hardware Index Update

After the project is complete and all tests pass, update the parent Hardware index repository.

**Repository**: `https://github.com/BrendanJamesLynskey/Hardware`

**Action**: Merge (never replace) a new row into the existing README.md table:

| Repository | Description | Status |
|---|---|---|
| [RISCV_IOMMU](https://github.com/BrendanJamesLynskey/RISCV_IOMMU) | RISC-V IOMMU — Sv32 I/O address translation with IOTLB, device context cache, AXI4 interfaces, and fault handling | ✅ Complete |

**Important**: Read the existing Hardware README first. Find the table. Add this row in alphabetical order by repo name. Do not delete or modify any existing rows.

---

## 10. Stretch Goals

These are not required for the base implementation but should be described in the technical report and are candidates for future work.

### 10.1 Two-Stage Translation (Virtualisation)

Stage 1 translates DVA → GPA using the device's page table (set up by the guest OS). Stage 2 translates GPA → HPA using the hypervisor's page table. This requires:
- A second root PPN field in the device context (`reserved_w1` can store it).
- A `mode` value for two-stage (e.g., `4'b0010`).
- The PTW must perform a nested walk: for each PTE read in Stage 1, the PTE's physical address itself must be translated through Stage 2.
- The IOTLB must store the final HPA.

### 10.2 Command Queue

A memory-resident ring buffer where software writes invalidation commands. The IOMMU reads commands from the queue and processes them. This replaces the simple register-based invalidation.

Command format (32 bits): `{reserved[31:16], device_id[15:8], opcode[7:0]}`
- Opcode `0x01`: Invalidate IOTLB by device ID.
- Opcode `0x02`: Invalidate IOTLB entry by device ID + VPN.
- Opcode `0x03`: Invalidate all IOTLB entries.
- Opcode `0x04`: Invalidate device context cache by device ID.
- Opcode `0xFF`: Fence — wait for all prior commands to complete.

### 10.3 MSI Remapping

Memory-Mapped I/O writes that target the MSI address range (typically `0xFEE0_0000`) are intercepted by the IOMMU and remapped according to an MSI page table. This allows the hypervisor to control which interrupts a device can inject.

### 10.4 ATS/PRI (Address Translation Services / Page Request Interface)

PCIe-based protocol where the device requests translations from the IOMMU before issuing DMA. The IOMMU responds with the translated address or a page fault. PRI allows the device to request that the OS page in a missing page.

---

## 11. Checklist — Definition of Done

- [ ] `iommu_pkg.sv` — all parameters, structs, and constants defined
- [ ] `lru_tracker.sv` — implemented and passing 6 SV tests + 4 CocoTB tests
- [ ] `iotlb.sv` — implemented and passing 10 SV tests + 6 CocoTB tests
- [ ] `device_context_cache.sv` — implemented and passing 7 SV tests + 4 CocoTB tests
- [ ] `io_ptw.sv` — implemented and passing 10 SV tests + 6 CocoTB tests
- [ ] `io_permission_checker.sv` — implemented and passing 8 SV tests + 4 CocoTB tests
- [ ] `fault_handler.sv` — implemented and passing 7 SV tests + 4 CocoTB tests
- [ ] `iommu_reg_file.sv` — implemented and passing 9 SV tests + 5 CocoTB tests
- [ ] `iommu_core.sv` — implemented and passing 10 SV tests + 6 CocoTB tests
- [ ] `iommu_axi_wrapper.sv` — implemented and passing 8 SV tests + 6 CocoTB tests
- [ ] All 75 SV tests pass (`scripts/run_all_sv.sh` exits 0)
- [ ] All 45 CocoTB tests pass (`scripts/run_all_cocotb.sh` exits 0)
- [ ] `scripts/compile.sh` — clean compilation with no warnings
- [ ] `README.md` — complete with architecture description, test summary, and usage
- [ ] `docs/RISCV_IOMMU_Technical_Report.md` — architecture decisions, design trade-offs, and stretch goal analysis
- [ ] Hardware index updated (merge new row into `https://github.com/BrendanJamesLynskey/Hardware` README)
- [ ] All files have author line as first line
- [ ] No vendor-specific primitives
- [ ] All `always @(*)` used where submodule outputs are read combinationally
- [ ] All FSMs follow the `state`/`state_next` pattern
- [ ] All interfaces use `valid`/`ready` handshake
- [ ] Git repository initialised with meaningful commit history (one commit per module, not one giant commit)
