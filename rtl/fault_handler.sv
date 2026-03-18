// Brendan Lynskey 2025
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
    input  logic                        head_inc,
    output logic [$clog2(DEPTH)-1:0]    head,
    output logic [$clog2(DEPTH)-1:0]    tail,
    output logic                        fault_pending,
    output logic                        queue_full,

    // Read data output for software
    output fault_record_t               read_data,

    // Performance
    output logic                        perf_fault
);

    localparam int IDX_W = $clog2(DEPTH);

    // Circular buffer storage
    fault_record_t queue [DEPTH];

    logic [IDX_W-1:0] r_head, r_tail;
    logic [IDX_W-1:0] tail_plus_one;

    assign tail_plus_one = (r_tail + 1) & (DEPTH[IDX_W-1:0] - 1);
    assign queue_full    = (tail_plus_one == r_head);
    assign fault_pending = (r_tail != r_head);
    assign fault_ready   = !queue_full;
    assign head          = r_head;
    assign tail          = r_tail;
    assign read_data     = queue[r_head];
    assign perf_fault    = fault_valid && fault_ready;

    always_ff @(posedge clk) begin
        if (srst) begin
            r_head <= '0;
            r_tail <= '0;
        end else begin
            // Write new fault record
            if (fault_valid && fault_ready) begin
                queue[r_tail] <= fault_record;
                r_tail <= tail_plus_one;
            end

            // Software advances head
            if (head_inc && fault_pending) begin
                r_head <= (r_head + 1) & (DEPTH[IDX_W-1:0] - 1);
            end
        end
    end

endmodule
