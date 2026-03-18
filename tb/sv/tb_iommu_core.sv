// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_iommu_core;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Transaction request
    logic                        txn_valid;
    logic                        txn_ready;
    logic [DEVICE_ID_W-1:0]      txn_device_id;
    logic [VADDR_W-1:0]          txn_vaddr;
    logic                        txn_is_read;
    logic                        txn_is_write;

    // Translation result
    logic                        txn_done;
    logic                        txn_fault;
    logic [3:0]                  txn_fault_cause;
    logic [PADDR_W-1:0]          txn_paddr;

    // IOMMU config
    logic                        iommu_enable;
    logic [PPN_W-1:0]            dct_base_ppn;

    // Memory read interface
    logic                        mem_rd_req_valid;
    logic                        mem_rd_req_ready;
    logic [PADDR_W-1:0]          mem_rd_addr;
    logic                        mem_rd_resp_valid;
    logic                        mem_rd_resp_ready;
    logic [31:0]                 mem_rd_data;
    logic                        mem_rd_error;

    // Fault output
    logic                        fault_valid;
    logic                        fault_ready;
    fault_record_t               fault_record;

    // Invalidation
    logic                        iotlb_inv_valid;
    logic [DEVICE_ID_W-1:0]      iotlb_inv_device_id;
    logic                        iotlb_inv_all;
    logic                        dc_inv_valid;
    logic [DEVICE_ID_W-1:0]      dc_inv_device_id;
    logic                        dc_inv_all;

    // Perf
    logic                        perf_iotlb_hit;
    logic                        perf_iotlb_miss;
    logic                        perf_fault;

    // DUT instantiation
    iommu_core dut (
        .clk              (clk),
        .srst             (srst),
        .txn_valid        (txn_valid),
        .txn_ready        (txn_ready),
        .txn_device_id    (txn_device_id),
        .txn_vaddr        (txn_vaddr),
        .txn_is_read      (txn_is_read),
        .txn_is_write     (txn_is_write),
        .txn_done         (txn_done),
        .txn_fault        (txn_fault),
        .txn_fault_cause  (txn_fault_cause),
        .txn_paddr        (txn_paddr),
        .iommu_enable     (iommu_enable),
        .dct_base_ppn     (dct_base_ppn),
        .mem_rd_req_valid (mem_rd_req_valid),
        .mem_rd_req_ready (mem_rd_req_ready),
        .mem_rd_addr      (mem_rd_addr),
        .mem_rd_resp_valid(mem_rd_resp_valid),
        .mem_rd_resp_ready(mem_rd_resp_ready),
        .mem_rd_data      (mem_rd_data),
        .mem_rd_error     (mem_rd_error),
        .fault_valid      (fault_valid),
        .fault_ready      (fault_ready),
        .fault_record     (fault_record),
        .iotlb_inv_valid  (iotlb_inv_valid),
        .iotlb_inv_device_id(iotlb_inv_device_id),
        .iotlb_inv_all    (iotlb_inv_all),
        .dc_inv_valid     (dc_inv_valid),
        .dc_inv_device_id (dc_inv_device_id),
        .dc_inv_all       (dc_inv_all),
        .perf_iotlb_hit   (perf_iotlb_hit),
        .perf_iotlb_miss  (perf_iotlb_miss),
        .perf_fault       (perf_fault)
    );

    // ==================== Memory model (64 KB) ====================
    // Addresses 0x0000 - 0xFFFF (byte), word-aligned
    logic [31:0] mem [0:16383];

    // Memory read responder -- registered ready to avoid comb loops
    logic mem_req_ready_r;
    assign mem_rd_req_ready = mem_req_ready_r;

    always_ff @(posedge clk) begin
        if (srst) begin
            mem_rd_resp_valid <= 0;
            mem_rd_data       <= 0;
            mem_rd_error      <= 0;
            mem_req_ready_r   <= 1;
        end else if (mem_rd_req_valid && mem_req_ready_r) begin
            mem_rd_data       <= mem[mem_rd_addr[15:2]];
            mem_rd_resp_valid <= 1;
            mem_rd_error      <= 0;
            mem_req_ready_r   <= 1;  // stay ready
        end else begin
            mem_rd_resp_valid <= 0;
            mem_req_ready_r   <= 1;
        end
    end

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        integer i;
        srst = 1;
        txn_valid        = 0;
        txn_device_id    = 0;
        txn_vaddr        = 0;
        txn_is_read      = 0;
        txn_is_write     = 0;
        iommu_enable     = 0;
        dct_base_ppn     = 0;
        fault_ready      = 1;
        iotlb_inv_valid  = 0;
        iotlb_inv_device_id = 0;
        iotlb_inv_all    = 0;
        dc_inv_valid     = 0;
        dc_inv_device_id = 0;
        dc_inv_all       = 0;
        for (i = 0; i < 16384; i = i + 1)
            mem[i] = 32'h0;
        repeat (4) @(posedge clk);
        srst = 0;
        @(posedge clk);
        #1;
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

    // Submit a transaction and wait for completion
    task automatic submit_txn(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [VADDR_W-1:0]     vaddr,
        input logic                    is_read,
        input logic                    is_write
    );
        txn_valid     = 1;
        txn_device_id = dev_id;
        txn_vaddr     = vaddr;
        txn_is_read   = is_read;
        txn_is_write  = is_write;
        @(posedge clk);
        while (!txn_ready) @(posedge clk);
        #1;
        txn_valid = 0;
    endtask

    // Wait for txn_done
    task automatic wait_txn_done();
        integer timeout;
        timeout = 0;
        while (!txn_done && timeout < 50) begin
            @(posedge clk);
            #1;
            timeout = timeout + 1;
        end
        if (timeout >= 50)
            $display("ERROR: wait_txn_done timed out! state=%0d", dut.state);
    endtask

    // Helper: set up device context entry in memory
    // DC entry address = {dct_base_ppn, 12'b0} + device_id * 8
    // Word 0: {pt_root_ppn[21:0], rsv[1:0], mode[3:0], fp, wp, rp, en}
    // Word 1: reserved (0)
    task automatic setup_dc_entry(
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [PPN_W-1:0]       pt_root_ppn,
        input logic [3:0]             mode,
        input logic                   en,
        input logic                   rp,
        input logic                   wp,
        input logic                   fp
    );
        logic [PADDR_W-1:0] dc_addr;
        logic [31:0] word0;
        dc_addr = {dct_base_ppn, 12'b0} + {{(PADDR_W-DEVICE_ID_W-3){1'b0}}, dev_id, 3'b000};
        word0 = {pt_root_ppn, 2'b00, mode, fp, wp, rp, en};
        mem[dc_addr[15:2]]     = word0;
        mem[dc_addr[15:2] + 1] = 32'h0;  // word 1 reserved
    endtask

    // Helper: set up a page table entry at a byte address
    // PTE format: {ppn1[11:0], ppn0[9:0], rsw[1:0], D, A, G, U, X, W, R, V}
    task automatic setup_pte_at(
        input logic [15:0]  byte_addr,
        input logic [11:0]  ppn1,
        input logic [9:0]   ppn0,
        input logic         r,
        input logic         w,
        input logic         x,
        input logic         v
    );
        logic [31:0] pte;
        // Set A=1, D=1 as required by spec
        pte = {ppn1, ppn0, 2'b00, 1'b1, 1'b1, 1'b0, 1'b0, x, w, r, v};
        mem[byte_addr[15:2]] = pte;
    endtask

    // ===================== Test tasks =====================
    // Address layout (all within 64KB):
    //   DCT base PPN = 0x001 -> phys 0x1000
    //   DC entries at 0x1000 + dev_id*8
    //   Page table roots: PPN 0x002 -> phys 0x2000, PPN 0x003 -> 0x3000, etc.
    //   L0 tables: PPN 0x004 -> 0x4000, PPN 0x005 -> 0x5000, etc.

    // Test 1: Bypass mode -- IOMMU disabled
    task automatic test_bypass();
        reset_dut();
        iommu_enable = 0;
        dct_base_ppn = 22'h000_001;

        submit_txn(8'h01, 32'hBEEF_0000, 1, 0);
        wait_txn_done();

        check("Bypass mode -- txn_done asserted", txn_done == 1'b1);
        check("Bypass mode -- no fault", txn_fault == 1'b0);
        check("Bypass mode -- address passes through",
              txn_paddr == {2'b0, 32'hBEEF_0000});
    endtask

    // Test 2: Bare mode -- device context with mode=BARE
    task automatic test_bare_mode();
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;  // DC table at 0x1000

        // Device 2: en=1, rp=1, wp=1, mode=BARE
        setup_dc_entry(8'h02, 22'h0, MODE_BARE, 1, 1, 1, 0);

        submit_txn(8'h02, 32'h1234_5678, 1, 0);
        wait_txn_done();

        check("Bare mode -- txn_done asserted", txn_done == 1'b1);
        check("Bare mode -- no fault", txn_fault == 1'b0);
        check("Bare mode -- address passes through",
              txn_paddr == {2'b0, 32'h1234_5678});
    endtask

    // Test 3: Successful Sv32 translation (full flow)
    task automatic test_sv32_translation();
        logic [PPN_W-1:0] expected_ppn;
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;  // DC table at 0x1000

        // Device 1: en=1, rp=1, wp=1, mode=Sv32, pt_root PPN=0x002 (phys 0x2000)
        setup_dc_entry(8'h01, 22'h000_002, MODE_SV32, 1, 1, 1, 0);

        // Virtual address: 0x0040_1000
        // vpn1 = vaddr[31:22] = 1
        // vpn0 = vaddr[21:12] = 1
        // offset = 0x000

        // L1 PTE at: {0x002, 12'b0} + vpn1*4 = 0x2000 + 4 = 0x2004
        // Non-leaf PTE: points to L0 table at PPN=0x004 (phys 0x4000)
        setup_pte_at(16'h2004, 12'h000, 10'h004, 0, 0, 0, 1);  // non-leaf

        // L0 PTE at: {0x004, 12'b0} + vpn0*4 = 0x4000 + 4 = 0x4004
        // Leaf PTE: ppn = {ppn1=0x050, ppn0=0x010}
        expected_ppn = {12'h050, 10'h010};
        setup_pte_at(16'h4004, 12'h050, 10'h010, 1, 1, 0, 1);  // leaf R=1,W=1

        submit_txn(8'h01, 32'h0040_1000, 1, 0);
        wait_txn_done();

        check("Sv32 translation -- txn_done asserted", txn_done == 1'b1);
        check("Sv32 translation -- no fault", txn_fault == 1'b0);
        check("Sv32 translation -- correct physical address",
              txn_paddr == {expected_ppn, 12'h000});
    endtask

    // Test 4: IOTLB hit on second access
    task automatic test_iotlb_hit();
        logic [PPN_W-1:0] expected_ppn;
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Same setup as test 3
        setup_dc_entry(8'h01, 22'h000_002, MODE_SV32, 1, 1, 1, 0);
        setup_pte_at(16'h2004, 12'h000, 10'h004, 0, 0, 0, 1);
        expected_ppn = {12'h050, 10'h010};
        setup_pte_at(16'h4004, 12'h050, 10'h010, 1, 1, 0, 1);

        // First access -- cold miss, PTW walk
        submit_txn(8'h01, 32'h0040_1000, 1, 0);
        wait_txn_done();
        check("IOTLB hit -- first access succeeds", txn_done == 1'b1 && txn_fault == 1'b0);

        @(posedge clk); #1;

        // Second access -- should hit IOTLB
        submit_txn(8'h01, 32'h0040_1ABC, 1, 0);
        wait_txn_done();

        check("IOTLB hit -- second access succeeds", txn_done == 1'b1);
        check("IOTLB hit -- no fault", txn_fault == 1'b0);
        check("IOTLB hit -- correct physical address",
              txn_paddr == {expected_ppn, 12'hABC});
    endtask

    // Test 5: Superpage translation
    task automatic test_superpage();
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 3: mode=Sv32, pt_root PPN=0x003 (phys 0x3000)
        setup_dc_entry(8'h03, 22'h000_003, MODE_SV32, 1, 1, 1, 0);

        // vaddr = 0x0080_2345
        // vpn1 = vaddr[31:22] = 2
        // vpn0 = vaddr[21:12] = 2
        // offset = 0x345

        // L1 PTE at: {0x003, 12'b0} + 2*4 = 0x3000 + 8 = 0x3008
        // Superpage leaf: ppn1=0x100, ppn0=0x000 (aligned)
        setup_pte_at(16'h3008, 12'h100, 10'h000, 1, 1, 0, 1);

        submit_txn(8'h03, 32'h0080_2345, 1, 0);
        wait_txn_done();

        check("Superpage -- txn_done asserted", txn_done == 1'b1);
        check("Superpage -- no fault", txn_fault == 1'b0);
        // Superpage: paddr = {ppn[21:10], vaddr[21:0]} = {0x100, 22'h00_2345}
        check("Superpage -- correct physical address",
              txn_paddr == {12'h100, 22'h00_2345});
    endtask

    // Test 6: Device context fault -- EN=0
    task automatic test_ctx_fault_disabled();
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 4: en=0 (disabled)
        setup_dc_entry(8'h04, 22'h0, MODE_SV32, 0, 0, 0, 0);

        submit_txn(8'h04, 32'h0000_1000, 1, 0);
        wait_txn_done();

        check("Ctx fault disabled -- txn_done asserted", txn_done == 1'b1);
        check("Ctx fault disabled -- fault asserted", txn_fault == 1'b1);
        check("Ctx fault disabled -- cause is CTX_INVALID",
              txn_fault_cause == CAUSE_CTX_INVALID);
    endtask

    // Test 7: Read permission fault -- context RP=0
    task automatic test_ctx_read_denied();
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 5: en=1, rp=0, wp=1, mode=Sv32
        setup_dc_entry(8'h05, 22'h000_002, MODE_SV32, 1, 0, 1, 0);

        submit_txn(8'h05, 32'h0000_1000, 1, 0);
        wait_txn_done();

        check("Ctx read denied -- txn_done asserted", txn_done == 1'b1);
        check("Ctx read denied -- fault asserted", txn_fault == 1'b1);
        check("Ctx read denied -- cause is CTX_READ_DENIED",
              txn_fault_cause == CAUSE_CTX_READ_DENIED);
    endtask

    // Test 8: PTE fault -- invalid PTE in page table
    task automatic test_pte_fault();
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 6: en=1, rp=1, wp=1, mode=Sv32, pt_root PPN=0x005
        setup_dc_entry(8'h06, 22'h000_005, MODE_SV32, 1, 1, 1, 0);

        // vaddr = 0x0000_1000, vpn1=0, vpn0=1
        // L1 PTE at: {0x005, 12'b0} + 0*4 = 0x5000
        // Invalid PTE: V=0
        mem[16'h5000 >> 2] = 32'h0000_0000;

        submit_txn(8'h06, 32'h0000_1000, 1, 0);
        wait_txn_done();

        check("PTE fault -- txn_done asserted", txn_done == 1'b1);
        check("PTE fault -- fault asserted", txn_fault == 1'b1);
        check("PTE fault -- cause is PTE_INVALID",
              txn_fault_cause == CAUSE_PTE_INVALID);
    endtask

    // Test 9: Multiple devices -- isolation
    task automatic test_device_isolation();
        logic [PPN_W-1:0] ppn_dev1;
        logic [PPN_W-1:0] ppn_dev2;
        logic [PADDR_W-1:0] paddr1, paddr2;
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 1: pt_root PPN=0x002 (phys 0x2000)
        setup_dc_entry(8'h01, 22'h000_002, MODE_SV32, 1, 1, 1, 0);
        // vpn1=0, vpn0=1 -> L1 at 0x2000, L0 at PPN 0x004 (0x4000)
        setup_pte_at(16'h2000, 12'h000, 10'h004, 0, 0, 0, 1);  // L1 non-leaf
        ppn_dev1 = {12'h060, 10'h010};
        setup_pte_at(16'h4004, 12'h060, 10'h010, 1, 1, 0, 1);  // L0 leaf

        // Device 2: pt_root PPN=0x006 (phys 0x6000)
        setup_dc_entry(8'h02, 22'h000_006, MODE_SV32, 1, 1, 1, 0);
        // vpn1=0, vpn0=1 -> L1 at 0x6000, L0 at PPN 0x007 (0x7000)
        setup_pte_at(16'h6000, 12'h000, 10'h007, 0, 0, 0, 1);  // L1 non-leaf
        ppn_dev2 = {12'h0A0, 10'h020};
        setup_pte_at(16'h7004, 12'h0A0, 10'h020, 1, 1, 0, 1);  // L0 leaf

        // Same vaddr, device 1
        submit_txn(8'h01, 32'h0000_1800, 1, 0);
        wait_txn_done();
        paddr1 = txn_paddr;
        check("Device isolation -- dev1 no fault", txn_fault == 1'b0);

        @(posedge clk); #1;

        // Same vaddr, device 2
        submit_txn(8'h02, 32'h0000_1800, 1, 0);
        wait_txn_done();
        paddr2 = txn_paddr;
        check("Device isolation -- dev2 no fault", txn_fault == 1'b0);

        check("Device isolation -- different physical addresses",
              paddr1 != paddr2);
        check("Device isolation -- dev1 correct paddr",
              paddr1 == {ppn_dev1, 12'h800});
        check("Device isolation -- dev2 correct paddr",
              paddr2 == {ppn_dev2, 12'h800});
    endtask

    // Test 10: IOTLB invalidation
    task automatic test_iotlb_invalidation();
        logic [PPN_W-1:0] expected_ppn;
        reset_dut();
        iommu_enable = 1;
        dct_base_ppn = 22'h000_001;

        // Device 7: pt_root PPN=0x008 (phys 0x8000)
        setup_dc_entry(8'h07, 22'h000_008, MODE_SV32, 1, 1, 1, 0);
        // vpn1=0, vpn0=1 -> L1 at 0x8000, L0 at PPN 0x009 (0x9000)
        setup_pte_at(16'h8000, 12'h000, 10'h009, 0, 0, 0, 1);  // L1 non-leaf
        expected_ppn = {12'h0B0, 10'h005};
        setup_pte_at(16'h9004, 12'h0B0, 10'h005, 1, 1, 0, 1);  // L0 leaf

        // First access -- PTW walk
        submit_txn(8'h07, 32'h0000_1000, 1, 0);
        wait_txn_done();
        check("IOTLB inv -- first access no fault", txn_fault == 1'b0);

        @(posedge clk); #1;

        // Invalidate IOTLB for device 7
        iotlb_inv_valid     = 1;
        iotlb_inv_device_id = 8'h07;
        iotlb_inv_all       = 0;
        @(posedge clk); #1;
        iotlb_inv_valid = 0;
        @(posedge clk); #1;

        // Also invalidate DC cache
        dc_inv_valid     = 1;
        dc_inv_device_id = 8'h07;
        dc_inv_all       = 0;
        @(posedge clk); #1;
        dc_inv_valid = 0;
        @(posedge clk); #1;

        // Change mapping: new L0 PTE
        expected_ppn = {12'h0C0, 10'h006};
        setup_pte_at(16'h9004, 12'h0C0, 10'h006, 1, 1, 0, 1);

        // Second access -- should trigger new PTW walk
        submit_txn(8'h07, 32'h0000_1000, 1, 0);
        wait_txn_done();
        check("IOTLB inv -- second access no fault", txn_fault == 1'b0);
        check("IOTLB inv -- new physical address after invalidation",
              txn_paddr == {expected_ppn, 12'h000});
    endtask

    // Main
    initial begin
        $dumpfile("tb_iommu_core.vcd");
        $dumpvars(0, tb_iommu_core);

        test_bypass();
        test_bare_mode();
        test_sv32_translation();
        test_iotlb_hit();
        test_superpage();
        test_ctx_fault_disabled();
        test_ctx_read_denied();
        test_pte_fault();
        test_device_isolation();
        test_iotlb_invalidation();

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
