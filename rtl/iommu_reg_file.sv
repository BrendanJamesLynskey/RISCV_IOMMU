// Brendan Lynskey 2025
module iommu_reg_file
    import iommu_pkg::*;
(
    input  logic                    clk,
    input  logic                    srst,

    // CPU-side register access (simple valid/ready)
    input  logic                    reg_wr_valid,
    output logic                    reg_wr_ready,
    input  logic [7:0]              reg_wr_addr,
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
    input  logic                    fault_pending,
    input  logic [7:0]              fq_head,
    input  logic [7:0]              fq_tail,
    input  fault_record_t           fq_read_data,

    // Fault queue head increment
    output logic                    fq_head_inc,

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

    // Always ready -- single-cycle access
    assign reg_wr_ready = 1'b1;
    assign reg_rd_ready = 1'b1;

    // Registers
    logic [31:0] ctrl_reg;
    logic [31:0] status_reg;
    logic [PPN_W-1:0] r_dct_base_ppn;
    logic [PPN_W-1:0] r_fq_base_ppn;
    logic [3:0]  r_fq_size_log2;
    logic [31:0] perf_hit_cnt;
    logic [31:0] perf_miss_cnt;
    logic [31:0] perf_fault_cnt;

    assign iommu_enable  = ctrl_reg[0];
    assign fault_irq_en  = ctrl_reg[1];
    assign dct_base_ppn  = r_dct_base_ppn;
    assign fq_base_ppn   = r_fq_base_ppn;
    assign fq_size_log2  = r_fq_size_log2;

    // Interrupt
    assign irq_fault = fault_pending & fault_irq_en;

    // Pulse outputs for invalidation and head increment
    logic r_iotlb_inv_valid;
    logic r_dc_inv_valid;
    logic r_fq_head_inc;
    logic [DEVICE_ID_W-1:0] r_iotlb_inv_device_id;
    logic                    r_iotlb_inv_all;
    logic [DEVICE_ID_W-1:0] r_dc_inv_device_id;
    logic                    r_dc_inv_all;

    assign iotlb_inv_valid     = r_iotlb_inv_valid;
    assign iotlb_inv_device_id = r_iotlb_inv_device_id;
    assign iotlb_inv_all       = r_iotlb_inv_all;
    assign dc_inv_valid        = r_dc_inv_valid;
    assign dc_inv_device_id    = r_dc_inv_device_id;
    assign dc_inv_all          = r_dc_inv_all;
    assign fq_head_inc         = r_fq_head_inc;

    // Write logic
    always_ff @(posedge clk) begin
        if (srst) begin
            ctrl_reg            <= 32'b0;
            status_reg          <= 32'b0;
            r_dct_base_ppn      <= '0;
            r_fq_base_ppn       <= '0;
            r_fq_size_log2      <= 4'd4;
            perf_hit_cnt        <= 32'b0;
            perf_miss_cnt       <= 32'b0;
            perf_fault_cnt      <= 32'b0;
            r_iotlb_inv_valid   <= 1'b0;
            r_dc_inv_valid      <= 1'b0;
            r_fq_head_inc       <= 1'b0;
            r_iotlb_inv_device_id <= '0;
            r_iotlb_inv_all     <= 1'b0;
            r_dc_inv_device_id  <= '0;
            r_dc_inv_all        <= 1'b0;
        end else begin
            // Default: clear pulse outputs each cycle
            r_iotlb_inv_valid <= 1'b0;
            r_dc_inv_valid    <= 1'b0;
            r_fq_head_inc     <= 1'b0;

            // Status: fault_pending is live from fault_handler
            status_reg[0] <= fault_pending;

            // Performance counters
            if (perf_iotlb_hit)  perf_hit_cnt   <= perf_hit_cnt + 1;
            if (perf_iotlb_miss) perf_miss_cnt  <= perf_miss_cnt + 1;
            if (perf_fault)      perf_fault_cnt <= perf_fault_cnt + 1;

            // Register writes
            if (reg_wr_valid) begin
                case (reg_wr_addr)
                    REG_IOMMU_CTRL: begin
                        ctrl_reg <= reg_wr_data;
                    end
                    REG_IOMMU_STATUS: begin
                        // W1C: write 1 to clear
                        status_reg <= status_reg & ~reg_wr_data;
                    end
                    REG_DCT_BASE: begin
                        r_dct_base_ppn <= reg_wr_data[PPN_W-1:0];
                    end
                    REG_FQ_BASE: begin
                        r_fq_base_ppn <= reg_wr_data[PPN_W-1:0];
                    end
                    REG_FQ_SIZE_LOG2: begin
                        r_fq_size_log2 <= reg_wr_data[3:0];
                    end
                    REG_FQ_HEAD_INC: begin
                        r_fq_head_inc <= 1'b1;
                    end
                    REG_IOTLB_INV: begin
                        r_iotlb_inv_valid     <= 1'b1;
                        r_iotlb_inv_device_id <= reg_wr_data[DEVICE_ID_W-1:0];
                        r_iotlb_inv_all       <= reg_wr_data[8];
                    end
                    REG_DC_INV: begin
                        r_dc_inv_valid     <= 1'b1;
                        r_dc_inv_device_id <= reg_wr_data[DEVICE_ID_W-1:0];
                        r_dc_inv_all       <= reg_wr_data[8];
                    end
                    default: ;
                endcase
            end
        end
    end

    // Read logic
    always @(*) begin
        reg_rd_data = 32'b0;
        if (reg_rd_valid) begin
            case (reg_rd_addr)
                REG_IOMMU_CAP:       reg_rd_data = CAP_VALUE;
                REG_IOMMU_CTRL:      reg_rd_data = ctrl_reg;
                REG_IOMMU_STATUS:    reg_rd_data = {31'b0, fault_pending};
                REG_DCT_BASE:        reg_rd_data = {{(32-PPN_W){1'b0}}, r_dct_base_ppn};
                REG_FQ_BASE:         reg_rd_data = {{(32-PPN_W){1'b0}}, r_fq_base_ppn};
                REG_FQ_HEAD:         reg_rd_data = {24'b0, fq_head};
                REG_FQ_TAIL:         reg_rd_data = {24'b0, fq_tail};
                REG_FQ_SIZE_LOG2:    reg_rd_data = {28'b0, r_fq_size_log2};
                REG_PERF_IOTLB_HIT:  reg_rd_data = perf_hit_cnt;
                REG_PERF_IOTLB_MISS: reg_rd_data = perf_miss_cnt;
                REG_PERF_FAULT_CNT:  reg_rd_data = perf_fault_cnt;
                REG_FQ_READ_DATA_LO: reg_rd_data = fq_read_data[31:0];
                REG_FQ_READ_DATA_HI: reg_rd_data = fq_read_data[63:32];
                default:             reg_rd_data = 32'b0;
            endcase
        end
    end

endmodule
