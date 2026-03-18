// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_io_permission_checker;
    import iommu_pkg::*;

    // Clock for sequencing (DUT is combinational)
    logic clk;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // DUT signals
    device_context_t        ctx;
    logic                   is_read;
    logic                   is_write;

    logic                   ctx_valid;
    logic                   ctx_fault;
    logic [3:0]             ctx_fault_cause;
    logic                   needs_translation;

    // DUT instantiation
    io_permission_checker dut ( .* );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
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

    task automatic set_ctx(
        input logic        en,
        input logic        rp,
        input logic        wp,
        input logic        fp,
        input logic [3:0]  mode,
        input logic [PPN_W-1:0] root_ppn
    );
        ctx.en          = en;
        ctx.rp          = rp;
        ctx.wp          = wp;
        ctx.fp          = fp;
        ctx.mode        = mode;
        ctx.rsv         = 2'b00;
        ctx.pt_root_ppn = root_ppn;
        ctx.reserved_w1 = 32'd0;
    endtask

    // =========================================================
    // Test tasks
    // =========================================================

    // Test 1: Context disabled (en=0)
    task automatic test_ctx_disabled();
        set_ctx(0, 1, 1, 0, MODE_SV32, 22'd0);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Context disabled — fault asserted",       ctx_fault);
        check("Context disabled — CAUSE_CTX_INVALID",    ctx_fault_cause == CAUSE_CTX_INVALID);
    endtask

    // Test 2: Context enabled, read permitted, read access
    task automatic test_read_permitted();
        set_ctx(1, 1, 1, 0, MODE_SV32, 22'd0);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Read permitted — no fault",               !ctx_fault);
        check("Read permitted — ctx_valid",               ctx_valid);
        check("Read permitted — needs_translation",       needs_translation);
    endtask

    // Test 3: Read denied (rp=0)
    task automatic test_read_denied();
        set_ctx(1, 0, 1, 0, MODE_SV32, 22'd0);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Read denied — fault asserted",            ctx_fault);
        check("Read denied — CAUSE_CTX_READ_DENIED",     ctx_fault_cause == CAUSE_CTX_READ_DENIED);
    endtask

    // Test 4: Write permitted
    task automatic test_write_permitted();
        set_ctx(1, 1, 1, 0, MODE_SV32, 22'd0);
        is_read  = 0;
        is_write = 1;
        @(posedge clk);

        check("Write permitted — no fault",              !ctx_fault);
        check("Write permitted — ctx_valid",              ctx_valid);
    endtask

    // Test 5: Write denied (wp=0)
    task automatic test_write_denied();
        set_ctx(1, 1, 0, 0, MODE_SV32, 22'd0);
        is_read  = 0;
        is_write = 1;
        @(posedge clk);

        check("Write denied — fault asserted",           ctx_fault);
        check("Write denied — CAUSE_CTX_WRITE_DENIED",   ctx_fault_cause == CAUSE_CTX_WRITE_DENIED);
    endtask

    // Test 6: Bare mode (no translation)
    task automatic test_bare_mode();
        set_ctx(1, 1, 1, 0, MODE_BARE, 22'd0);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Bare mode — no fault",                    !ctx_fault);
        check("Bare mode — ctx_valid",                    ctx_valid);
        check("Bare mode — needs_translation=0",         !needs_translation);
    endtask

    // Test 7: Sv32 mode (translation needed)
    task automatic test_sv32_mode();
        set_ctx(1, 1, 1, 0, MODE_SV32, 22'h12_3456);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Sv32 mode — no fault",                    !ctx_fault);
        check("Sv32 mode — ctx_valid",                    ctx_valid);
        check("Sv32 mode — needs_translation=1",          needs_translation);
    endtask

    // Test 8: Invalid mode
    task automatic test_invalid_mode();
        set_ctx(1, 1, 1, 0, 4'b0010, 22'd0);
        is_read  = 1;
        is_write = 0;
        @(posedge clk);

        check("Invalid mode — fault asserted",           ctx_fault);
        check("Invalid mode — CAUSE_CTX_INVALID",        ctx_fault_cause == CAUSE_CTX_INVALID);
    endtask

    // =========================================================
    // Main
    // =========================================================
    initial begin
        $dumpfile("tb_io_permission_checker.vcd");
        $dumpvars(0, tb_io_permission_checker);

        test_ctx_disabled();
        test_read_permitted();
        test_read_denied();
        test_write_permitted();
        test_write_denied();
        test_bare_mode();
        test_sv32_mode();
        test_invalid_mode();

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
