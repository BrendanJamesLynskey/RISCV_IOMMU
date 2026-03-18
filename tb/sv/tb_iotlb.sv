// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_iotlb;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Command signals (driven by tasks, relayed to DUT via always block)
    logic                        cmd_lookup_valid;
    logic [DEVICE_ID_W-1:0]      cmd_lookup_device_id;
    logic [VPN_W-1:0]            cmd_lookup_vpn1;
    logic [VPN_W-1:0]            cmd_lookup_vpn0;
    logic                        cmd_refill_valid;
    logic [DEVICE_ID_W-1:0]      cmd_refill_device_id;
    logic [VPN_W-1:0]            cmd_refill_vpn1;
    logic [VPN_W-1:0]            cmd_refill_vpn0;
    logic [PPN_W-1:0]            cmd_refill_ppn;
    logic                        cmd_refill_perm_r;
    logic                        cmd_refill_perm_w;
    logic                        cmd_refill_is_superpage;
    logic                        cmd_inv_valid;
    logic [DEVICE_ID_W-1:0]      cmd_inv_device_id;
    logic                        cmd_inv_all;

    // DUT port signals
    logic                        lookup_valid;
    logic                        lookup_ready;
    logic [DEVICE_ID_W-1:0]      lookup_device_id;
    logic [VPN_W-1:0]            lookup_vpn1;
    logic [VPN_W-1:0]            lookup_vpn0;
    logic                        lookup_hit;
    logic [PPN_W-1:0]            lookup_ppn;
    logic                        lookup_perm_r;
    logic                        lookup_perm_w;
    logic                        lookup_is_superpage;
    logic                        refill_valid;
    logic [DEVICE_ID_W-1:0]      refill_device_id;
    logic [VPN_W-1:0]            refill_vpn1;
    logic [VPN_W-1:0]            refill_vpn0;
    logic [PPN_W-1:0]            refill_ppn;
    logic                        refill_perm_r;
    logic                        refill_perm_w;
    logic                        refill_is_superpage;
    logic                        inv_valid;
    logic [DEVICE_ID_W-1:0]      inv_device_id;
    logic                        inv_all;
    logic                        perf_hit;
    logic                        perf_miss;

    // Relay command signals to DUT ports (iverilog workaround)
    always @(*) begin
        lookup_valid       = cmd_lookup_valid;
        lookup_device_id   = cmd_lookup_device_id;
        lookup_vpn1        = cmd_lookup_vpn1;
        lookup_vpn0        = cmd_lookup_vpn0;
        refill_valid       = cmd_refill_valid;
        refill_device_id   = cmd_refill_device_id;
        refill_vpn1        = cmd_refill_vpn1;
        refill_vpn0        = cmd_refill_vpn0;
        refill_ppn         = cmd_refill_ppn;
        refill_perm_r      = cmd_refill_perm_r;
        refill_perm_w      = cmd_refill_perm_w;
        refill_is_superpage = cmd_refill_is_superpage;
        inv_valid          = cmd_inv_valid;
        inv_device_id      = cmd_inv_device_id;
        inv_all            = cmd_inv_all;
    end

    // DUT instantiation
    iotlb #(.DEPTH(IOTLB_DEPTH)) dut (
        .clk                (clk),
        .srst               (srst),
        .lookup_valid       (lookup_valid),
        .lookup_ready       (lookup_ready),
        .lookup_device_id   (lookup_device_id),
        .lookup_vpn1        (lookup_vpn1),
        .lookup_vpn0        (lookup_vpn0),
        .lookup_hit         (lookup_hit),
        .lookup_ppn         (lookup_ppn),
        .lookup_perm_r      (lookup_perm_r),
        .lookup_perm_w      (lookup_perm_w),
        .lookup_is_superpage(lookup_is_superpage),
        .refill_valid       (refill_valid),
        .refill_device_id   (refill_device_id),
        .refill_vpn1        (refill_vpn1),
        .refill_vpn0        (refill_vpn0),
        .refill_ppn         (refill_ppn),
        .refill_perm_r      (refill_perm_r),
        .refill_perm_w      (refill_perm_w),
        .refill_is_superpage(refill_is_superpage),
        .inv_valid          (inv_valid),
        .inv_device_id      (inv_device_id),
        .inv_all            (inv_all),
        .perf_hit           (perf_hit),
        .perf_miss          (perf_miss)
    );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst                    = 1;
        cmd_lookup_valid        = 0;
        cmd_lookup_device_id    = 0;
        cmd_lookup_vpn1         = 0;
        cmd_lookup_vpn0         = 0;
        cmd_refill_valid        = 0;
        cmd_refill_device_id    = 0;
        cmd_refill_vpn1         = 0;
        cmd_refill_vpn0         = 0;
        cmd_refill_ppn          = 0;
        cmd_refill_perm_r       = 0;
        cmd_refill_perm_w       = 0;
        cmd_refill_is_superpage = 0;
        cmd_inv_valid           = 0;
        cmd_inv_device_id       = 0;
        cmd_inv_all             = 0;
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

    // Refill helper: assert refill signals for one cycle, then wait one cycle
    task automatic do_refill(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [VPN_W-1:0]       vpn1,
        input logic [VPN_W-1:0]       vpn0,
        input logic [PPN_W-1:0]       ppn,
        input logic                   perm_r,
        input logic                   perm_w,
        input logic                   is_super
    );
        cmd_refill_valid        = 1;
        cmd_refill_device_id    = dev_id;
        cmd_refill_vpn1         = vpn1;
        cmd_refill_vpn0         = vpn0;
        cmd_refill_ppn          = ppn;
        cmd_refill_perm_r       = perm_r;
        cmd_refill_perm_w       = perm_w;
        cmd_refill_is_superpage = is_super;
        @(posedge clk);
        cmd_refill_valid        = 0;
        @(posedge clk);
    endtask

    // Lookup helper: assert lookup for one clock edge (LRU updates on hit)
    task automatic do_lookup(
        input  logic [DEVICE_ID_W-1:0] dev_id,
        input  logic [VPN_W-1:0]       vpn1,
        input  logic [VPN_W-1:0]       vpn0,
        output logic                   hit,
        output logic [PPN_W-1:0]       ppn,
        output logic                   perm_r,
        output logic                   perm_w,
        output logic                   is_super
    );
        cmd_lookup_valid     = 1;
        cmd_lookup_device_id = dev_id;
        cmd_lookup_vpn1      = vpn1;
        cmd_lookup_vpn0      = vpn0;
        #1;  // allow combinational settle
        hit      = lookup_hit;
        ppn      = lookup_ppn;
        perm_r   = lookup_perm_r;
        perm_w   = lookup_perm_w;
        is_super = lookup_is_superpage;
        @(posedge clk);  // LRU updated on this edge if hit
        cmd_lookup_valid = 0;
        @(posedge clk);
    endtask

    // Refill+lookup: refill then lookup to trigger LRU update
    task automatic refill_and_touch(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [VPN_W-1:0]       vpn1,
        input logic [VPN_W-1:0]       vpn0,
        input logic [PPN_W-1:0]       ppn,
        input logic                   perm_r,
        input logic                   perm_w,
        input logic                   is_super
    );
        logic                   dummy_hit;
        logic [PPN_W-1:0]       dummy_ppn;
        logic                   dummy_r, dummy_w, dummy_s;
        do_refill(dev_id, vpn1, vpn0, ppn, perm_r, perm_w, is_super);
        do_lookup(dev_id, vpn1, vpn0, dummy_hit, dummy_ppn, dummy_r, dummy_w, dummy_s);
    endtask

    // Temporary variables for lookup results
    logic                   t_hit;
    logic [PPN_W-1:0]       t_ppn;
    logic                   t_perm_r;
    logic                   t_perm_w;
    logic                   t_is_super;

    // ---------------------------------------------------------------
    // Test 1: Reset — all entries invalid, lookup misses
    // ---------------------------------------------------------------
    task automatic test_reset();
        reset_dut();
        cmd_lookup_valid     = 1;
        cmd_lookup_device_id = 8'h01;
        cmd_lookup_vpn1      = 10'h0AA;
        cmd_lookup_vpn0      = 10'h055;
        #1;
        check("Reset -- lookup misses after reset", lookup_hit == 0);
        cmd_lookup_valid = 0;
        @(posedge clk);
    endtask

    // ---------------------------------------------------------------
    // Test 2: Single refill + hit
    // ---------------------------------------------------------------
    task automatic test_single_refill_hit();
        reset_dut();
        do_refill(8'h01, 10'h0AA, 10'h055, 22'h123456, 1, 1, 0);
        do_lookup(8'h01, 10'h0AA, 10'h055, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Single refill + hit -- lookup hits after refill",
              t_hit == 1 && t_ppn == 22'h123456);
    endtask

    // ---------------------------------------------------------------
    // Test 3: Different device IDs — same VPN, different device IDs
    // ---------------------------------------------------------------
    task automatic test_different_device_ids();
        reset_dut();
        refill_and_touch(8'h01, 10'h100, 10'h200, 22'h111111, 1, 0, 0);
        do_refill(8'h02, 10'h100, 10'h200, 22'h222222, 1, 0, 0);

        do_lookup(8'h01, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Different device IDs -- device 1 returns correct PPN",
              t_hit == 1 && t_ppn == 22'h111111);

        do_lookup(8'h02, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Different device IDs -- device 2 returns correct PPN",
              t_hit == 1 && t_ppn == 22'h222222);
    endtask

    // ---------------------------------------------------------------
    // Test 4: Superpage hit — refill superpage, lookup with any vpn0
    // ---------------------------------------------------------------
    task automatic test_superpage_hit();
        reset_dut();
        do_refill(8'h03, 10'h0FF, 10'h000, 22'h3ABCDE, 1, 1, 1);

        do_lookup(8'h03, 10'h0FF, 10'h123, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Superpage hit -- matches with different vpn0",
              t_hit == 1 && t_ppn == 22'h3ABCDE && t_is_super == 1);

        do_lookup(8'h03, 10'h0FF, 10'h3FF, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Superpage hit -- matches with another vpn0",
              t_hit == 1 && t_ppn == 22'h3ABCDE && t_is_super == 1);
    endtask

    // ---------------------------------------------------------------
    // Test 5: Capacity eviction — fill all 16, add one more
    // ---------------------------------------------------------------
    task automatic test_capacity_eviction();
        integer i;
        reset_dut();

        for (i = 0; i < IOTLB_DEPTH; i = i + 1) begin
            refill_and_touch(i[7:0], 10'h000, i[9:0], i[21:0], 1, 0, 0);
        end

        do_lookup(8'h00, 10'h000, 10'h000, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Capacity eviction -- entry 0 present before overflow",
              t_hit == 1);

        do_refill(8'hFF, 10'h3FF, 10'h3FF, 22'h3FFFFF, 1, 1, 0);

        do_lookup(8'hFF, 10'h3FF, 10'h3FF, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Capacity eviction -- new entry is present after overflow",
              t_hit == 1 && t_ppn == 22'h3FFFFF);
    endtask

    // ---------------------------------------------------------------
    // Test 6: Invalidate by device ID
    // ---------------------------------------------------------------
    task automatic test_invalidate_by_device_id();
        reset_dut();
        refill_and_touch(8'h0A, 10'h001, 10'h002, 22'h0AAAAA, 1, 1, 0);
        refill_and_touch(8'h0A, 10'h003, 10'h004, 22'h0BBBBB, 1, 1, 0);
        do_refill(8'h0B, 10'h001, 10'h002, 22'h0CCCCC, 1, 1, 0);

        cmd_inv_valid     = 1;
        cmd_inv_device_id = 8'h0A;
        cmd_inv_all       = 0;
        @(posedge clk);
        cmd_inv_valid     = 0;
        @(posedge clk);

        do_lookup(8'h0A, 10'h001, 10'h002, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Invalidate by device ID -- device 0x0A entry 1 misses", t_hit == 0);

        do_lookup(8'h0A, 10'h003, 10'h004, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Invalidate by device ID -- device 0x0A entry 2 misses", t_hit == 0);

        do_lookup(8'h0B, 10'h001, 10'h002, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Invalidate by device ID -- device 0x0B entry still hits",
              t_hit == 1 && t_ppn == 22'h0CCCCC);
    endtask

    // ---------------------------------------------------------------
    // Test 7: Invalidate all
    // ---------------------------------------------------------------
    task automatic test_invalidate_all();
        reset_dut();
        refill_and_touch(8'h01, 10'h010, 10'h020, 22'h111111, 1, 0, 0);
        do_refill(8'h02, 10'h030, 10'h040, 22'h222222, 0, 1, 0);

        cmd_inv_valid = 1;
        cmd_inv_all   = 1;
        @(posedge clk);
        cmd_inv_valid = 0;
        cmd_inv_all   = 0;
        @(posedge clk);

        do_lookup(8'h01, 10'h010, 10'h020, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Invalidate all -- entry 1 misses after inv_all", t_hit == 0);

        do_lookup(8'h02, 10'h030, 10'h040, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Invalidate all -- entry 2 misses after inv_all", t_hit == 0);
    endtask

    // ---------------------------------------------------------------
    // Test 8: Refill overwrites LRU
    // ---------------------------------------------------------------
    task automatic test_refill_overwrites_lru();
        integer i;
        logic [3:0] victim;
        logic [7:0] victim_dev_id;
        reset_dut();

        for (i = 0; i < IOTLB_DEPTH; i = i + 1) begin
            refill_and_touch(i[7:0], 10'h000, i[9:0], i[21:0], 1, 0, 0);
        end

        victim = dut.lru_victim_idx;
        victim_dev_id = dut.entry_device_id[victim];

        do_refill(8'hFE, 10'h3FE, 10'h3FE, 22'h3FFFFE, 1, 1, 0);

        do_lookup(victim_dev_id, 10'h000, victim_dev_id[3:0], t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Refill overwrites LRU -- evicted entry misses", t_hit == 0);

        do_lookup(8'hFE, 10'h3FE, 10'h3FE, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Refill overwrites LRU -- new entry is present",
              t_hit == 1 && t_ppn == 22'h3FFFFE);
    endtask

    // ---------------------------------------------------------------
    // Test 9: Permission fields
    // ---------------------------------------------------------------
    task automatic test_permission_fields();
        reset_dut();

        refill_and_touch(8'h01, 10'h100, 10'h200, 22'h123456, 1, 0, 0);
        refill_and_touch(8'h02, 10'h100, 10'h200, 22'h254321, 0, 1, 0);
        do_refill(8'h03, 10'h100, 10'h200, 22'h0ABCDE, 1, 1, 0);

        do_lookup(8'h01, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Permission fields -- R=1,W=0 stored correctly",
              t_hit == 1 && t_perm_r == 1 && t_perm_w == 0);

        do_lookup(8'h02, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Permission fields -- R=0,W=1 stored correctly",
              t_hit == 1 && t_ppn == 22'h254321 && t_perm_r == 0 && t_perm_w == 1);

        do_lookup(8'h03, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Permission fields -- R=1,W=1 stored correctly",
              t_hit == 1 && t_perm_r == 1 && t_perm_w == 1);
    endtask

    // ---------------------------------------------------------------
    // Test 10: Miss returns no hit
    // ---------------------------------------------------------------
    task automatic test_miss_returns_no_hit();
        reset_dut();

        do_lookup(8'h00, 10'h000, 10'h000, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Miss returns no hit -- empty TLB misses", t_hit == 0);

        do_refill(8'h01, 10'h100, 10'h200, 22'h123456, 1, 1, 0);

        do_lookup(8'h01, 10'h101, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Miss returns no hit -- different vpn1 misses", t_hit == 0);

        do_lookup(8'h01, 10'h100, 10'h201, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Miss returns no hit -- different vpn0 misses", t_hit == 0);

        do_lookup(8'h02, 10'h100, 10'h200, t_hit, t_ppn, t_perm_r, t_perm_w, t_is_super);
        check("Miss returns no hit -- different device_id misses", t_hit == 0);
    endtask

    // Main
    initial begin
        $dumpfile("tb_iotlb.vcd");
        $dumpvars(0, tb_iotlb);

        test_reset();
        test_single_refill_hit();
        test_different_device_ids();
        test_superpage_hit();
        test_capacity_eviction();
        test_invalidate_by_device_id();
        test_invalidate_all();
        test_refill_overwrites_lru();
        test_permission_fields();
        test_miss_returns_no_hit();

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
