// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_fault_handler;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // DUT signals
    logic                                fault_valid;
    logic                                fault_ready;
    fault_record_t                       fault_record;

    logic                                head_inc;
    logic [$clog2(FAULT_QUEUE_DEPTH)-1:0] head;
    logic [$clog2(FAULT_QUEUE_DEPTH)-1:0] tail;
    logic                                fault_pending;
    logic                                queue_full;

    fault_record_t                       read_data;
    logic                                perf_fault;

    // DUT instantiation
    fault_handler dut ( .* );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst         = 1;
        fault_valid  = 0;
        fault_record = '0;
        head_inc     = 0;
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

    // Build a fault record
    function automatic fault_record_t make_fault(
        input logic [3:0]             cause,
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [VADDR_W-1:0]     addr,
        input logic                   is_rd,
        input logic                   is_wr
    );
        fault_record_t fr;
        fr.faulting_addr = addr;
        fr.reserved1     = 16'd0;
        fr.device_id     = dev_id;
        fr.cause         = cause;
        fr.reserved0     = 1'b0;
        fr.is_write      = is_wr;
        fr.is_read       = is_rd;
        fr.valid         = 1'b1;
        return fr;
    endfunction

    // Write one fault record: assert valid, wait for it to be sampled, deassert
    task automatic write_fault(input fault_record_t fr);
        fault_valid  = 1;
        fault_record = fr;
        @(posedge clk);   // DUT samples fault_valid=1 on this edge
        #1;               // small delay so registered outputs settle
        fault_valid = 0;
    endtask

    // =========================================================
    // Test tasks
    // =========================================================

    // Test 1: Reset
    task automatic test_reset();
        reset_dut();
        check("Reset — head=0",              head == 0);
        check("Reset — tail=0",              tail == 0);
        check("Reset — no fault_pending",    !fault_pending);
        check("Reset — not queue_full",      !queue_full);
        check("Reset — fault_ready",          fault_ready);
    endtask

    // Test 2: Single fault write
    task automatic test_single_fault();
        fault_record_t fr;

        reset_dut();
        fr = make_fault(CAUSE_PTE_INVALID, 8'hAA, 32'hDEAD_0000, 1'b1, 1'b0);

        write_fault(fr);
        @(posedge clk);

        check("Single fault — tail advanced",     tail == 1);
        check("Single fault — fault_pending",      fault_pending);
        check("Single fault — head still 0",       head == 0);
    endtask

    // Test 3: Multiple faults
    task automatic test_multiple_faults();
        fault_record_t fr;
        integer i;

        reset_dut();

        for (i = 0; i < 4; i++) begin
            fr = make_fault(CAUSE_READ_DENIED, i[DEVICE_ID_W-1:0],
                            {16'd0, i[15:0]}, 1'b1, 1'b0);
            write_fault(fr);
        end
        @(posedge clk);

        check("Multiple faults — tail=4",         tail == 4);
        check("Multiple faults — fault_pending",   fault_pending);
        check("Multiple faults — head=0",          head == 0);
    endtask

    // Test 4: Head increment
    task automatic test_head_increment();
        fault_record_t fr;
        integer i;

        reset_dut();

        // Write 3 faults
        for (i = 0; i < 3; i++) begin
            fr = make_fault(CAUSE_WRITE_DENIED, i[DEVICE_ID_W-1:0],
                            32'hBEEF_0000, 1'b0, 1'b1);
            write_fault(fr);
        end
        @(posedge clk);

        // Advance head 3 times to drain queue
        for (i = 0; i < 3; i++) begin
            head_inc = 1;
            @(posedge clk);
            #1;
            head_inc = 0;
            @(posedge clk);
        end

        check("Head increment — head caught up",   head == tail);
        check("Head increment — no pending",       !fault_pending);
    endtask

    // Test 5: Queue full
    task automatic test_queue_full();
        fault_record_t fr;
        integer i;

        reset_dut();

        // Fill queue to capacity (DEPTH-1 entries, since full = tail+1 == head)
        for (i = 0; i < (FAULT_QUEUE_DEPTH - 1); i++) begin
            fr = make_fault(CAUSE_PTE_INVALID, i[DEVICE_ID_W-1:0],
                            {16'hCAFE, i[15:0]}, 1'b1, 1'b0);
            write_fault(fr);
        end
        @(posedge clk);

        check("Queue full — queue_full asserted",  queue_full);
        check("Queue full — fault_ready deasserted", !fault_ready);
    endtask

    // Test 6: Wrap-around
    task automatic test_wraparound();
        fault_record_t fr;
        integer i;

        reset_dut();

        // Fill queue, then drain, then fill again to force wrap
        // Write DEPTH-1 entries
        for (i = 0; i < (FAULT_QUEUE_DEPTH - 1); i++) begin
            fr = make_fault(CAUSE_PTE_MISALIGNED, i[DEVICE_ID_W-1:0],
                            32'h0000_1000, 1'b1, 1'b0);
            write_fault(fr);
        end

        // Drain all entries
        for (i = 0; i < (FAULT_QUEUE_DEPTH - 1); i++) begin
            head_inc = 1;
            @(posedge clk);
            #1;
            head_inc = 0;
            @(posedge clk);
        end

        // Now head and tail should both be at DEPTH-1
        // Write 2 more entries -- tail wraps around
        for (i = 0; i < 2; i++) begin
            fr = make_fault(CAUSE_READ_DENIED, i[DEVICE_ID_W-1:0],
                            32'hFACE_0000 + i, 1'b1, 1'b0);
            write_fault(fr);
        end
        @(posedge clk);

        check("Wrap-around — fault_pending",        fault_pending);
        check("Wrap-around — tail wrapped",         tail < head);
    endtask

    // Test 7: Fault record integrity
    task automatic test_fault_record_integrity();
        fault_record_t fr, rd;

        reset_dut();

        fr = make_fault(CAUSE_CTX_WRITE_DENIED, 8'h42, 32'hA5A5_5A5A, 1'b0, 1'b1);
        write_fault(fr);
        @(posedge clk);

        rd = read_data;
        check("Integrity — cause matches",         rd.cause == CAUSE_CTX_WRITE_DENIED);
        check("Integrity — device_id matches",     rd.device_id == 8'h42);
        check("Integrity — faulting_addr matches",  rd.faulting_addr == 32'hA5A5_5A5A);
        check("Integrity — is_write matches",       rd.is_write == 1'b1);
        check("Integrity — is_read matches",        rd.is_read == 1'b0);
        check("Integrity — valid set",              rd.valid == 1'b1);
    endtask

    // =========================================================
    // Main
    // =========================================================
    initial begin
        $dumpfile("tb_fault_handler.vcd");
        $dumpvars(0, tb_fault_handler);

        test_reset();
        test_single_fault();
        test_multiple_faults();
        test_head_increment();
        test_queue_full();
        test_wraparound();
        test_fault_record_integrity();

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
