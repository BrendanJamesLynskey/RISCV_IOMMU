// Brendan Lynskey 2025
module iommu_axi_wrapper
    import iommu_pkg::*;
(
    input  logic                        clk,
    input  logic                        srst,

    // ==================== AXI4 Slave Interface (Device Side) ====================
    input  logic [AXI_ID_W-1:0]         s_axi_awid,
    input  logic [AXI_ADDR_W-1:0]       s_axi_awaddr,
    input  logic [7:0]                  s_axi_awlen,
    input  logic [2:0]                  s_axi_awsize,
    input  logic [1:0]                  s_axi_awburst,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,

    input  logic [AXI_DATA_W-1:0]       s_axi_wdata,
    input  logic [AXI_STRB_W-1:0]       s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,

    output logic [AXI_ID_W-1:0]         s_axi_bid,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    input  logic [AXI_ID_W-1:0]         s_axi_arid,
    input  logic [AXI_ADDR_W-1:0]       s_axi_araddr,
    input  logic [7:0]                  s_axi_arlen,
    input  logic [2:0]                  s_axi_arsize,
    input  logic [1:0]                  s_axi_arburst,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,

    output logic [AXI_ID_W-1:0]         s_axi_rid,
    output logic [AXI_DATA_W-1:0]       s_axi_rdata,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready,

    // ==================== AXI4 Master Interface (Memory Side) ====================
    output logic [AXI_ID_W-1:0]         m_axi_awid,
    output logic [AXI_ADDR_W-1:0]       m_axi_awaddr,
    output logic [7:0]                  m_axi_awlen,
    output logic [2:0]                  m_axi_awsize,
    output logic [1:0]                  m_axi_awburst,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awready,

    output logic [AXI_DATA_W-1:0]       m_axi_wdata,
    output logic [AXI_STRB_W-1:0]       m_axi_wstrb,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wready,

    input  logic [AXI_ID_W-1:0]         m_axi_bid,
    input  logic [1:0]                  m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_bready,

    output logic [AXI_ID_W-1:0]         m_axi_arid,
    output logic [AXI_ADDR_W-1:0]       m_axi_araddr,
    output logic [7:0]                  m_axi_arlen,
    output logic [2:0]                  m_axi_arsize,
    output logic [1:0]                  m_axi_arburst,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arready,

    input  logic [AXI_ID_W-1:0]         m_axi_rid,
    input  logic [AXI_DATA_W-1:0]       m_axi_rdata,
    input  logic [1:0]                  m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rready,

    // ==================== Register Access Interface (CPU side) ====================
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

    // ==================== Wrapper FSM ====================
    typedef enum logic [3:0] {
        W_IDLE,
        W_ACCEPT_WDATA,
        W_TRANSLATE,
        W_TRANSLATE_WAIT,
        W_TRANSLATE_DONE,
        W_FWD_RD_ADDR,
        W_FWD_RD_DATA,
        W_FWD_WR_ADDR,
        W_FWD_WR_DATA,
        W_FWD_WR_RESP,
        W_ERR_RD_RESP,
        W_ERR_WR_RESP,
        W_CORE_MEM_RD_ADDR,
        W_CORE_MEM_RD_DATA
    } wrapper_state_t;

    wrapper_state_t wstate, wstate_next;

    // Latched slave-side transaction
    logic                   r_is_read_txn;
    logic [AXI_ID_W-1:0]   r_txn_id;
    logic [AXI_ADDR_W-1:0] r_txn_addr;
    logic [AXI_DATA_W-1:0] r_txn_wdata;
    logic [AXI_STRB_W-1:0] r_txn_wstrb;
    logic [DEVICE_ID_W-1:0] r_txn_device_id;

    // Translated address
    logic [PADDR_W-1:0]    r_translated_addr;
    logic                   r_txn_fault;

    // ==================== Core interface signals ====================
    logic                        core_txn_valid;
    logic                        core_txn_ready;
    logic                        core_txn_done;
    logic                        core_txn_fault;
    logic [3:0]                  core_txn_fault_cause;
    logic [PADDR_W-1:0]          core_txn_paddr;

    // Core memory read interface
    logic                        core_mem_rd_req_valid;
    logic                        core_mem_rd_req_ready;
    logic [PADDR_W-1:0]          core_mem_rd_addr;
    logic                        core_mem_rd_resp_valid;
    logic                        core_mem_rd_resp_ready;
    logic [31:0]                 core_mem_rd_data;
    logic                        core_mem_rd_error;

    // ==================== Register file signals ====================
    logic                    rf_iommu_enable;
    logic                    rf_fault_irq_en;
    logic [PPN_W-1:0]       rf_dct_base_ppn;
    logic [PPN_W-1:0]       rf_fq_base_ppn;
    logic [3:0]             rf_fq_size_log2;
    logic                    rf_fault_pending;
    logic [7:0]             rf_fq_head, rf_fq_tail;
    logic                    rf_fq_head_inc;
    logic                    rf_iotlb_inv_valid;
    logic [DEVICE_ID_W-1:0] rf_iotlb_inv_device_id;
    logic                    rf_iotlb_inv_all;
    logic                    rf_dc_inv_valid;
    logic [DEVICE_ID_W-1:0] rf_dc_inv_device_id;
    logic                    rf_dc_inv_all;
    logic                    rf_perf_iotlb_hit;
    logic                    rf_perf_iotlb_miss;
    logic                    rf_perf_fault;

    // ==================== Fault handler signals ====================
    logic                    fh_fault_valid;
    logic                    fh_fault_ready;
    fault_record_t           fh_fault_record;
    logic [$clog2(FAULT_QUEUE_DEPTH)-1:0] fh_head, fh_tail;
    logic                    fh_fault_pending;
    logic                    fh_queue_full;
    fault_record_t           fh_read_data;
    logic                    fh_perf_fault;

    // ==================== Submodule Instantiations ====================

    iommu_core u_core (
        .clk              (clk),
        .srst             (srst),
        .txn_valid        (core_txn_valid),
        .txn_ready        (core_txn_ready),
        .txn_device_id    (r_txn_device_id),
        .txn_vaddr        (r_txn_addr[VADDR_W-1:0]),
        .txn_is_read      (r_is_read_txn),
        .txn_is_write     (!r_is_read_txn),
        .txn_done         (core_txn_done),
        .txn_fault        (core_txn_fault),
        .txn_fault_cause  (core_txn_fault_cause),
        .txn_paddr        (core_txn_paddr),
        .iommu_enable     (rf_iommu_enable),
        .dct_base_ppn     (rf_dct_base_ppn),
        .mem_rd_req_valid (core_mem_rd_req_valid),
        .mem_rd_req_ready (core_mem_rd_req_ready),
        .mem_rd_addr      (core_mem_rd_addr),
        .mem_rd_resp_valid(core_mem_rd_resp_valid),
        .mem_rd_resp_ready(core_mem_rd_resp_ready),
        .mem_rd_data      (core_mem_rd_data),
        .mem_rd_error     (core_mem_rd_error),
        .fault_valid      (fh_fault_valid),
        .fault_ready      (fh_fault_ready),
        .fault_record     (fh_fault_record),
        .iotlb_inv_valid  (rf_iotlb_inv_valid),
        .iotlb_inv_device_id(rf_iotlb_inv_device_id),
        .iotlb_inv_all    (rf_iotlb_inv_all),
        .dc_inv_valid     (rf_dc_inv_valid),
        .dc_inv_device_id (rf_dc_inv_device_id),
        .dc_inv_all       (rf_dc_inv_all),
        .perf_iotlb_hit   (rf_perf_iotlb_hit),
        .perf_iotlb_miss  (rf_perf_iotlb_miss),
        .perf_fault       (rf_perf_fault)
    );

    fault_handler u_fh (
        .clk           (clk),
        .srst          (srst),
        .fault_valid   (fh_fault_valid),
        .fault_ready   (fh_fault_ready),
        .fault_record  (fh_fault_record),
        .head_inc      (rf_fq_head_inc),
        .head          (fh_head),
        .tail          (fh_tail),
        .fault_pending (fh_fault_pending),
        .queue_full    (fh_queue_full),
        .read_data     (fh_read_data),
        .perf_fault    (fh_perf_fault)
    );

    iommu_reg_file u_rf (
        .clk              (clk),
        .srst             (srst),
        .reg_wr_valid     (reg_wr_valid),
        .reg_wr_ready     (reg_wr_ready),
        .reg_wr_addr      (reg_wr_addr),
        .reg_wr_data      (reg_wr_data),
        .reg_rd_valid     (reg_rd_valid),
        .reg_rd_ready     (reg_rd_ready),
        .reg_rd_addr      (reg_rd_addr),
        .reg_rd_data      (reg_rd_data),
        .iommu_enable     (rf_iommu_enable),
        .fault_irq_en     (rf_fault_irq_en),
        .dct_base_ppn     (rf_dct_base_ppn),
        .fq_base_ppn      (rf_fq_base_ppn),
        .fq_size_log2     (rf_fq_size_log2),
        .fault_pending    (fh_fault_pending),
        .fq_head          ({4'b0, fh_head}),
        .fq_tail          ({4'b0, fh_tail}),
        .fq_read_data     (fh_read_data),
        .fq_head_inc      (rf_fq_head_inc),
        .iotlb_inv_valid  (rf_iotlb_inv_valid),
        .iotlb_inv_device_id(rf_iotlb_inv_device_id),
        .iotlb_inv_all    (rf_iotlb_inv_all),
        .dc_inv_valid     (rf_dc_inv_valid),
        .dc_inv_device_id (rf_dc_inv_device_id),
        .dc_inv_all       (rf_dc_inv_all),
        .perf_iotlb_hit   (rf_perf_iotlb_hit),
        .perf_iotlb_miss  (rf_perf_iotlb_miss),
        .perf_fault       (rf_perf_fault),
        .irq_fault        (irq_fault)
    );

    // ==================== Wrapper State Machine ====================
    always_ff @(posedge clk) begin
        if (srst)
            wstate <= W_IDLE;
        else
            wstate <= wstate_next;
    end

    // Latch slave transaction
    always_ff @(posedge clk) begin
        if (srst) begin
            r_is_read_txn   <= 1'b0;
            r_txn_id        <= '0;
            r_txn_addr      <= '0;
            r_txn_wdata     <= '0;
            r_txn_wstrb     <= '0;
            r_txn_device_id <= '0;
            r_translated_addr <= '0;
            r_txn_fault     <= 1'b0;
        end else begin
            // Accept read address (arready is comb from always @(*), use arvalid only)
            if (wstate == W_IDLE && s_axi_arvalid) begin
                r_is_read_txn   <= 1'b1;
                r_txn_id        <= s_axi_arid;
                r_txn_addr      <= s_axi_araddr;
                r_txn_device_id <= {{(DEVICE_ID_W-AXI_ID_W){1'b0}}, s_axi_arid};
            end
            // Accept write address
            if (wstate == W_IDLE && !s_axi_arvalid && s_axi_awvalid) begin
                r_is_read_txn   <= 1'b0;
                r_txn_id        <= s_axi_awid;
                r_txn_addr      <= s_axi_awaddr;
                r_txn_device_id <= {{(DEVICE_ID_W-AXI_ID_W){1'b0}}, s_axi_awid};
            end
            // Accept write data (wready is comb, use wvalid only)
            if (wstate == W_ACCEPT_WDATA && s_axi_wvalid) begin
                r_txn_wdata <= s_axi_wdata;
                r_txn_wstrb <= s_axi_wstrb;
            end
            // Latch translation result
            if (wstate == W_TRANSLATE_WAIT && core_txn_done) begin
                r_translated_addr <= core_txn_paddr;
                r_txn_fault       <= core_txn_fault;
            end
        end
    end

    // ==================== Core memory read via AXI master ====================
    // When core needs memory reads (PTW / DC fetch), we bridge via AXI master
    logic core_mem_pending;
    logic core_mem_resp_pending;
    logic [PADDR_W-1:0] r_core_mem_addr;  // latched address for AXI master

    always_ff @(posedge clk) begin
        if (srst) begin
            core_mem_pending      <= 1'b0;
            core_mem_resp_pending <= 1'b0;
            r_core_mem_addr       <= '0;
            core_mem_rd_resp_valid <= 1'b0;
            core_mem_rd_data      <= '0;
            core_mem_rd_error     <= 1'b0;
        end else begin
            core_mem_rd_resp_valid <= 1'b0; // pulse

            // Accept core memory read request -- latch address
            if (core_mem_rd_req_valid && core_mem_rd_req_ready) begin
                core_mem_pending <= 1'b1;
                r_core_mem_addr  <= core_mem_rd_addr;
            end

            // AXI master AR accepted
            if (wstate == W_CORE_MEM_RD_ADDR && m_axi_arvalid && m_axi_arready) begin
                core_mem_pending      <= 1'b0;
                core_mem_resp_pending <= 1'b1;
            end

            // AXI master R response
            if (wstate == W_CORE_MEM_RD_DATA && m_axi_rvalid && m_axi_rready) begin
                core_mem_resp_pending  <= 1'b0;
                core_mem_rd_resp_valid <= 1'b1;
                core_mem_rd_data       <= m_axi_rdata;
                core_mem_rd_error      <= (m_axi_rresp != 2'b00);
            end
        end
    end

    assign core_mem_rd_req_ready = (wstate == W_TRANSLATE_WAIT) && !core_mem_pending && !core_mem_resp_pending;

    // ==================== Submodule control via assign ====================
    // Break combinational feedback loop between wrapper always @(*) and core
    assign core_txn_valid = (wstate == W_TRANSLATE);

    // ==================== Next-state logic ====================
    always @(*) begin
        wstate_next    = wstate;
        s_axi_arready  = 1'b0;
        s_axi_awready  = 1'b0;
        s_axi_wready   = 1'b0;
        s_axi_bvalid   = 1'b0;
        s_axi_bid      = '0;
        s_axi_bresp    = 2'b00;
        s_axi_rvalid   = 1'b0;
        s_axi_rid      = '0;
        s_axi_rdata    = '0;
        s_axi_rresp    = 2'b00;
        s_axi_rlast    = 1'b0;

        m_axi_arvalid  = 1'b0;
        m_axi_arid     = '0;
        m_axi_araddr   = '0;
        m_axi_arlen    = 8'b0;
        m_axi_arsize   = 3'b010;
        m_axi_arburst  = 2'b01;
        m_axi_rready   = 1'b0;

        m_axi_awvalid  = 1'b0;
        m_axi_awid     = '0;
        m_axi_awaddr   = '0;
        m_axi_awlen    = 8'b0;
        m_axi_awsize   = 3'b010;
        m_axi_awburst  = 2'b01;
        m_axi_wvalid   = 1'b0;
        m_axi_wdata    = '0;
        m_axi_wstrb    = '0;
        m_axi_wlast    = 1'b0;
        m_axi_bready   = 1'b0;

        case (wstate)
            W_IDLE: begin
                // Accept read requests with priority over writes
                if (s_axi_arvalid) begin
                    s_axi_arready = 1'b1;
                    wstate_next   = W_TRANSLATE;
                end else if (s_axi_awvalid) begin
                    s_axi_awready = 1'b1;
                    wstate_next   = W_ACCEPT_WDATA;
                end
            end

            W_ACCEPT_WDATA: begin
                s_axi_wready = 1'b1;
                if (s_axi_wvalid)
                    wstate_next = W_TRANSLATE;
            end

            W_TRANSLATE: begin
                if (core_txn_ready)
                    wstate_next = W_TRANSLATE_WAIT;
            end

            W_TRANSLATE_WAIT: begin
                // Handle core memory reads via AXI master
                if (core_mem_pending) begin
                    wstate_next = W_CORE_MEM_RD_ADDR;
                end else if (core_txn_done) begin
                    // Go to DONE state to use latched results
                    wstate_next = W_TRANSLATE_DONE;
                end
            end

            W_TRANSLATE_DONE: begin
                // Use registered r_txn_fault and r_translated_addr
                if (r_txn_fault) begin
                    if (r_is_read_txn)
                        wstate_next = W_ERR_RD_RESP;
                    else
                        wstate_next = W_ERR_WR_RESP;
                end else begin
                    if (r_is_read_txn)
                        wstate_next = W_FWD_RD_ADDR;
                    else
                        wstate_next = W_FWD_WR_ADDR;
                end
            end

            W_CORE_MEM_RD_ADDR: begin
                m_axi_arvalid = 1'b1;
                m_axi_araddr  = r_core_mem_addr;
                m_axi_arid    = '0;
                m_axi_arlen   = 8'b0;
                m_axi_arsize  = 3'b010;
                m_axi_arburst = 2'b01;
                if (m_axi_arready)
                    wstate_next = W_CORE_MEM_RD_DATA;
            end

            W_CORE_MEM_RD_DATA: begin
                m_axi_rready = 1'b1;
                if (m_axi_rvalid)
                    wstate_next = W_TRANSLATE_WAIT;
            end

            W_FWD_RD_ADDR: begin
                m_axi_arvalid = 1'b1;
                m_axi_araddr  = r_translated_addr;
                m_axi_arid    = r_txn_id;
                m_axi_arlen   = 8'b0;
                m_axi_arsize  = 3'b010;
                m_axi_arburst = 2'b01;
                if (m_axi_arready)
                    wstate_next = W_FWD_RD_DATA;
            end

            W_FWD_RD_DATA: begin
                m_axi_rready = 1'b1;
                if (m_axi_rvalid) begin
                    s_axi_rvalid = 1'b1;
                    s_axi_rid    = r_txn_id;
                    s_axi_rdata  = m_axi_rdata;
                    s_axi_rresp  = m_axi_rresp;
                    s_axi_rlast  = 1'b1;
                    if (s_axi_rready)
                        wstate_next = W_IDLE;
                end
            end

            W_FWD_WR_ADDR: begin
                m_axi_awvalid = 1'b1;
                m_axi_awaddr  = r_translated_addr;
                m_axi_awid    = r_txn_id;
                m_axi_awlen   = 8'b0;
                m_axi_awsize  = 3'b010;
                m_axi_awburst = 2'b01;
                if (m_axi_awready)
                    wstate_next = W_FWD_WR_DATA;
            end

            W_FWD_WR_DATA: begin
                m_axi_wvalid = 1'b1;
                m_axi_wdata  = r_txn_wdata;
                m_axi_wstrb  = r_txn_wstrb;
                m_axi_wlast  = 1'b1;
                if (m_axi_wready)
                    wstate_next = W_FWD_WR_RESP;
            end

            W_FWD_WR_RESP: begin
                m_axi_bready = 1'b1;
                if (m_axi_bvalid) begin
                    s_axi_bvalid = 1'b1;
                    s_axi_bid    = r_txn_id;
                    s_axi_bresp  = m_axi_bresp;
                    if (s_axi_bready)
                        wstate_next = W_IDLE;
                end
            end

            W_ERR_RD_RESP: begin
                s_axi_rvalid = 1'b1;
                s_axi_rid    = r_txn_id;
                s_axi_rdata  = '0;
                s_axi_rresp  = 2'b10; // SLVERR
                s_axi_rlast  = 1'b1;
                if (s_axi_rready)
                    wstate_next = W_IDLE;
            end

            W_ERR_WR_RESP: begin
                s_axi_bvalid = 1'b1;
                s_axi_bid    = r_txn_id;
                s_axi_bresp  = 2'b10; // SLVERR
                if (s_axi_bready)
                    wstate_next = W_IDLE;
            end
        endcase
    end

endmodule
