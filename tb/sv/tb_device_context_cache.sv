// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_device_context_cache;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Command signals (driven by tasks, relayed to DUT via always block)
    logic                        cmd_lookup_valid;
    logic [DEVICE_ID_W-1:0]      cmd_lookup_device_id;
    logic                        cmd_refill_valid;
    logic [DEVICE_ID_W-1:0]      cmd_refill_device_id;
    device_context_t             cmd_refill_ctx;
    logic                        cmd_inv_valid;
    logic [DEVICE_ID_W-1:0]      cmd_inv_device_id;
    logic                        cmd_inv_all;

    // DUT port signals
    logic                        lookup_valid;
    logic                        lookup_ready;
    logic [DEVICE_ID_W-1:0]      lookup_device_id;
    logic                        lookup_hit;
    device_context_t             lookup_ctx;
    logic                        refill_valid;
    logic [DEVICE_ID_W-1:0]      refill_device_id;
    device_context_t             refill_ctx;
    logic                        inv_valid;
    logic [DEVICE_ID_W-1:0]      inv_device_id;
    logic                        inv_all;

    // Relay command signals to DUT ports (iverilog workaround)
    always @(*) begin
        lookup_valid     = cmd_lookup_valid;
        lookup_device_id = cmd_lookup_device_id;
        refill_valid     = cmd_refill_valid;
        refill_device_id = cmd_refill_device_id;
        refill_ctx       = cmd_refill_ctx;
        inv_valid        = cmd_inv_valid;
        inv_device_id    = cmd_inv_device_id;
        inv_all          = cmd_inv_all;
    end

    // DUT instantiation
    device_context_cache #(.DEPTH(DC_CACHE_DEPTH)) dut (
        .clk             (clk),
        .srst            (srst),
        .lookup_valid    (lookup_valid),
        .lookup_ready    (lookup_ready),
        .lookup_device_id(lookup_device_id),
        .lookup_hit      (lookup_hit),
        .lookup_ctx      (lookup_ctx),
        .refill_valid    (refill_valid),
        .refill_device_id(refill_device_id),
        .refill_ctx      (refill_ctx),
        .inv_valid       (inv_valid),
        .inv_device_id   (inv_device_id),
        .inv_all         (inv_all)
    );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst                 = 1;
        cmd_lookup_valid     = 0;
        cmd_lookup_device_id = 0;
        cmd_refill_valid     = 0;
        cmd_refill_device_id = 0;
        cmd_refill_ctx       = '0;
        cmd_inv_valid        = 0;
        cmd_inv_device_id    = 0;
        cmd_inv_all          = 0;
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

    // Build a device_context_t
    function automatic device_context_t make_ctx(
        input logic [31:0]      reserved_w1,
        input logic [PPN_W-1:0] pt_root_ppn,
        input logic [1:0]       rsv,
        input logic [3:0]       mode,
        input logic             fp,
        input logic             wp,
        input logic             rp,
        input logic             en
    );
        device_context_t ctx;
        ctx.reserved_w1 = reserved_w1;
        ctx.pt_root_ppn = pt_root_ppn;
        ctx.rsv         = rsv;
        ctx.mode        = mode;
        ctx.fp          = fp;
        ctx.wp          = wp;
        ctx.rp          = rp;
        ctx.en          = en;
        return ctx;
    endfunction

    // Refill helper
    task automatic do_refill(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input device_context_t        ctx
    );
        cmd_refill_valid     = 1;
        cmd_refill_device_id = dev_id;
        cmd_refill_ctx       = ctx;
        @(posedge clk);
        cmd_refill_valid     = 0;
        @(posedge clk);
    endtask

    // Lookup helper
    task automatic do_lookup(
        input  logic [DEVICE_ID_W-1:0] dev_id,
        output logic                   hit,
        output device_context_t        ctx
    );
        cmd_lookup_valid     = 1;
        cmd_lookup_device_id = dev_id;
        #1;  // allow combinational settle
        hit = lookup_hit;
        ctx = lookup_ctx;
        @(posedge clk);  // LRU updated on this edge if hit
        cmd_lookup_valid     = 0;
        @(posedge clk);
    endtask

    // Refill+lookup: refill then lookup to trigger LRU update
    task automatic refill_and_touch(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input device_context_t        ctx
    );
        logic            dummy_hit;
        device_context_t dummy_ctx;
        do_refill(dev_id, ctx);
        do_lookup(dev_id, dummy_hit, dummy_ctx);
    endtask

    // Temporary variables for lookup results
    logic            t_hit;
    device_context_t t_ctx;

    // ---------------------------------------------------------------
    // Test 1: Reset — all misses
    // ---------------------------------------------------------------
    task automatic test_reset();
        reset_dut();
        cmd_lookup_valid     = 1;
        cmd_lookup_device_id = 8'h01;
        #1;
        check("Reset -- lookup misses after reset", lookup_hit == 0);
        cmd_lookup_valid = 0;
        @(posedge clk);
    endtask

    // ---------------------------------------------------------------
    // Test 2: Single refill + hit
    // ---------------------------------------------------------------
    task automatic test_single_refill_hit();
        device_context_t ctx_in;
        reset_dut();
        ctx_in = make_ctx(32'h0, 22'h2ABCDE, 2'b00, MODE_SV32, 0, 1, 1, 1);
        do_refill(8'h05, ctx_in);
        do_lookup(8'h05, t_hit, t_ctx);
        check("Single refill + hit -- lookup hits after refill",
              t_hit == 1);
        check("Single refill + hit -- context data matches",
              t_ctx.pt_root_ppn == 22'h2ABCDE &&
              t_ctx.mode == MODE_SV32 &&
              t_ctx.en == 1 &&
              t_ctx.rp == 1 &&
              t_ctx.wp == 1);
    endtask

    // ---------------------------------------------------------------
    // Test 3: Multiple devices — independent entries
    // ---------------------------------------------------------------
    task automatic test_multiple_devices();
        device_context_t ctx_a, ctx_b;
        reset_dut();
        ctx_a = make_ctx(32'h0, 22'h111111, 2'b00, MODE_SV32, 0, 1, 1, 1);
        ctx_b = make_ctx(32'h0, 22'h222222, 2'b00, MODE_BARE, 0, 0, 1, 1);

        refill_and_touch(8'h0A, ctx_a);
        do_refill(8'h0B, ctx_b);

        do_lookup(8'h0A, t_hit, t_ctx);
        check("Multiple devices -- device 0x0A hits",
              t_hit == 1 && t_ctx.pt_root_ppn == 22'h111111);

        do_lookup(8'h0B, t_hit, t_ctx);
        check("Multiple devices -- device 0x0B hits with correct data",
              t_hit == 1 && t_ctx.pt_root_ppn == 22'h222222 && t_ctx.mode == MODE_BARE);

        do_lookup(8'h0C, t_hit, t_ctx);
        check("Multiple devices -- non-existent device misses",
              t_hit == 0);
    endtask

    // ---------------------------------------------------------------
    // Test 4: Capacity eviction — fill all entries, add one more
    // ---------------------------------------------------------------
    task automatic test_capacity_eviction();
        integer i;
        device_context_t ctx_i;
        reset_dut();

        for (i = 0; i < DC_CACHE_DEPTH; i = i + 1) begin
            ctx_i = make_ctx(32'h0, i[21:0], 2'b00, MODE_SV32, 0, 1, 1, 1);
            refill_and_touch(i[7:0], ctx_i);
        end

        do_lookup(8'h00, t_hit, t_ctx);
        check("Capacity eviction -- entry 0 present before overflow",
              t_hit == 1 && t_ctx.pt_root_ppn == 22'h000000);

        ctx_i = make_ctx(32'h0, 22'h3FFFFF, 2'b00, MODE_SV32, 0, 1, 1, 1);
        do_refill(8'h08, ctx_i);

        do_lookup(8'h08, t_hit, t_ctx);
        check("Capacity eviction -- new entry present after overflow",
              t_hit == 1 && t_ctx.pt_root_ppn == 22'h3FFFFF);
    endtask

    // ---------------------------------------------------------------
    // Test 5: Invalidate by device ID
    // ---------------------------------------------------------------
    task automatic test_invalidate_by_device_id();
        device_context_t ctx_a, ctx_b;
        reset_dut();
        ctx_a = make_ctx(32'h0, 22'h0AAAAA, 2'b00, MODE_SV32, 0, 1, 1, 1);
        ctx_b = make_ctx(32'h0, 22'h0BBBBB, 2'b00, MODE_SV32, 0, 1, 1, 1);

        refill_and_touch(8'h0A, ctx_a);
        do_refill(8'h0B, ctx_b);

        cmd_inv_valid     = 1;
        cmd_inv_device_id = 8'h0A;
        cmd_inv_all       = 0;
        @(posedge clk);
        cmd_inv_valid     = 0;
        @(posedge clk);

        do_lookup(8'h0A, t_hit, t_ctx);
        check("Invalidate by device ID -- device 0x0A misses", t_hit == 0);

        do_lookup(8'h0B, t_hit, t_ctx);
        check("Invalidate by device ID -- device 0x0B still hits",
              t_hit == 1 && t_ctx.pt_root_ppn == 22'h0BBBBB);
    endtask

    // ---------------------------------------------------------------
    // Test 6: Invalidate all
    // ---------------------------------------------------------------
    task automatic test_invalidate_all();
        device_context_t ctx_a, ctx_b;
        reset_dut();
        ctx_a = make_ctx(32'h0, 22'h0AAAAA, 2'b00, MODE_SV32, 0, 1, 1, 1);
        ctx_b = make_ctx(32'h0, 22'h0BBBBB, 2'b00, MODE_SV32, 0, 1, 1, 1);

        refill_and_touch(8'h0A, ctx_a);
        do_refill(8'h0B, ctx_b);

        cmd_inv_valid = 1;
        cmd_inv_all   = 1;
        @(posedge clk);
        cmd_inv_valid = 0;
        cmd_inv_all   = 0;
        @(posedge clk);

        do_lookup(8'h0A, t_hit, t_ctx);
        check("Invalidate all -- device 0x0A misses after inv_all", t_hit == 0);

        do_lookup(8'h0B, t_hit, t_ctx);
        check("Invalidate all -- device 0x0B misses after inv_all", t_hit == 0);
    endtask

    // ---------------------------------------------------------------
    // Test 7: Context fields — verify all fields round-trip correctly
    // ---------------------------------------------------------------
    task automatic test_context_fields();
        device_context_t ctx_full;
        reset_dut();

        ctx_full = make_ctx(
            32'hDEADBEEF,  // reserved_w1
            22'h3ABCDE,    // pt_root_ppn
            2'b11,         // rsv
            MODE_SV32,     // mode
            1,             // fp
            1,             // wp
            1,             // rp
            1              // en
        );
        do_refill(8'hFF, ctx_full);
        do_lookup(8'hFF, t_hit, t_ctx);

        check("Context fields -- hit after refill", t_hit == 1);
        check("Context fields -- reserved_w1 round-trips",
              t_ctx.reserved_w1 == 32'hDEADBEEF);
        check("Context fields -- pt_root_ppn round-trips",
              t_ctx.pt_root_ppn == 22'h3ABCDE);
        check("Context fields -- rsv round-trips",
              t_ctx.rsv == 2'b11);
        check("Context fields -- mode round-trips",
              t_ctx.mode == MODE_SV32);
        check("Context fields -- fp round-trips", t_ctx.fp == 1);
        check("Context fields -- wp round-trips", t_ctx.wp == 1);
        check("Context fields -- rp round-trips", t_ctx.rp == 1);
        check("Context fields -- en round-trips", t_ctx.en == 1);
    endtask

    // Main
    initial begin
        $dumpfile("tb_device_context_cache.vcd");
        $dumpvars(0, tb_device_context_cache);

        test_reset();
        test_single_refill_hit();
        test_multiple_devices();
        test_capacity_eviction();
        test_invalidate_by_device_id();
        test_invalidate_all();
        test_context_fields();

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
