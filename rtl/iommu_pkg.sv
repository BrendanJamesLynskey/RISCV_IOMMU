// Brendan Lynskey 2025
package iommu_pkg;

    // ==================== Address Parameters ====================
    localparam int PADDR_W       = 34;   // Physical address width (Sv32: up to 34 bits)
    localparam int VADDR_W       = 32;   // Virtual (device) address width
    localparam int PAGE_OFFSET_W = 12;   // 4 KB page offset
    localparam int VPN_W         = 10;   // VPN field width (each level)
    localparam int PPN_W         = 22;   // Physical page number width (34 - 12)
    localparam int PTE_W         = 32;   // PTE width

    // ==================== Device Parameters ====================
    localparam int DEVICE_ID_W   = 8;    // Device ID width (up to 256 devices)

    // ==================== Cache Parameters ====================
    localparam int IOTLB_DEPTH     = 16; // Number of IOTLB entries
    localparam int DC_CACHE_DEPTH  = 8;  // Number of device context cache entries

    // ==================== AXI Parameters ====================
    localparam int AXI_DATA_W = 32;      // AXI data bus width
    localparam int AXI_ADDR_W = 34;      // AXI address bus width (= PADDR_W)
    localparam int AXI_ID_W   = 4;       // AXI ID width
    localparam int AXI_STRB_W = 4;       // AXI write strobe width (AXI_DATA_W / 8)

    // ==================== Fault Queue Parameters ====================
    localparam int FAULT_QUEUE_DEPTH = 16; // Fault queue depth (power of 2)

    // ==================== Translation Modes ====================
    localparam logic [3:0] MODE_BARE = 4'b0000;
    localparam logic [3:0] MODE_SV32 = 4'b0001;

    // ==================== Fault Cause Codes ====================
    localparam logic [3:0] CAUSE_NONE             = 4'h0;
    localparam logic [3:0] CAUSE_PTE_INVALID      = 4'h1;
    localparam logic [3:0] CAUSE_PTE_MISALIGNED   = 4'h2;
    localparam logic [3:0] CAUSE_READ_DENIED      = 4'h3;
    localparam logic [3:0] CAUSE_WRITE_DENIED     = 4'h4;
    localparam logic [3:0] CAUSE_CTX_INVALID      = 4'h5;
    localparam logic [3:0] CAUSE_CTX_READ_DENIED  = 4'h6;
    localparam logic [3:0] CAUSE_CTX_WRITE_DENIED = 4'h7;
    localparam logic [3:0] CAUSE_PTW_ACCESS_FAULT = 4'h8;
    localparam logic [3:0] CAUSE_RESERVED         = 4'hF;

    // ==================== Device Context Table Entry ====================
    typedef struct packed {
        logic [31:0]            reserved_w1;    // Word 1 -- reserved
        logic [PPN_W-1:0]       pt_root_ppn;    // [31:10] of word 0
        logic [1:0]             rsv;            // [9:8]
        logic [3:0]             mode;           // [7:4]
        logic                   fp;             // [3] fault policy
        logic                   wp;             // [2] write permission
        logic                   rp;             // [1] read permission
        logic                   en;             // [0] enable
    } device_context_t;  // 64 bits total

    // ==================== Fault Record ====================
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

    // ==================== Register Offsets ====================
    localparam logic [7:0] REG_IOMMU_CAP       = 8'h00;
    localparam logic [7:0] REG_IOMMU_CTRL      = 8'h04;
    localparam logic [7:0] REG_IOMMU_STATUS    = 8'h08;
    localparam logic [7:0] REG_DCT_BASE        = 8'h0C;
    localparam logic [7:0] REG_FQ_BASE         = 8'h10;
    localparam logic [7:0] REG_FQ_HEAD         = 8'h14;
    localparam logic [7:0] REG_FQ_TAIL         = 8'h18;
    localparam logic [7:0] REG_FQ_HEAD_INC     = 8'h1C;
    localparam logic [7:0] REG_FQ_SIZE_LOG2    = 8'h20;
    localparam logic [7:0] REG_IOTLB_INV       = 8'h24;
    localparam logic [7:0] REG_DC_INV          = 8'h28;
    localparam logic [7:0] REG_PERF_IOTLB_HIT  = 8'h2C;
    localparam logic [7:0] REG_PERF_IOTLB_MISS = 8'h30;
    localparam logic [7:0] REG_PERF_FAULT_CNT  = 8'h34;
    localparam logic [7:0] REG_FQ_READ_DATA_LO = 8'h38;
    localparam logic [7:0] REG_FQ_READ_DATA_HI = 8'h3C;

    // ==================== Capability Register Value ====================
    // Bit 0: Sv32 supported = 1
    // Bit 1: Two-stage supported = 0
    // Bits 7:4: max device ID width = 8
    localparam logic [31:0] CAP_VALUE = 32'h0000_0081;

endpackage
