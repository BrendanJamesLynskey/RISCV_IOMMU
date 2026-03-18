// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_lru_tracker;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Command signals (driven by tasks)
    logic                       cmd_access_valid;
    logic [$clog2(16)-1:0]      cmd_access_idx;
    logic                       cmd_access_valid_4;
    logic [$clog2(4)-1:0]       cmd_access_idx_4;

    // DUT port signals (relayed from command signals)
    logic                       access_valid;
    logic [$clog2(16)-1:0]      access_idx;
    logic [$clog2(16)-1:0]      lru_idx;

    always @(*) begin
        access_valid = cmd_access_valid;
        access_idx   = cmd_access_idx;
    end

    // DUT instantiation (DEPTH=16)
    lru_tracker #(.DEPTH(16)) dut (
        .clk         (clk),
        .srst        (srst),
        .access_valid(access_valid),
        .access_idx  (access_idx),
        .lru_idx     (lru_idx)
    );

    // DUT port signals for DEPTH=4 instance
    logic                       access_valid_4;
    logic [$clog2(4)-1:0]       access_idx_4;
    logic [$clog2(4)-1:0]       lru_idx_4;

    always @(*) begin
        access_valid_4 = cmd_access_valid_4;
        access_idx_4   = cmd_access_idx_4;
    end

    // DUT instantiation (DEPTH=4)
    lru_tracker #(.DEPTH(4)) dut4 (
        .clk         (clk),
        .srst        (srst),
        .access_valid(access_valid_4),
        .access_idx  (access_idx_4),
        .lru_idx     (lru_idx_4)
    );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst = 1;
        cmd_access_valid   = 0;
        cmd_access_idx     = 0;
        cmd_access_valid_4 = 0;
        cmd_access_idx_4   = 0;
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

    // Access helper for DEPTH=16
    task automatic do_access(input logic [3:0] idx);
        cmd_access_valid = 1;
        cmd_access_idx   = idx;
        @(posedge clk);
        cmd_access_valid = 0;
        @(posedge clk);
    endtask

    // Access helper for DEPTH=4
    task automatic do_access_4(input logic [1:0] idx);
        cmd_access_valid_4 = 1;
        cmd_access_idx_4   = idx;
        @(posedge clk);
        cmd_access_valid_4 = 0;
        @(posedge clk);
    endtask

    // ---------------------------------------------------------------
    // Test 1: Reset — LRU index is 0 after reset
    // ---------------------------------------------------------------
    task automatic test_reset();
        reset_dut();
        check("Reset -- LRU index is 0 after reset", lru_idx == 4'd0);
    endtask

    // ---------------------------------------------------------------
    // Test 2: Sequential access — access entry 0, LRU changes
    // ---------------------------------------------------------------
    task automatic test_sequential_access();
        logic [3:0] lru_after_0;
        reset_dut();

        do_access(4'd0);
        lru_after_0 = lru_idx;
        check("Sequential access -- LRU changes after accessing entry 0",
              lru_after_0 != 4'd0);
        check("Sequential access -- LRU points to entry 8 after accessing 0",
              lru_after_0 == 4'd8);
    endtask

    // ---------------------------------------------------------------
    // Test 3: Repeated access — accessing same entry repeatedly doesn't change LRU
    // ---------------------------------------------------------------
    task automatic test_repeated_access();
        logic [3:0] lru_before, lru_after;
        integer i;
        reset_dut();

        do_access(4'd0);
        lru_before = lru_idx;

        for (i = 0; i < 5; i = i + 1) begin
            do_access(4'd0);
        end
        lru_after = lru_idx;

        check("Repeated access -- accessing same entry repeatedly does not change LRU",
              lru_before == lru_after);
    endtask

    // ---------------------------------------------------------------
    // Test 4: LRU eviction order — access via LRU pointer, verify it changes
    // ---------------------------------------------------------------
    task automatic test_lru_eviction_order();
        logic [3:0] prev_lru;
        integer i;
        reset_dut();

        for (i = 0; i < 4; i = i + 1) begin
            prev_lru = lru_idx;
            do_access(lru_idx);
        end
        check("LRU eviction order -- LRU changes after accessing multiple LRU targets",
              lru_idx != 4'd0);
    endtask

    // ---------------------------------------------------------------
    // Test 5: Wrap-around — access LRU entry repeatedly, collect 16 distinct indices
    // ---------------------------------------------------------------
    task automatic test_wrap_around();
        logic [3:0] visited [0:15];
        logic all_distinct;
        integer i, j;
        reset_dut();

        for (i = 0; i < 16; i = i + 1) begin
            visited[i] = lru_idx;
            do_access(lru_idx);
        end

        all_distinct = 1;
        for (i = 0; i < 16; i = i + 1) begin
            for (j = i + 1; j < 16; j = j + 1) begin
                if (visited[i] == visited[j])
                    all_distinct = 0;
            end
        end

        check("Wrap-around -- pseudo-LRU visits 16 distinct indices",
              all_distinct);
    endtask

    // ---------------------------------------------------------------
    // Test 6: Parameterisation — DEPTH=4 instance works correctly
    // ---------------------------------------------------------------
    task automatic test_parameterisation();
        logic [1:0] visited_4 [0:3];
        logic distinct_4;
        integer i, j;
        reset_dut();

        check("Parameterisation -- DEPTH=4 LRU index is 0 after reset",
              lru_idx_4 == 2'd0);

        for (i = 0; i < 4; i = i + 1) begin
            visited_4[i] = lru_idx_4;
            do_access_4(lru_idx_4);
        end

        distinct_4 = 1;
        for (i = 0; i < 4; i = i + 1) begin
            for (j = i + 1; j < 4; j = j + 1) begin
                if (visited_4[i] == visited_4[j])
                    distinct_4 = 0;
            end
        end

        check("Parameterisation -- DEPTH=4 visits 4 distinct LRU indices",
              distinct_4);
    endtask

    // Main
    initial begin
        $dumpfile("tb_lru_tracker.vcd");
        $dumpvars(0, tb_lru_tracker);

        test_reset();
        test_sequential_access();
        test_repeated_access();
        test_lru_eviction_order();
        test_wrap_around();
        test_parameterisation();

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
