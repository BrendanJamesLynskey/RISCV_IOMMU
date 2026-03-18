// Brendan Lynskey 2025
module lru_tracker #(
    parameter int DEPTH = 16
)(
    input  logic                    clk,
    input  logic                    srst,
    input  logic                    access_valid,
    input  logic [$clog2(DEPTH)-1:0] access_idx,
    output logic [$clog2(DEPTH)-1:0] lru_idx
);

    localparam int IDX_W = $clog2(DEPTH);

    // Tree-based pseudo-LRU using DEPTH-1 bits
    logic [DEPTH-2:0] tree;

    // On access: walk leaf-to-root, set each node to point AWAY from accessed entry
    integer node_wr, bit_sel;
    always_ff @(posedge clk) begin
        if (srst) begin
            tree <= '0;
        end else if (access_valid) begin
            for (int level = 0; level < IDX_W; level++) begin
                node_wr = (1 << (IDX_W - 1 - level)) - 1 + (access_idx >> (level + 1));
                bit_sel = (access_idx >> level) & 1;
                tree[node_wr] <= ~bit_sel[0];
            end
        end
    end

    // Walk the tree top-down to find LRU entry
    integer node_rd;
    always @(*) begin
        lru_idx = '0;
        node_rd = 0;
        for (int level = 0; level < IDX_W; level++) begin
            if (tree[node_rd] == 1'b0) begin
                lru_idx[IDX_W - 1 - level] = 1'b0;
                node_rd = 2 * node_rd + 1;
            end else begin
                lru_idx[IDX_W - 1 - level] = 1'b1;
                node_rd = 2 * node_rd + 2;
            end
        end
    end

endmodule
