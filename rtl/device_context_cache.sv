// Brendan Lynskey 2025
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

    localparam int IDX_W = $clog2(DEPTH);

    // Entry storage
    logic [DEPTH-1:0]           entry_valid;
    logic [DEVICE_ID_W-1:0]     entry_device_id [DEPTH];
    device_context_t            entry_ctx       [DEPTH];

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
                match_vec[mi] = (entry_device_id[mi] == lookup_device_id);
            end
        end
    end

    // Priority encoder
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
    assign lookup_ctx   = entry_ctx[hit_idx];

    // LRU update on hit
    assign lru_access_valid = lookup_hit;
    assign lru_access_idx   = hit_idx;

    // Refill and invalidation
    integer ri;
    always_ff @(posedge clk) begin
        if (srst) begin
            entry_valid <= '0;
        end else begin
            // Invalidation
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
                entry_ctx      [lru_victim_idx] <= refill_ctx;
            end
        end
    end

endmodule
