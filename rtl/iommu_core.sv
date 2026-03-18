// Brendan Lynskey 2025
module iommu_core
    import iommu_pkg::*;
(
    input  logic                        clk,
    input  logic                        srst,

    // Transaction request (from AXI wrapper)
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
    output logic [PADDR_W-1:0]          txn_paddr,

    // IOMMU enable (from register file)
    input  logic                        iommu_enable,

    // Device context table base (from register file)
    input  logic [PPN_W-1:0]            dct_base_ppn,

    // Memory read interface (to AXI master arbiter)
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

    // ==================== Core FSM ====================
    typedef enum logic [3:0] {
        CORE_IDLE,
        CORE_BYPASS,
        CORE_DC_LOOKUP,
        CORE_DC_FETCH_REQ,
        CORE_DC_FETCH_WAIT_W0,
        CORE_DC_FETCH_REQ_W1,
        CORE_DC_FETCH_WAIT_W1,
        CORE_DC_CHECK,
        CORE_IOTLB_LOOKUP,
        CORE_PTW_WALK,
        CORE_PTW_WAIT,
        CORE_TRANSLATE,
        CORE_FAULT,
        CORE_DONE
    } core_state_t;

    core_state_t state, state_next;

    // Latched transaction
    logic [DEVICE_ID_W-1:0] r_device_id;
    logic [VADDR_W-1:0]     r_vaddr;
    logic                   r_is_read, r_is_write;
    logic [VPN_W-1:0]       r_vpn1, r_vpn0;
    logic [PAGE_OFFSET_W-1:0] r_page_offset;

    // Latched device context
    device_context_t r_ctx;
    logic [31:0] r_dc_word0;

    // Latched translation result
    logic [PPN_W-1:0]  r_ppn;
    logic               r_is_superpage;
    logic [3:0]         r_fault_cause;

    // ==================== IOTLB signals ====================
    logic                        iotlb_lookup_valid;
    logic                        iotlb_lookup_ready;
    logic                        iotlb_lookup_hit;
    logic [PPN_W-1:0]            iotlb_lookup_ppn;
    logic                        iotlb_lookup_perm_r;
    logic                        iotlb_lookup_perm_w;
    logic                        iotlb_lookup_is_superpage;
    logic                        iotlb_refill_valid;
    logic                        iotlb_perf_hit;
    logic                        iotlb_perf_miss;

    // ==================== DC cache signals ====================
    logic                        dc_lookup_valid;
    logic                        dc_lookup_ready;
    logic                        dc_lookup_hit;
    device_context_t             dc_lookup_ctx;
    logic                        dc_refill_valid;

    // ==================== PTW signals ====================
    logic                        ptw_walk_req_valid;
    logic                        ptw_walk_req_ready;
    logic                        ptw_walk_done;
    logic                        ptw_walk_fault;
    logic [3:0]                  ptw_walk_fault_cause;
    logic [PPN_W-1:0]            ptw_walk_ppn;
    logic                        ptw_walk_perm_r;
    logic                        ptw_walk_perm_w;
    logic                        ptw_walk_is_superpage;
    logic                        ptw_mem_rd_req_valid;
    logic                        ptw_mem_rd_req_ready;
    logic [PADDR_W-1:0]          ptw_mem_rd_addr;

    // ==================== Permission checker signals ====================
    logic                        pchk_ctx_valid;
    logic                        pchk_ctx_fault;
    logic [3:0]                  pchk_ctx_fault_cause;
    logic                        pchk_needs_translation;

    // ==================== Memory read mux ====================
    // Core-level memory reads (DC fetch) vs PTW memory reads
    logic                        core_mem_rd_req_valid;
    logic [PADDR_W-1:0]          core_mem_rd_addr_reg;
    logic                        use_ptw_mem;

    assign use_ptw_mem = (state == CORE_PTW_WALK || state == CORE_PTW_WAIT);

    assign mem_rd_req_valid = use_ptw_mem ? ptw_mem_rd_req_valid : core_mem_rd_req_valid;
    assign mem_rd_addr      = use_ptw_mem ? ptw_mem_rd_addr      : core_mem_rd_addr_reg;
    assign ptw_mem_rd_req_ready = use_ptw_mem ? mem_rd_req_ready : 1'b0;
    assign mem_rd_resp_ready = 1'b1; // Always ready to accept responses

    // ==================== Submodule control via assigns ====================
    // These break the combinational feedback loop between iommu_core's always @(*)
    // and submodule always @(*) blocks in iverilog.
    assign dc_lookup_valid     = (state == CORE_DC_LOOKUP);
    assign dc_refill_valid     = (state == CORE_DC_CHECK);
    assign iotlb_lookup_valid  = (state == CORE_IOTLB_LOOKUP);
    assign iotlb_refill_valid  = (state == CORE_PTW_WAIT) && ptw_walk_done && !ptw_walk_fault;
    assign ptw_walk_req_valid  = (state == CORE_PTW_WALK);

    // core_mem_rd_req_valid and core_mem_rd_addr_reg are driven in the always @(*)
    // block below (they don't cause feedback loops since mem_rd_req_ready is registered).

    // ==================== Submodule Instantiations ====================

    iotlb u_iotlb (
        .clk              (clk),
        .srst             (srst),
        .lookup_valid     (iotlb_lookup_valid),
        .lookup_ready     (iotlb_lookup_ready),
        .lookup_device_id (r_device_id),
        .lookup_vpn1      (r_vpn1),
        .lookup_vpn0      (r_vpn0),
        .lookup_hit       (iotlb_lookup_hit),
        .lookup_ppn       (iotlb_lookup_ppn),
        .lookup_perm_r    (iotlb_lookup_perm_r),
        .lookup_perm_w    (iotlb_lookup_perm_w),
        .lookup_is_superpage(iotlb_lookup_is_superpage),
        .refill_valid     (iotlb_refill_valid),
        .refill_device_id (r_device_id),
        .refill_vpn1      (r_vpn1),
        .refill_vpn0      (r_vpn0),
        .refill_ppn       (ptw_walk_ppn),
        .refill_perm_r    (ptw_walk_perm_r),
        .refill_perm_w    (ptw_walk_perm_w),
        .refill_is_superpage(ptw_walk_is_superpage),
        .inv_valid        (iotlb_inv_valid),
        .inv_device_id    (iotlb_inv_device_id),
        .inv_all          (iotlb_inv_all),
        .perf_hit         (iotlb_perf_hit),
        .perf_miss        (iotlb_perf_miss)
    );

    device_context_cache u_dc_cache (
        .clk              (clk),
        .srst             (srst),
        .lookup_valid     (dc_lookup_valid),
        .lookup_ready     (dc_lookup_ready),
        .lookup_device_id (r_device_id),
        .lookup_hit       (dc_lookup_hit),
        .lookup_ctx       (dc_lookup_ctx),
        .refill_valid     (dc_refill_valid),
        .refill_device_id (r_device_id),
        .refill_ctx       (r_ctx),
        .inv_valid        (dc_inv_valid),
        .inv_device_id    (dc_inv_device_id),
        .inv_all          (dc_inv_all)
    );

    io_ptw u_ptw (
        .clk              (clk),
        .srst             (srst),
        .walk_req_valid   (ptw_walk_req_valid),
        .walk_req_ready   (ptw_walk_req_ready),
        .walk_device_id   (r_device_id),
        .walk_vpn1        (r_vpn1),
        .walk_vpn0        (r_vpn0),
        .walk_pt_root_ppn (r_ctx.pt_root_ppn),
        .walk_is_read     (r_is_read),
        .walk_is_write    (r_is_write),
        .walk_done        (ptw_walk_done),
        .walk_fault       (ptw_walk_fault),
        .walk_fault_cause (ptw_walk_fault_cause),
        .walk_ppn         (ptw_walk_ppn),
        .walk_perm_r      (ptw_walk_perm_r),
        .walk_perm_w      (ptw_walk_perm_w),
        .walk_is_superpage(ptw_walk_is_superpage),
        .mem_rd_req_valid (ptw_mem_rd_req_valid),
        .mem_rd_req_ready (ptw_mem_rd_req_ready),
        .mem_rd_addr      (ptw_mem_rd_addr),
        .mem_rd_resp_valid(use_ptw_mem ? mem_rd_resp_valid : 1'b0),
        .mem_rd_resp_ready(),
        .mem_rd_data      (mem_rd_data),
        .mem_rd_error     (mem_rd_error)
    );

    io_permission_checker u_pchk (
        .ctx              (r_ctx),
        .is_read          (r_is_read),
        .is_write         (r_is_write),
        .ctx_valid        (pchk_ctx_valid),
        .ctx_fault        (pchk_ctx_fault),
        .ctx_fault_cause  (pchk_ctx_fault_cause),
        .needs_translation(pchk_needs_translation)
    );

    // ==================== State Register ====================
    always_ff @(posedge clk) begin
        if (srst)
            state <= CORE_IDLE;
        else
            state <= state_next;
    end

    // ==================== Latch transaction on acceptance ====================
    always_ff @(posedge clk) begin
        if (srst) begin
            r_device_id   <= '0;
            r_vaddr       <= '0;
            r_is_read     <= 1'b0;
            r_is_write    <= 1'b0;
            r_vpn1        <= '0;
            r_vpn0        <= '0;
            r_page_offset <= '0;
        end else if (txn_valid && txn_ready) begin
            r_device_id   <= txn_device_id;
            r_vaddr       <= txn_vaddr;
            r_is_read     <= txn_is_read;
            r_is_write    <= txn_is_write;
            r_vpn1        <= txn_vaddr[VADDR_W-1 -: VPN_W];
            r_vpn0        <= txn_vaddr[PAGE_OFFSET_W +: VPN_W];
            r_page_offset <= txn_vaddr[PAGE_OFFSET_W-1:0];
        end
    end

    // ==================== DC fetch latching ====================
    always_ff @(posedge clk) begin
        if (srst) begin
            r_dc_word0 <= '0;
            r_ctx      <= '0;
        end else begin
            // Latch DC from cache hit
            if (state == CORE_DC_LOOKUP && dc_lookup_hit) begin
                r_ctx <= dc_lookup_ctx;
            end
            // Latch word 0 from memory
            if (state == CORE_DC_FETCH_WAIT_W0 && mem_rd_resp_valid && !mem_rd_error) begin
                r_dc_word0 <= mem_rd_data;
            end
            // Latch word 1 and assemble context
            if (state == CORE_DC_FETCH_WAIT_W1 && mem_rd_resp_valid && !mem_rd_error) begin
                r_ctx <= {mem_rd_data, r_dc_word0};
            end
        end
    end

    // ==================== Translation result latching ====================
    always_ff @(posedge clk) begin
        if (srst) begin
            r_ppn         <= '0;
            r_is_superpage <= 1'b0;
            r_fault_cause <= CAUSE_NONE;
        end else begin
            if (state == CORE_IOTLB_LOOKUP && iotlb_lookup_hit) begin
                r_ppn          <= iotlb_lookup_ppn;
                r_is_superpage <= iotlb_lookup_is_superpage;
            end
            if (state == CORE_PTW_WAIT && ptw_walk_done && !ptw_walk_fault) begin
                r_ppn          <= ptw_walk_ppn;
                r_is_superpage <= ptw_walk_is_superpage;
            end
            if (state == CORE_PTW_WAIT && ptw_walk_done && ptw_walk_fault) begin
                r_fault_cause <= ptw_walk_fault_cause;
            end
            if (state == CORE_DC_CHECK && pchk_ctx_fault) begin
                r_fault_cause <= pchk_ctx_fault_cause;
            end
            if (state == CORE_DC_FETCH_WAIT_W0 && mem_rd_resp_valid && mem_rd_error) begin
                r_fault_cause <= CAUSE_PTW_ACCESS_FAULT;
            end
            if (state == CORE_DC_FETCH_WAIT_W1 && mem_rd_resp_valid && mem_rd_error) begin
                r_fault_cause <= CAUSE_PTW_ACCESS_FAULT;
            end
        end
    end

    // ==================== Next-State Logic ====================
    // Reads submodule outputs -- uses always @(*) per coding convention
    always @(*) begin
        state_next          = state;
        txn_ready           = 1'b0;
        txn_done            = 1'b0;
        txn_fault           = 1'b0;
        txn_fault_cause     = CAUSE_NONE;
        txn_paddr           = '0;
        fault_valid         = 1'b0;
        fault_record        = '0;
        core_mem_rd_req_valid = 1'b0;
        core_mem_rd_addr_reg  = '0;

        case (state)
            CORE_IDLE: begin
                txn_ready = 1'b1;
                if (txn_valid) begin
                    if (!iommu_enable)
                        state_next = CORE_BYPASS;
                    else
                        state_next = CORE_DC_LOOKUP;
                end
            end

            CORE_BYPASS: begin
                txn_done  = 1'b1;
                txn_paddr = {{(PADDR_W-VADDR_W){1'b0}}, r_vaddr};
                state_next = CORE_IDLE;
            end

            CORE_DC_LOOKUP: begin
                if (dc_lookup_hit)
                    state_next = CORE_DC_CHECK;
                else
                    state_next = CORE_DC_FETCH_REQ;
            end

            CORE_DC_FETCH_REQ: begin
                core_mem_rd_req_valid = 1'b1;
                core_mem_rd_addr_reg = {dct_base_ppn, 12'b0} +
                    {{(PADDR_W-DEVICE_ID_W-3){1'b0}}, r_device_id, 3'b000};
                if (mem_rd_req_ready)
                    state_next = CORE_DC_FETCH_WAIT_W0;
            end

            CORE_DC_FETCH_WAIT_W0: begin
                if (mem_rd_resp_valid) begin
                    if (mem_rd_error)
                        state_next = CORE_FAULT;
                    else
                        state_next = CORE_DC_FETCH_REQ_W1;
                end
            end

            CORE_DC_FETCH_REQ_W1: begin
                core_mem_rd_req_valid = 1'b1;
                core_mem_rd_addr_reg = {dct_base_ppn, 12'b0} +
                    {{(PADDR_W-DEVICE_ID_W-3){1'b0}}, r_device_id, 3'b000} +
                    {{(PADDR_W-3){1'b0}}, 3'd4};
                if (mem_rd_req_ready)
                    state_next = CORE_DC_FETCH_WAIT_W1;
            end

            CORE_DC_FETCH_WAIT_W1: begin
                if (mem_rd_resp_valid) begin
                    if (mem_rd_error)
                        state_next = CORE_FAULT;
                    else begin
                        state_next = CORE_DC_CHECK;
                    end
                end
            end

            CORE_DC_CHECK: begin
                if (pchk_ctx_fault) begin
                    state_next = CORE_FAULT;
                end else if (!pchk_needs_translation) begin
                    state_next = CORE_BYPASS;
                end else begin
                    state_next = CORE_IOTLB_LOOKUP;
                end
            end

            CORE_IOTLB_LOOKUP: begin
                if (iotlb_lookup_hit)
                    state_next = CORE_TRANSLATE;
                else
                    state_next = CORE_PTW_WALK;
            end

            CORE_PTW_WALK: begin
                if (ptw_walk_req_ready)
                    state_next = CORE_PTW_WAIT;
            end

            CORE_PTW_WAIT: begin
                if (ptw_walk_done) begin
                    if (ptw_walk_fault)
                        state_next = CORE_FAULT;
                    else begin
                        state_next = CORE_TRANSLATE;
                    end
                end
            end

            CORE_TRANSLATE: begin
                txn_done = 1'b1;
                if (r_is_superpage) begin
                    txn_paddr = {r_ppn[PPN_W-1:VPN_W], r_vaddr[VPN_W+PAGE_OFFSET_W-1:0]};
                end else begin
                    txn_paddr = {r_ppn, r_page_offset};
                end
                state_next = CORE_IDLE;
            end

            CORE_FAULT: begin
                fault_valid = 1'b1;
                fault_record.valid         = 1'b1;
                fault_record.is_read       = r_is_read;
                fault_record.is_write      = r_is_write;
                fault_record.reserved0     = 1'b0;
                fault_record.cause         = r_fault_cause;
                fault_record.device_id     = r_device_id;
                fault_record.reserved1     = 16'b0;
                fault_record.faulting_addr = r_vaddr;

                if (fault_ready)
                    state_next = CORE_DONE;
            end

            CORE_DONE: begin
                txn_done        = 1'b1;
                txn_fault       = 1'b1;
                txn_fault_cause = r_fault_cause;
                state_next      = CORE_IDLE;
            end
        endcase
    end

    // Performance counters
    assign perf_iotlb_hit  = iotlb_perf_hit;
    assign perf_iotlb_miss = iotlb_perf_miss;
    assign perf_fault      = (state == CORE_FAULT) && fault_valid && fault_ready;

endmodule
