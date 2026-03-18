// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_iommu_reg_file;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // DUT signals -- register access
    logic                    reg_wr_valid;
    logic                    reg_wr_ready;
    logic [7:0]              reg_wr_addr;
    logic [31:0]             reg_wr_data;

    logic                    reg_rd_valid;
    logic                    reg_rd_ready;
    logic [7:0]              reg_rd_addr;
    logic [31:0]             reg_rd_data;

    // Outputs to IOMMU datapath
    logic                    iommu_enable;
    logic                    fault_irq_en;
    logic [PPN_W-1:0]        dct_base_ppn;
    logic [PPN_W-1:0]        fq_base_ppn;
    logic [3:0]              fq_size_log2;

    // Fault queue interface (from fault_handler)
    logic                    fault_pending;
    logic [7:0]              fq_head;
    logic [7:0]              fq_tail;
    fault_record_t           fq_read_data;

    // Fault queue head increment
    logic                    fq_head_inc;

    // Invalidation outputs
    logic                    iotlb_inv_valid;
    logic [DEVICE_ID_W-1:0]  iotlb_inv_device_id;
    logic                    iotlb_inv_all;
    logic                    dc_inv_valid;
    logic [DEVICE_ID_W-1:0]  dc_inv_device_id;
    logic                    dc_inv_all;

    // Performance counter inputs
    logic                    perf_iotlb_hit;
    logic                    perf_iotlb_miss;
    logic                    perf_fault;

    // Interrupt output
    logic                    irq_fault;

    // Fault handler signals
    logic                    fh_fault_valid;
    logic                    fh_fault_ready;
    fault_record_t           fh_fault_record;
    logic                    fh_queue_full;
    logic [$clog2(FAULT_QUEUE_DEPTH)-1:0] fh_head, fh_tail;
    logic                    fh_fault_pending;
    fault_record_t           fh_read_data;
    logic                    fh_perf_fault;

    // Instantiate fault_handler
    fault_handler u_fh (
        .clk           (clk),
        .srst          (srst),
        .fault_valid   (fh_fault_valid),
        .fault_ready   (fh_fault_ready),
        .fault_record  (fh_fault_record),
        .head_inc      (fq_head_inc),
        .head          (fh_head),
        .tail          (fh_tail),
        .fault_pending (fh_fault_pending),
        .queue_full    (fh_queue_full),
        .read_data     (fh_read_data),
        .perf_fault    (fh_perf_fault)
    );

    // Connect fault_handler outputs to reg_file inputs
    assign fault_pending = fh_fault_pending;
    assign fq_head       = {4'b0, fh_head};
    assign fq_tail       = {4'b0, fh_tail};
    assign fq_read_data  = fh_read_data;

    // DUT instantiation
    iommu_reg_file dut (
        .clk              (clk),
        .srst             (srst),
        .reg_wr_valid     (reg_wr_valid),
        .reg_wr_ready     (reg_wr_ready),
        .reg_wr_addr      (reg_wr_addr),
        .reg_wr_data      (reg_wr_data),
        .reg_rd_valid     (reg_rd_valid),
        .reg_rd_ready     (reg_rd_ready),
        .reg_rd_addr      (reg_rd_addr),
        .reg_rd_data      (reg_rd_data),
        .iommu_enable     (iommu_enable),
        .fault_irq_en     (fault_irq_en),
        .dct_base_ppn     (dct_base_ppn),
        .fq_base_ppn      (fq_base_ppn),
        .fq_size_log2     (fq_size_log2),
        .fault_pending    (fault_pending),
        .fq_head          (fq_head),
        .fq_tail          (fq_tail),
        .fq_read_data     (fq_read_data),
        .fq_head_inc      (fq_head_inc),
        .iotlb_inv_valid  (iotlb_inv_valid),
        .iotlb_inv_device_id(iotlb_inv_device_id),
        .iotlb_inv_all    (iotlb_inv_all),
        .dc_inv_valid     (dc_inv_valid),
        .dc_inv_device_id (dc_inv_device_id),
        .dc_inv_all       (dc_inv_all),
        .perf_iotlb_hit   (perf_iotlb_hit),
        .perf_iotlb_miss  (perf_iotlb_miss),
        .perf_fault       (perf_fault),
        .irq_fault        (irq_fault)
    );

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // Helper tasks
    task automatic reset_dut();
        srst = 1;
        reg_wr_valid    = 0;
        reg_rd_valid    = 0;
        reg_wr_addr     = 0;
        reg_wr_data     = 0;
        reg_rd_addr     = 0;
        perf_iotlb_hit  = 0;
        perf_iotlb_miss = 0;
        perf_fault      = 0;
        fh_fault_valid  = 0;
        fh_fault_record = '0;
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

    // Write a register: assert valid for one cycle, wait for it to be latched
    task automatic reg_write(input logic [7:0] addr, input logic [31:0] data);
        @(posedge clk);
        reg_wr_valid = 1;
        reg_wr_addr  = addr;
        reg_wr_data  = data;
        @(posedge clk);
        reg_wr_valid = 0;
        #1;  // let NBA settle
    endtask

    // Read a register: the read is combinational, so assert valid and sample
    task automatic reg_read(input logic [7:0] addr, output logic [31:0] data);
        reg_rd_valid = 1;
        reg_rd_addr  = addr;
        #1;  // combinational settle
        data = reg_rd_data;
        reg_rd_valid = 0;
    endtask

    // ===================== Test tasks =====================

    task automatic test_reset();
        logic [31:0] rdata;
        reset_dut();
        reg_read(REG_IOMMU_CTRL, rdata);
        check("Reset -- CTRL register is 0", rdata == 32'h0);
        reg_read(REG_FQ_SIZE_LOG2, rdata);
        check("Reset -- FQ_SIZE_LOG2 default is 4", rdata == 32'h4);
        check("Reset -- iommu_enable is 0", iommu_enable == 1'b0);
    endtask

    task automatic test_read_capability();
        logic [31:0] rdata;
        reset_dut();
        reg_read(REG_IOMMU_CAP, rdata);
        check("Read capability register returns CAP_VALUE", rdata == CAP_VALUE);
    endtask

    task automatic test_write_read_ctrl();
        logic [31:0] rdata;
        reset_dut();
        reg_write(REG_IOMMU_CTRL, 32'h0000_0003);
        reg_read(REG_IOMMU_CTRL, rdata);
        check("Write/Read CTRL -- value matches", rdata == 32'h0000_0003);
        check("Write CTRL -- iommu_enable asserted", iommu_enable == 1'b1);
        check("Write CTRL -- fault_irq_en asserted", fault_irq_en == 1'b1);
    endtask

    task automatic test_write_read_dct_base();
        logic [31:0] rdata;
        logic [PPN_W-1:0] expected_ppn;
        reset_dut();
        expected_ppn = 22'h2A_BCDE;
        reg_write(REG_DCT_BASE, {10'b0, expected_ppn});
        reg_read(REG_DCT_BASE, rdata);
        check("Write/Read DCT_BASE -- PPN matches",
              rdata[PPN_W-1:0] == expected_ppn);
        check("Write DCT_BASE -- dct_base_ppn output matches",
              dct_base_ppn == expected_ppn);
    endtask

    task automatic test_iotlb_inv_pulse();
        reset_dut();
        reg_write(REG_IOTLB_INV, {23'b0, 1'b1, 8'hA5});
        // After reg_write, the pulse is set (NBA settled with #1)
        check("IOTLB invalidation -- valid pulsed", iotlb_inv_valid == 1'b1);
        check("IOTLB invalidation -- device_id correct",
              iotlb_inv_device_id == 8'hA5);
        check("IOTLB invalidation -- all flag set", iotlb_inv_all == 1'b1);
        // Wait one more cycle for pulse to clear
        @(posedge clk);
        #1;
        check("IOTLB invalidation -- pulse cleared after one cycle",
              iotlb_inv_valid == 1'b0);
    endtask

    task automatic test_dc_inv_pulse();
        reset_dut();
        reg_write(REG_DC_INV, {23'b0, 1'b0, 8'h42});
        check("DC invalidation -- valid pulsed", dc_inv_valid == 1'b1);
        check("DC invalidation -- device_id correct",
              dc_inv_device_id == 8'h42);
        check("DC invalidation -- all flag clear", dc_inv_all == 1'b0);
        @(posedge clk);
        #1;
        check("DC invalidation -- pulse cleared after one cycle",
              dc_inv_valid == 1'b0);
    endtask

    task automatic test_fq_head_tail();
        logic [31:0] rdata;
        logic [63:0] fr_bits;
        fault_record_t fr;
        reset_dut();

        // Initially head == tail == 0
        reg_read(REG_FQ_HEAD, rdata);
        check("FQ head/tail -- head is 0 after reset", rdata == 32'h0);
        reg_read(REG_FQ_TAIL, rdata);
        check("FQ head/tail -- tail is 0 after reset", rdata == 32'h0);

        // Inject a fault record via fault_handler
        fr.valid         = 1'b1;
        fr.is_read       = 1'b1;
        fr.is_write      = 1'b0;
        fr.reserved0     = 1'b0;
        fr.cause         = CAUSE_PTE_INVALID;
        fr.device_id     = 8'h05;
        fr.reserved1     = 16'h0;
        fr.faulting_addr = 32'hDEAD_BEEF;
        fr_bits = fr;

        fh_fault_valid  = 1;
        fh_fault_record = fr;
        @(posedge clk);
        #1;
        fh_fault_valid  = 0;
        @(posedge clk);
        #1;

        // Tail should have advanced
        reg_read(REG_FQ_TAIL, rdata);
        check("FQ head/tail -- tail advanced after fault write", rdata[7:0] == 8'h01);

        // Read fault data
        reg_read(REG_FQ_READ_DATA_LO, rdata);
        check("FQ read data lo -- matches fault record low bits",
              rdata == fr_bits[31:0]);
        reg_read(REG_FQ_READ_DATA_HI, rdata);
        check("FQ read data hi -- matches fault record high bits",
              rdata == fr_bits[63:32]);

        // Increment head via reg write
        reg_write(REG_FQ_HEAD_INC, 32'h1);
        // fq_head_inc pulse is now active; fault_handler processes on next edge
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        reg_read(REG_FQ_HEAD, rdata);
        check("FQ head/tail -- head advanced after head_inc", rdata[7:0] == 8'h01);
    endtask

    task automatic test_perf_counters();
        logic [31:0] rdata;
        reset_dut();

        // Pulse performance counter inputs: set before posedge, clear after
        perf_iotlb_hit = 1;
        @(posedge clk);
        #1;
        perf_iotlb_hit = 0;
        @(posedge clk);
        #1;
        perf_iotlb_hit = 1;
        @(posedge clk);
        #1;
        perf_iotlb_hit = 0;
        perf_iotlb_miss = 1;
        @(posedge clk);
        #1;
        perf_iotlb_miss = 0;
        @(posedge clk);
        #1;

        reg_read(REG_PERF_IOTLB_HIT, rdata);
        check("Perf counters -- IOTLB hit count is 2", rdata == 32'd2);
        reg_read(REG_PERF_IOTLB_MISS, rdata);
        check("Perf counters -- IOTLB miss count is 1", rdata == 32'd1);
    endtask

    task automatic test_irq_output();
        fault_record_t fr;
        reset_dut();

        // Enable fault IRQ
        reg_write(REG_IOMMU_CTRL, 32'h0000_0002);
        @(posedge clk);
        #1;

        // No fault pending yet -- IRQ should be low
        check("IRQ -- no fault pending, irq_fault is 0", irq_fault == 1'b0);

        // Inject a fault
        fr = '0;
        fr.valid     = 1'b1;
        fr.is_read   = 1'b1;
        fr.cause     = CAUSE_PTE_INVALID;
        fr.device_id = 8'h01;
        fr.faulting_addr = 32'h1000;

        fh_fault_valid  = 1;
        fh_fault_record = fr;
        @(posedge clk);
        #1;
        fh_fault_valid  = 0;
        @(posedge clk);
        #1;

        // Now fault_pending should be high, and with fault_irq_en -> irq_fault
        check("IRQ -- fault pending with irq_en, irq_fault is 1", irq_fault == 1'b1);

        // Disable IRQ via CTRL
        reg_write(REG_IOMMU_CTRL, 32'h0000_0000);
        @(posedge clk);
        #1;
        check("IRQ -- irq disabled, irq_fault is 0", irq_fault == 1'b0);
    endtask

    // Main
    initial begin
        $dumpfile("tb_iommu_reg_file.vcd");
        $dumpvars(0, tb_iommu_reg_file);

        test_reset();
        test_read_capability();
        test_write_read_ctrl();
        test_write_read_dct_base();
        test_iotlb_inv_pulse();
        test_dc_inv_pulse();
        test_fq_head_tail();
        test_perf_counters();
        test_irq_output();

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
