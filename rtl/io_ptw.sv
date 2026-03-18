// Brendan Lynskey 2025
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
    input  logic [PPN_W-1:0]            walk_pt_root_ppn,
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

    // FSM states
    typedef enum logic [2:0] {
        PTW_IDLE,
        PTW_L1_REQ,
        PTW_L1_WAIT,
        PTW_L1_CHECK,
        PTW_L0_REQ,
        PTW_L0_WAIT,
        PTW_L0_CHECK,
        PTW_DONE
    } ptw_state_t;

    ptw_state_t state, state_next;

    // Latched request
    logic [DEVICE_ID_W-1:0] r_device_id;
    logic [VPN_W-1:0]       r_vpn1, r_vpn0;
    logic [PPN_W-1:0]       r_pt_root_ppn;
    logic                   r_is_read, r_is_write;

    // Latched PTE from memory
    logic [31:0]            r_pte;

    // Result registers
    logic                   r_fault;
    logic [3:0]             r_fault_cause;
    logic [PPN_W-1:0]       r_ppn;
    logic                   r_perm_r, r_perm_w;
    logic                   r_superpage;

    // PTE field extraction
    logic       pte_v, pte_r, pte_w, pte_x;
    logic [9:0] pte_ppn0;
    logic [11:0] pte_ppn1;

    assign pte_v    = r_pte[0];
    assign pte_r    = r_pte[1];
    assign pte_w    = r_pte[2];
    assign pte_x    = r_pte[3];
    assign pte_ppn0 = r_pte[19:10];
    assign pte_ppn1 = r_pte[31:20];

    wire pte_is_leaf = pte_v && (pte_r || pte_w || pte_x);
    wire pte_is_ptr  = pte_v && !pte_r && !pte_w && !pte_x;

    // State register
    always_ff @(posedge clk) begin
        if (srst)
            state <= PTW_IDLE;
        else
            state <= state_next;
    end

    // Latch request on acceptance
    always_ff @(posedge clk) begin
        if (srst) begin
            r_device_id    <= '0;
            r_vpn1         <= '0;
            r_vpn0         <= '0;
            r_pt_root_ppn  <= '0;
            r_is_read      <= 1'b0;
            r_is_write     <= 1'b0;
        end else if (walk_req_valid && walk_req_ready) begin
            r_device_id    <= walk_device_id;
            r_vpn1         <= walk_vpn1;
            r_vpn0         <= walk_vpn0;
            r_pt_root_ppn  <= walk_pt_root_ppn;
            r_is_read      <= walk_is_read;
            r_is_write     <= walk_is_write;
        end
    end

    // Latch PTE from memory response
    always_ff @(posedge clk) begin
        if (srst) begin
            r_pte <= '0;
        end else if (mem_rd_resp_valid && mem_rd_resp_ready) begin
            r_pte <= mem_rd_data;
        end
    end

    // Result registers
    always_ff @(posedge clk) begin
        if (srst) begin
            r_fault       <= 1'b0;
            r_fault_cause <= CAUSE_NONE;
            r_ppn         <= '0;
            r_perm_r      <= 1'b0;
            r_perm_w      <= 1'b0;
            r_superpage   <= 1'b0;
        end else begin
            case (state)
                PTW_L1_WAIT: begin
                    if (mem_rd_resp_valid && mem_rd_error) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTW_ACCESS_FAULT;
                    end
                end
                PTW_L1_CHECK: begin
                    if (!pte_v) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTE_INVALID;
                    end else if (pte_is_leaf) begin
                        // Superpage at level 1
                        if (pte_w && !pte_r) begin
                            // Invalid encoding: W=1, R=0
                            r_fault       <= 1'b1;
                            r_fault_cause <= CAUSE_PTE_INVALID;
                        end else if (pte_ppn0 != 10'b0) begin
                            r_fault       <= 1'b1;
                            r_fault_cause <= CAUSE_PTE_MISALIGNED;
                        end else if (r_is_read && !pte_r) begin
                            r_fault       <= 1'b1;
                            r_fault_cause <= CAUSE_READ_DENIED;
                        end else if (r_is_write && !pte_w) begin
                            r_fault       <= 1'b1;
                            r_fault_cause <= CAUSE_WRITE_DENIED;
                        end else begin
                            r_fault     <= 1'b0;
                            r_ppn       <= {pte_ppn1, pte_ppn0};
                            r_perm_r    <= pte_r;
                            r_perm_w    <= pte_w;
                            r_superpage <= 1'b1;
                        end
                    end
                    // Non-leaf: proceed to L0 (no result update needed)
                end
                PTW_L0_WAIT: begin
                    if (mem_rd_resp_valid && mem_rd_error) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTW_ACCESS_FAULT;
                    end
                end
                PTW_L0_CHECK: begin
                    if (!pte_v) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTE_INVALID;
                    end else if (!pte_is_leaf) begin
                        // Non-leaf at level 0 is invalid
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTE_INVALID;
                    end else if (pte_w && !pte_r) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_PTE_INVALID;
                    end else if (r_is_read && !pte_r) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_READ_DENIED;
                    end else if (r_is_write && !pte_w) begin
                        r_fault       <= 1'b1;
                        r_fault_cause <= CAUSE_WRITE_DENIED;
                    end else begin
                        r_fault     <= 1'b0;
                        r_ppn       <= {pte_ppn1, pte_ppn0};
                        r_perm_r    <= pte_r;
                        r_perm_w    <= pte_w;
                        r_superpage <= 1'b0;
                    end
                end
                PTW_IDLE: begin
                    r_fault       <= 1'b0;
                    r_fault_cause <= CAUSE_NONE;
                    r_superpage   <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // Next-state logic and output control
    always @(*) begin
        state_next       = state;
        walk_req_ready   = 1'b0;
        walk_done        = 1'b0;
        mem_rd_req_valid = 1'b0;
        mem_rd_addr      = '0;
        mem_rd_resp_ready = 1'b0;

        case (state)
            PTW_IDLE: begin
                walk_req_ready = 1'b1;
                if (walk_req_valid)
                    state_next = PTW_L1_REQ;
            end

            PTW_L1_REQ: begin
                mem_rd_req_valid = 1'b1;
                // L1 PTE address = {root_ppn, 12'b0} + (vpn1 * 4)
                mem_rd_addr = {r_pt_root_ppn, 12'b0} + {{PADDR_W-12{1'b0}}, r_vpn1, 2'b00};
                if (mem_rd_req_ready)
                    state_next = PTW_L1_WAIT;
            end

            PTW_L1_WAIT: begin
                mem_rd_resp_ready = 1'b1;
                if (mem_rd_resp_valid) begin
                    if (mem_rd_error)
                        state_next = PTW_DONE;
                    else
                        state_next = PTW_L1_CHECK;
                end
            end

            PTW_L1_CHECK: begin
                if (!pte_v) begin
                    state_next = PTW_DONE;
                end else if (pte_is_leaf) begin
                    state_next = PTW_DONE;
                end else if (pte_is_ptr) begin
                    state_next = PTW_L0_REQ;
                end else begin
                    state_next = PTW_DONE;
                end
            end

            PTW_L0_REQ: begin
                mem_rd_req_valid = 1'b1;
                // L0 PTE address = {pte_ppn, 12'b0} + (vpn0 * 4)
                mem_rd_addr = {{PADDR_W-PTE_W{1'b0}}, pte_ppn1, pte_ppn0, 12'b0} +
                              {{PADDR_W-12{1'b0}}, r_vpn0, 2'b00};
                if (mem_rd_req_ready)
                    state_next = PTW_L0_WAIT;
            end

            PTW_L0_WAIT: begin
                mem_rd_resp_ready = 1'b1;
                if (mem_rd_resp_valid) begin
                    if (mem_rd_error)
                        state_next = PTW_DONE;
                    else
                        state_next = PTW_L0_CHECK;
                end
            end

            PTW_L0_CHECK: begin
                state_next = PTW_DONE;
            end

            PTW_DONE: begin
                walk_done = 1'b1;
                state_next = PTW_IDLE;
            end
        endcase
    end

    // Output assignments
    assign walk_fault       = r_fault;
    assign walk_fault_cause = r_fault_cause;
    assign walk_ppn         = r_ppn;
    assign walk_perm_r      = r_perm_r;
    assign walk_perm_w      = r_perm_w;
    assign walk_is_superpage = r_superpage;

endmodule
