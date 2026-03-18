// Brendan Lynskey 2025
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

    localparam int IDX_W = $clog2(DEPTH);

    // Entry storage
    logic [DEPTH-1:0]           entry_valid;
    logic [DEVICE_ID_W-1:0]     entry_device_id [DEPTH];
    logic [VPN_W-1:0]           entry_vpn1      [DEPTH];
    logic [VPN_W-1:0]           entry_vpn0      [DEPTH];
    logic [PPN_W-1:0]           entry_ppn       [DEPTH];
    logic [DEPTH-1:0]           entry_perm_r;
    logic [DEPTH-1:0]           entry_perm_w;
    logic [DEPTH-1:0]           entry_superpage;

    // LRU tracker
    logic                       lru_access_valid;
    logic [IDX_W-1:0]           lru_access_idx;
    logic [IDX_W-1:0]           lru_victim_idx;

    lru_tracker #(.DEPTH(DEPTH)) u_lru (
        .clk         (clk),
        .srst        (srst),
        .access_valid(lru_access_valid),
        .access_idx  (lru_access_idx),
        .lru_idx     (lru_victim_idx)
    );

    // Lookup: combinational CAM match
    logic [DEPTH-1:0] match_vec;
    logic             any_hit;
    logic [IDX_W-1:0] hit_idx;

    integer mi;
    always @(*) begin
        match_vec = '0;
        for (mi = 0; mi < DEPTH; mi = mi + 1) begin
            if (entry_valid[mi]) begin
                if (entry_superpage[mi]) begin
                    // Superpage: match device_id + vpn1 only
                    match_vec[mi] = (entry_device_id[mi] == lookup_device_id) &&
                                    (entry_vpn1[mi] == lookup_vpn1);
                end else begin
                    // Standard page: match device_id + vpn1 + vpn0
                    match_vec[mi] = (entry_device_id[mi] == lookup_device_id) &&
                                    (entry_vpn1[mi] == lookup_vpn1) &&
                                    (entry_vpn0[mi] == lookup_vpn0);
                end
            end
        end
    end

    // Priority encoder to find hit index
    integer hi;
    always @(*) begin
        any_hit = 1'b0;
        hit_idx = '0;
        for (hi = 0; hi < DEPTH; hi = hi + 1) begin
            if (match_vec[hi] && !any_hit) begin
                any_hit = 1'b1;
                hit_idx = hi[IDX_W-1:0];
            end
        end
    end

    assign lookup_ready = 1'b1;
    assign lookup_hit   = lookup_valid && any_hit;

    // Output mux
    always @(*) begin
        lookup_ppn         = entry_ppn[hit_idx];
        lookup_perm_r      = entry_perm_r[hit_idx];
        lookup_perm_w      = entry_perm_w[hit_idx];
        lookup_is_superpage = entry_superpage[hit_idx];
    end

    // LRU update on hit
    assign lru_access_valid = lookup_hit;
    assign lru_access_idx   = hit_idx;

    // Performance counters
    assign perf_hit  = lookup_valid && any_hit;
    assign perf_miss = lookup_valid && !any_hit;

    // Refill and invalidation
    integer ri;
    always_ff @(posedge clk) begin
        if (srst) begin
            entry_valid <= '0;
            entry_perm_r <= '0;
            entry_perm_w <= '0;
            entry_superpage <= '0;
        end else begin
            // Invalidation (higher priority than refill)
            if (inv_valid) begin
                if (inv_all) begin
                    entry_valid <= '0;
                end else begin
                    for (ri = 0; ri < DEPTH; ri = ri + 1) begin
                        if (entry_device_id[ri] == inv_device_id) begin
                            entry_valid[ri] <= 1'b0;
                        end
                    end
                end
            end

            // Refill into LRU slot
            if (refill_valid) begin
                entry_valid    [lru_victim_idx] <= 1'b1;
                entry_device_id[lru_victim_idx] <= refill_device_id;
                entry_vpn1     [lru_victim_idx] <= refill_vpn1;
                entry_vpn0     [lru_victim_idx] <= refill_vpn0;
                entry_ppn      [lru_victim_idx] <= refill_ppn;
                entry_perm_r   [lru_victim_idx] <= refill_perm_r;
                entry_perm_w   [lru_victim_idx] <= refill_perm_w;
                entry_superpage[lru_victim_idx] <= refill_is_superpage;
            end
        end
    end

endmodule
