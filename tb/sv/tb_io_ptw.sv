// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_io_ptw;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // DUT signals
    logic                   walk_req_valid;
    logic                   walk_req_ready;
    logic [DEVICE_ID_W-1:0] walk_device_id;
    logic [VPN_W-1:0]       walk_vpn1;
    logic [VPN_W-1:0]       walk_vpn0;
    logic [PPN_W-1:0]       walk_pt_root_ppn;
    logic                   walk_is_read;
    logic                   walk_is_write;

    logic                   walk_done;
    logic                   walk_fault;
    logic [3:0]             walk_fault_cause;
    logic [PPN_W-1:0]       walk_ppn;
    logic                   walk_perm_r;
    logic                   walk_perm_w;
    logic                   walk_is_superpage;

    logic                   mem_rd_req_valid;
    logic                   mem_rd_req_ready;
    logic [PADDR_W-1:0]     mem_rd_addr;
    logic                   mem_rd_resp_valid;
    logic                   mem_rd_resp_ready;
    logic [31:0]            mem_rd_data;
    logic                   mem_rd_error;

    // DUT instantiation
    io_ptw dut ( .* );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // =========================================================
    // Simple memory model -- 4 KB addressable region
    // =========================================================
    logic [31:0] mem [0:1023];  // 1024 x 32-bit words
    logic        mem_error_inject;

    initial mem_error_inject = 0;

    // Always ready to accept read requests
    assign mem_rd_req_ready = 1'b1;

    // Respond to memory read requests from DUT with 1-cycle latency
    always_ff @(posedge clk) begin
        if (srst) begin
            mem_rd_resp_valid <= 0;
            mem_rd_data       <= '0;
            mem_rd_error      <= 0;
        end else if (mem_rd_req_valid && mem_rd_req_ready) begin
            mem_rd_data       <= mem[mem_rd_addr[11:2]];  // word-aligned
            mem_rd_resp_valid <= 1;
            mem_rd_error      <= mem_error_inject;
        end else begin
            mem_rd_resp_valid <= 0;
        end
    end

    // =========================================================
    // Helper tasks
    // =========================================================
    task automatic reset_dut();
        srst = 1;
        walk_req_valid   = 0;
        walk_device_id   = '0;
        walk_vpn1        = '0;
        walk_vpn0        = '0;
        walk_pt_root_ppn = '0;
        walk_is_read     = 0;
        walk_is_write    = 0;
        mem_error_inject = 0;
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

    // Issue a walk request and wait for walk_done
    task automatic issue_walk(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [VPN_W-1:0]       vpn1,
        input logic [VPN_W-1:0]       vpn0,
        input logic [PPN_W-1:0]       root_ppn,
        input logic                   is_rd,
        input logic                   is_wr
    );
        @(posedge clk);
        walk_req_valid   = 1;
        walk_device_id   = dev_id;
        walk_vpn1        = vpn1;
        walk_vpn0        = vpn0;
        walk_pt_root_ppn = root_ppn;
        walk_is_read     = is_rd;
        walk_is_write    = is_wr;
        @(posedge clk);
        walk_req_valid = 0;
        // Wait for walk_done
        while (!walk_done) @(posedge clk);
        @(posedge clk);  // let outputs settle
    endtask

    // =========================================================
    // Test tasks
    // =========================================================

    // Test 1: Successful two-level walk
    task automatic test_two_level_walk();
        logic [PPN_W-1:0] root_ppn;
        logic [VPN_W-1:0] vpn1, vpn0;
        logic [31:0]      l1_pte, l0_pte;
        logic [PPN_W-1:0] l1_ppn, leaf_ppn;
        integer l1_addr_idx, l0_addr_idx;

        reset_dut();

        root_ppn = 22'h00_0001;   // root page table at phys addr 0x1000
        vpn1     = 10'd0;
        vpn0     = 10'd1;
        l1_ppn   = 22'h00_0002;   // L0 table at phys addr 0x2000
        leaf_ppn = 22'h00_ABCD;

        // L1 PTE: non-leaf pointer (V=1, R=W=X=0)
        l1_pte = {l1_ppn[21:10], l1_ppn[9:0], 10'b00_0000_0001};
        l1_addr_idx = vpn1;  // offset in root table (word index)
        mem[l1_addr_idx] = l1_pte;

        // L0 PTE: leaf (V=1, R=1, W=1, X=0)
        l0_pte = {leaf_ppn[21:10], leaf_ppn[9:0], 10'b00_0000_0111};
        // L0 table base = l1_ppn * 4096 = 0x2000, word offset = vpn0
        l0_addr_idx = ((l1_ppn << 12) >> 2) + vpn0;
        // But our memory is only 1024 words (4KB). Use small addresses.
        // l1_ppn at 0x2000 => word index 0x800, too large.
        // Use smaller addresses that fit in 1024 words.
        root_ppn = 22'h00_0000;   // root at 0x0000
        vpn1     = 10'd0;
        vpn0     = 10'd2;
        l1_ppn   = 22'h00_0001;   // L0 table at 0x1000 => word 0x400 = 1024 -- just at limit

        // Use root_ppn = 0, so L1 PTE addr = 0 + vpn1*4 = word 0
        // l1_ppn = 0, so L0 PTE addr = 0 + vpn0*4 => word = vpn0
        l1_ppn   = 22'h00_0000;   // L0 table also at 0x0000 region
        leaf_ppn = 22'h3A_BCDE;

        // L1 PTE at mem[vpn1] = non-leaf pointer to l1_ppn
        l1_pte = {l1_ppn[21:10], l1_ppn[9:0], 10'b00_0000_0001};  // V=1 only
        mem[vpn1] = l1_pte;

        // L0 PTE at mem[vpn0] = leaf R=1,W=1
        l0_pte = {leaf_ppn[21:10], leaf_ppn[9:0], 10'b00_0000_0111};  // V=1,R=1,W=1
        mem[vpn0] = l0_pte;

        issue_walk(8'd1, vpn1, vpn0, root_ppn, 1'b1, 1'b0);

        check("Two-level walk — no fault",        !walk_fault);
        check("Two-level walk — correct PPN",      walk_ppn == leaf_ppn);
        check("Two-level walk — perm_r set",        walk_perm_r);
        check("Two-level walk — not superpage",    !walk_is_superpage);
    endtask

    // Test 2: Superpage walk
    task automatic test_superpage();
        logic [PPN_W-1:0] root_ppn;
        logic [VPN_W-1:0] vpn1;
        logic [31:0]      l1_pte;
        logic [PPN_W-1:0] super_ppn;

        reset_dut();

        root_ppn  = 22'h00_0000;
        vpn1      = 10'd5;
        // Superpage PPN: ppn0 must be 0 for alignment
        super_ppn = {12'hABC, 10'd0};  // ppn1=0xABC, ppn0=0

        // L1 PTE: leaf (V=1, R=1, W=1, X=0), ppn0=0 (aligned)
        l1_pte = {super_ppn[21:10], super_ppn[9:0], 10'b00_0000_0111};
        mem[vpn1] = l1_pte;

        issue_walk(8'd2, vpn1, 10'd0, root_ppn, 1'b1, 1'b0);

        check("Superpage — no fault",          !walk_fault);
        check("Superpage — is_superpage set",    walk_is_superpage);
        check("Superpage — correct PPN",         walk_ppn == super_ppn);
    endtask

    // Test 3: L1 PTE invalid
    task automatic test_l1_invalid();
        reset_dut();

        // L1 PTE: V=0
        mem[10'd3] = 32'h0000_0000;  // all zeros => V=0

        issue_walk(8'd3, 10'd3, 10'd0, 22'h00_0000, 1'b1, 1'b0);

        check("L1 invalid — fault asserted",            walk_fault);
        check("L1 invalid — CAUSE_PTE_INVALID",         walk_fault_cause == CAUSE_PTE_INVALID);
    endtask

    // Test 4: L0 PTE invalid
    task automatic test_l0_invalid();
        logic [31:0] l1_pte, l0_pte;

        reset_dut();

        // L1 PTE: non-leaf pointer to address 0
        l1_pte = {22'd0, 10'b00_0000_0001};  // V=1, R=W=X=0 (pointer)
        mem[10'd4] = l1_pte;

        // L0 PTE: V=0
        l0_pte = 32'h0000_0000;
        mem[10'd7] = l0_pte;  // vpn0=7

        issue_walk(8'd4, 10'd4, 10'd7, 22'h00_0000, 1'b1, 1'b0);

        check("L0 invalid — fault asserted",            walk_fault);
        check("L0 invalid — CAUSE_PTE_INVALID",         walk_fault_cause == CAUSE_PTE_INVALID);
    endtask

    // Test 5: Misaligned superpage
    task automatic test_misaligned_superpage();
        logic [31:0] l1_pte;

        reset_dut();

        // L1 leaf PTE with ppn0 != 0 (misaligned superpage)
        // V=1, R=1, W=0, X=0, ppn0=10'd1 (non-zero)
        l1_pte = {12'hABC, 10'd1, 10'b00_0000_0011};  // V=1,R=1
        mem[10'd8] = l1_pte;

        issue_walk(8'd5, 10'd8, 10'd0, 22'h00_0000, 1'b1, 1'b0);

        check("Misaligned superpage — fault",            walk_fault);
        check("Misaligned superpage — CAUSE_PTE_MISALIGNED",
              walk_fault_cause == CAUSE_PTE_MISALIGNED);
    endtask

    // Test 6: Read permission denied
    task automatic test_read_denied();
        logic [31:0] l1_pte, l0_pte;

        reset_dut();

        // L1 non-leaf pointer
        l1_pte = {22'd0, 10'b00_0000_0001};
        mem[10'd10] = l1_pte;

        // L0 leaf: V=1, R=0, W=1, X=0 -- wait, W=1 R=0 is invalid encoding
        // Use: V=1, R=0, W=0, X=1 (execute only)
        l0_pte = {12'hDEA, 10'd0, 10'b00_0000_1001};  // V=1, X=1 only
        mem[10'd11] = l0_pte;

        issue_walk(8'd6, 10'd10, 10'd11, 22'h00_0000, 1'b1, 1'b0);

        check("Read denied — fault",                    walk_fault);
        check("Read denied — CAUSE_READ_DENIED",        walk_fault_cause == CAUSE_READ_DENIED);
    endtask

    // Test 7: Write permission denied
    task automatic test_write_denied();
        logic [31:0] l1_pte, l0_pte;

        reset_dut();

        // L1 non-leaf pointer
        l1_pte = {22'd0, 10'b00_0000_0001};
        mem[10'd12] = l1_pte;

        // L0 leaf: V=1, R=1, W=0, X=0 (read-only)
        l0_pte = {12'hBEE, 10'd0, 10'b00_0000_0011};  // V=1, R=1
        mem[10'd13] = l0_pte;

        issue_walk(8'd7, 10'd12, 10'd13, 22'h00_0000, 1'b0, 1'b1);

        check("Write denied — fault",                   walk_fault);
        check("Write denied — CAUSE_WRITE_DENIED",      walk_fault_cause == CAUSE_WRITE_DENIED);
    endtask

    // Test 8: Invalid PTE encoding (W=1, R=0)
    task automatic test_invalid_encoding();
        logic [31:0] l1_pte;

        reset_dut();

        // L1 leaf PTE: V=1, R=0, W=1, X=0 (invalid encoding), ppn0=0
        l1_pte = {12'hFFF, 10'd0, 10'b00_0000_0101};  // V=1, W=1, R=0
        mem[10'd14] = l1_pte;

        issue_walk(8'd8, 10'd14, 10'd0, 22'h00_0000, 1'b1, 1'b0);

        check("Invalid encoding W=1,R=0 — fault",       walk_fault);
        check("Invalid encoding W=1,R=0 — PTE_INVALID",
              walk_fault_cause == CAUSE_PTE_INVALID);
    endtask

    // Test 9: Memory error during walk
    task automatic test_memory_error();
        reset_dut();

        mem_error_inject = 1;
        // Any PTE in memory -- doesn't matter, error will be returned
        mem[10'd15] = 32'hDEAD_BEEF;

        issue_walk(8'd9, 10'd15, 10'd0, 22'h00_0000, 1'b1, 1'b0);

        mem_error_inject = 0;

        check("Memory error — fault",                   walk_fault);
        check("Memory error — CAUSE_PTW_ACCESS_FAULT",
              walk_fault_cause == CAUSE_PTW_ACCESS_FAULT);
    endtask

    // Test 10: Back-to-back walks
    task automatic test_back_to_back();
        logic [PPN_W-1:0] ppn1, ppn2;

        reset_dut();

        ppn1 = 22'h11_1111;
        ppn2 = 22'h22_2222;

        // Setup walk 1: simple two-level
        // L1 at mem[20]: non-leaf pointer to base 0
        mem[10'd20] = {22'd0, 10'b00_0000_0001};
        // L0 at mem[21]: leaf R=1, W=1
        mem[10'd21] = {ppn1[21:10], ppn1[9:0], 10'b00_0000_0111};

        // Setup walk 2:
        // L1 at mem[22]: non-leaf pointer to base 0
        mem[10'd22] = {22'd0, 10'b00_0000_0001};
        // L0 at mem[23]: leaf R=1, W=1
        mem[10'd23] = {ppn2[21:10], ppn2[9:0], 10'b00_0000_0111};

        // Walk 1
        issue_walk(8'd10, 10'd20, 10'd21, 22'h00_0000, 1'b1, 1'b0);
        check("Back-to-back walk 1 — no fault",         !walk_fault);
        check("Back-to-back walk 1 — correct PPN",      walk_ppn == ppn1);

        // Walk 2 immediately after
        issue_walk(8'd10, 10'd22, 10'd23, 22'h00_0000, 1'b1, 1'b0);
        check("Back-to-back walk 2 — no fault",         !walk_fault);
        check("Back-to-back walk 2 — correct PPN",      walk_ppn == ppn2);
    endtask

    // =========================================================
    // Main
    // =========================================================
    initial begin
        $dumpfile("tb_io_ptw.vcd");
        $dumpvars(0, tb_io_ptw);

        test_two_level_walk();
        test_superpage();
        test_l1_invalid();
        test_l0_invalid();
        test_misaligned_superpage();
        test_read_denied();
        test_write_denied();
        test_invalid_encoding();
        test_memory_error();
        test_back_to_back();

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
