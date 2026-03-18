// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_iommu_axi_wrapper;
    import iommu_pkg::*;

    // Clock and reset
    logic clk, srst;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // AXI4 Slave Interface (Device Side)
    logic [AXI_ID_W-1:0]    s_axi_awid;
    logic [AXI_ADDR_W-1:0]  s_axi_awaddr;
    logic [7:0]             s_axi_awlen;
    logic [2:0]             s_axi_awsize;
    logic [1:0]             s_axi_awburst;
    logic                   s_axi_awvalid;
    logic                   s_axi_awready;
    logic [AXI_DATA_W-1:0]  s_axi_wdata;
    logic [AXI_STRB_W-1:0]  s_axi_wstrb;
    logic                   s_axi_wlast;
    logic                   s_axi_wvalid;
    logic                   s_axi_wready;
    logic [AXI_ID_W-1:0]    s_axi_bid;
    logic [1:0]             s_axi_bresp;
    logic                   s_axi_bvalid;
    logic                   s_axi_bready;
    logic [AXI_ID_W-1:0]    s_axi_arid;
    logic [AXI_ADDR_W-1:0]  s_axi_araddr;
    logic [7:0]             s_axi_arlen;
    logic [2:0]             s_axi_arsize;
    logic [1:0]             s_axi_arburst;
    logic                   s_axi_arvalid;
    logic                   s_axi_arready;
    logic [AXI_ID_W-1:0]    s_axi_rid;
    logic [AXI_DATA_W-1:0]  s_axi_rdata;
    logic [1:0]             s_axi_rresp;
    logic                   s_axi_rlast;
    logic                   s_axi_rvalid;
    logic                   s_axi_rready;

    // AXI4 Master Interface (Memory Side)
    logic [AXI_ID_W-1:0]    m_axi_awid, m_axi_arid;
    logic [AXI_ADDR_W-1:0]  m_axi_awaddr, m_axi_araddr;
    logic [7:0]             m_axi_awlen, m_axi_arlen;
    logic [2:0]             m_axi_awsize, m_axi_arsize;
    logic [1:0]             m_axi_awburst, m_axi_arburst;
    logic                   m_axi_awvalid, m_axi_awready;
    logic [AXI_DATA_W-1:0]  m_axi_wdata;
    logic [AXI_STRB_W-1:0]  m_axi_wstrb;
    logic                   m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [AXI_ID_W-1:0]    m_axi_bid;
    logic [1:0]             m_axi_bresp;
    logic                   m_axi_bvalid, m_axi_bready;
    logic                   m_axi_arvalid, m_axi_arready;
    logic [AXI_ID_W-1:0]    m_axi_rid;
    logic [AXI_DATA_W-1:0]  m_axi_rdata;
    logic [1:0]             m_axi_rresp;
    logic                   m_axi_rlast, m_axi_rvalid, m_axi_rready;

    // Register access
    logic        reg_wr_valid, reg_wr_ready, reg_rd_valid, reg_rd_ready;
    logic [7:0]  reg_wr_addr, reg_rd_addr;
    logic [31:0] reg_wr_data, reg_rd_data;
    logic        irq_fault;

    // DUT
    iommu_axi_wrapper dut (.*);

    // ==================== Memory-side AXI slave model ====================
    logic [31:0] slave_mem [0:16383];

    // Slave read: respond one cycle after AR accepted
    logic                   slv_rd_pend;
    logic [AXI_ADDR_W-1:0]  slv_rd_addr;
    logic [AXI_ID_W-1:0]    slv_rd_id;

    // Slave write
    logic                   slv_wr_addr_pend;
    logic                   slv_wr_data_pend;
    logic [AXI_ADDR_W-1:0]  slv_wr_addr;
    logic [AXI_ID_W-1:0]    slv_wr_id;
    logic [AXI_DATA_W-1:0]  slv_wr_data_v;

    always_ff @(posedge clk) begin
        if (srst) begin
            m_axi_arready <= 1;
            m_axi_rvalid  <= 0; m_axi_rdata <= 0; m_axi_rresp <= 0;
            m_axi_rlast   <= 0; m_axi_rid <= 0;
            slv_rd_pend   <= 0;
            m_axi_awready <= 1; m_axi_wready <= 1;
            m_axi_bvalid  <= 0; m_axi_bresp <= 0; m_axi_bid <= 0;
            slv_wr_addr_pend <= 0; slv_wr_data_pend <= 0;
        end else begin
            // ---- Read path ----
            // Clear rvalid when accepted
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid  <= 0;
                m_axi_arready <= 1;
            end
            // Produce response
            if (slv_rd_pend && !m_axi_rvalid) begin
                m_axi_rvalid  <= 1;
                m_axi_rdata   <= slave_mem[slv_rd_addr[15:2]];
                m_axi_rresp   <= 2'b00;
                m_axi_rlast   <= 1;
                m_axi_rid     <= slv_rd_id;
                slv_rd_pend   <= 0;
            end
            // Accept AR
            if (m_axi_arvalid && m_axi_arready && !slv_rd_pend) begin
                slv_rd_addr   <= m_axi_araddr;
                slv_rd_id     <= m_axi_arid;
                slv_rd_pend   <= 1;
                m_axi_arready <= 0;
            end

            // ---- Write path ----
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid  <= 0;
                m_axi_awready <= 1;
                m_axi_wready  <= 1;
            end
            // Accept AW
            if (m_axi_awvalid && m_axi_awready) begin
                slv_wr_addr      <= m_axi_awaddr;
                slv_wr_id        <= m_axi_awid;
                slv_wr_addr_pend <= 1;
                m_axi_awready    <= 0;
            end
            // Accept W
            if (m_axi_wvalid && m_axi_wready) begin
                slv_wr_data_v    <= m_axi_wdata;
                slv_wr_data_pend <= 1;
                m_axi_wready     <= 0;
            end
            // Complete write
            if (slv_wr_addr_pend && slv_wr_data_pend && !m_axi_bvalid) begin
                slave_mem[slv_wr_addr[15:2]] <= slv_wr_data_v;
                m_axi_bvalid      <= 1;
                m_axi_bresp       <= 2'b00;
                m_axi_bid         <= slv_wr_id;
                slv_wr_addr_pend  <= 0;
                slv_wr_data_pend  <= 0;
            end
        end
    end

    // Counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_count = 0;

    // ==================== Helpers ====================

    task automatic reset_dut();
        integer i;
        srst = 1;
        s_axi_awid = 0; s_axi_awaddr = 0; s_axi_awlen = 0;
        s_axi_awsize = 3'b010; s_axi_awburst = 2'b01; s_axi_awvalid = 0;
        s_axi_wdata = 0; s_axi_wstrb = 4'hF; s_axi_wlast = 0; s_axi_wvalid = 0;
        s_axi_bready = 1;
        s_axi_arid = 0; s_axi_araddr = 0; s_axi_arlen = 0;
        s_axi_arsize = 3'b010; s_axi_arburst = 2'b01; s_axi_arvalid = 0;
        s_axi_rready = 1;
        reg_wr_valid = 0; reg_wr_addr = 0; reg_wr_data = 0;
        reg_rd_valid = 0; reg_rd_addr = 0;
        for (i = 0; i < 16384; i = i + 1) slave_mem[i] = 32'h0;
        repeat (4) @(posedge clk);
        srst = 0;
        @(posedge clk); #1;
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

    task automatic reg_write(input logic [7:0] addr, input logic [31:0] data);
        @(posedge clk);
        reg_wr_valid = 1; reg_wr_addr = addr; reg_wr_data = data;
        @(posedge clk);
        reg_wr_valid = 0;
        #1;
    endtask

    task automatic reg_read(input logic [7:0] addr, output logic [31:0] data);
        reg_rd_valid = 1; reg_rd_addr = addr;
        #1; data = reg_rd_data; reg_rd_valid = 0;
    endtask

    // AXI device-side read: drive AR, wait for R
    task automatic axi_read(
        input  logic [AXI_ADDR_W-1:0] addr,
        input  logic [AXI_ID_W-1:0]   id,
        output logic [AXI_DATA_W-1:0] rdata,
        output logic [1:0]            rresp
    );
        integer timeout;
        // Drive AR at negedge so signals stable before posedge
        @(negedge clk);
        s_axi_araddr  = addr;
        s_axi_arid    = id;
        s_axi_arlen   = 0;
        s_axi_arsize  = 3'b010;
        s_axi_arburst = 2'b01;
        s_axi_arvalid = 1;
        s_axi_rready  = 1;

        // Wait for posedge where wrapper accepts AR
        @(posedge clk);
        // Deassert arvalid at negedge
        @(negedge clk);
        s_axi_arvalid = 0;

        // Wait for R response
        timeout = 0;
        while (!s_axi_rvalid && timeout < 200) begin
            @(posedge clk);
            #1;
            timeout = timeout + 1;
        end
        rdata = s_axi_rdata;
        rresp = s_axi_rresp;
        if (timeout >= 200) $display("ERROR: axi_read timed out");
        @(posedge clk); #1;
    endtask

    // AXI device-side write: drive AW+W, wait for B
    task automatic axi_write(
        input  logic [AXI_ADDR_W-1:0] addr,
        input  logic [AXI_ID_W-1:0]   id,
        input  logic [AXI_DATA_W-1:0] wdata,
        output logic [1:0]            bresp
    );
        integer timeout;
        // Drive AW
        s_axi_awaddr  = addr;
        s_axi_awid    = id;
        s_axi_awlen   = 0;
        s_axi_awsize  = 3'b010;
        s_axi_awburst = 2'b01;
        s_axi_awvalid = 1;

        // Wait for AW acceptance
        @(posedge clk);
        @(negedge clk);
        s_axi_awvalid = 0;

        // Drive W at negedge
        @(negedge clk);
        s_axi_wdata  = wdata;
        s_axi_wstrb  = 4'hF;
        s_axi_wlast  = 1;
        s_axi_wvalid = 1;
        @(posedge clk);
        @(negedge clk);
        s_axi_wvalid = 0;
        s_axi_wlast  = 0;

        // Wait for B
        s_axi_bready = 1;
        timeout = 0;
        while (!s_axi_bvalid && timeout < 200) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        bresp = s_axi_bresp;
        if (timeout >= 200) $display("ERROR: axi_write timed out");
        @(posedge clk); #1;
    endtask

    task automatic configure_iommu(
        input logic [PPN_W-1:0] dct_base,
        input logic             enable,
        input logic             irq_en
    );
        reg_write(REG_DCT_BASE, {10'b0, dct_base});
        reg_write(REG_IOMMU_CTRL, {30'b0, irq_en, enable});
    endtask

    task automatic setup_dc_entry(
        input logic [PPN_W-1:0]       dct_base,
        input logic [DEVICE_ID_W-1:0] dev_id,
        input logic [PPN_W-1:0]       pt_root_ppn,
        input logic [3:0]             mode,
        input logic                   en,
        input logic                   rp,
        input logic                   wp
    );
        logic [PADDR_W-1:0] dc_addr;
        dc_addr = {dct_base, 12'b0} + {{(PADDR_W-DEVICE_ID_W-3){1'b0}}, dev_id, 3'b000};
        slave_mem[dc_addr[15:2]]     = {pt_root_ppn, 2'b00, mode, 1'b0, wp, rp, en};
        slave_mem[dc_addr[15:2] + 1] = 32'h0;
    endtask

    task automatic setup_pte_at(
        input logic [15:0] byte_addr,
        input logic [11:0] ppn1, input logic [9:0] ppn0,
        input logic r, input logic w, input logic x, input logic v
    );
        slave_mem[byte_addr[15:2]] = {ppn1, ppn0, 2'b00, 1'b1, 1'b1, 1'b0, 1'b0, x, w, r, v};
    endtask

    // ===================== Test tasks =====================

    task automatic test_axi_read_bypass();
        logic [AXI_DATA_W-1:0] rdata;
        logic [1:0] rresp;
        reset_dut();
        configure_iommu(22'h000_001, 0, 0);
        slave_mem[16'h2000 >> 2] = 32'hCAFE_BABE;
        axi_read(34'h0000_2000, 4'h1, rdata, rresp);
        check("AXI read bypass -- response OK", rresp == 2'b00);
        check("AXI read bypass -- data correct", rdata == 32'hCAFE_BABE);
    endtask

    task automatic test_axi_write_bypass();
        logic [1:0] bresp;
        reset_dut();
        configure_iommu(22'h000_001, 0, 0);
        axi_write(34'h0000_3000, 4'h2, 32'hDEAD_BEEF, bresp);
        check("AXI write bypass -- response OK", bresp == 2'b00);
        // Allow slave mem write to settle
        @(posedge clk); #1;
        check("AXI write bypass -- data written", slave_mem[16'h3000 >> 2] == 32'hDEAD_BEEF);
    endtask

    task automatic test_axi_read_translated();
        logic [AXI_DATA_W-1:0] rdata;
        logic [1:0] rresp;
        reset_dut();
        configure_iommu(22'h000_001, 1, 0);
        setup_dc_entry(22'h000_001, 8'h01, 22'h000_002, MODE_SV32, 1, 1, 1);
        // vaddr=0x0040_1000 -> vpn1=1, vpn0=1
        setup_pte_at(16'h2004, 12'h000, 10'h004, 0, 0, 0, 1);  // L1 non-leaf
        // Map to phys 0xA000: ppn={0x000, 0x00A}
        setup_pte_at(16'h4004, 12'h000, 10'h00A, 1, 1, 0, 1);  // L0 leaf
        slave_mem[16'hA000 >> 2] = 32'h1234_5678;

        axi_read(34'h0040_1000, 4'h1, rdata, rresp);
        check("AXI read translated -- response OK", rresp == 2'b00);
        check("AXI read translated -- data correct", rdata == 32'h1234_5678);
    endtask

    task automatic test_axi_write_translated();
        logic [1:0] bresp;
        reset_dut();
        configure_iommu(22'h000_001, 1, 0);
        setup_dc_entry(22'h000_001, 8'h02, 22'h000_003, MODE_SV32, 1, 1, 1);
        // vaddr=0x0000_1000 -> vpn1=0, vpn0=1
        setup_pte_at(16'h3000, 12'h000, 10'h005, 0, 0, 0, 1);
        setup_pte_at(16'h5004, 12'h000, 10'h00B, 1, 1, 0, 1);

        axi_write(34'h0000_1000, 4'h2, 32'hFACE_FEED, bresp);
        check("AXI write translated -- response OK", bresp == 2'b00);
        @(posedge clk); #1;
        check("AXI write translated -- data at translated addr",
              slave_mem[16'hB000 >> 2] == 32'hFACE_FEED);
    endtask

    task automatic test_fault_response();
        logic [AXI_DATA_W-1:0] rdata;
        logic [1:0] rresp;
        reset_dut();
        configure_iommu(22'h000_001, 1, 0);
        setup_dc_entry(22'h000_001, 8'h03, 22'h0, MODE_SV32, 0, 0, 0);
        axi_read(34'h0000_1000, 4'h3, rdata, rresp);
        check("Fault response -- SLVERR returned", rresp == 2'b10);
    endtask

    task automatic test_register_access();
        logic [31:0] rdata;
        reset_dut();
        reg_read(REG_IOMMU_CAP, rdata);
        check("Register access -- CAP reads correctly", rdata == CAP_VALUE);
        reg_write(REG_IOMMU_CTRL, 32'h0000_0003);
        reg_read(REG_IOMMU_CTRL, rdata);
        check("Register access -- CTRL write/read", rdata == 32'h0000_0003);
        reg_write(REG_DCT_BASE, {10'b0, 22'h3A_BCDE});
        reg_read(REG_DCT_BASE, rdata);
        check("Register access -- DCT_BASE write/read", rdata[PPN_W-1:0] == 22'h3A_BCDE);
    endtask

    task automatic test_back_to_back();
        logic [AXI_DATA_W-1:0] rdata1, rdata2;
        logic [1:0] rresp1, rresp2;
        reset_dut();
        configure_iommu(22'h000_001, 0, 0);
        slave_mem[16'h4000 >> 2] = 32'hAAAA_AAAA;
        slave_mem[16'h5000 >> 2] = 32'h5555_5555;
        axi_read(34'h0000_4000, 4'h1, rdata1, rresp1);
        axi_read(34'h0000_5000, 4'h1, rdata2, rresp2);
        check("Back-to-back -- first read OK", rresp1 == 2'b00 && rdata1 == 32'hAAAA_AAAA);
        check("Back-to-back -- second read OK", rresp2 == 2'b00 && rdata2 == 32'h5555_5555);
    endtask

    task automatic test_interrupt();
        logic [AXI_DATA_W-1:0] rdata;
        logic [1:0] rresp;
        reset_dut();
        configure_iommu(22'h000_001, 1, 1);
        check("Interrupt -- initially low", irq_fault == 1'b0);
        setup_dc_entry(22'h000_001, 8'h04, 22'h0, MODE_SV32, 0, 0, 0);
        axi_read(34'h0000_1000, 4'h4, rdata, rresp);
        repeat (3) @(posedge clk);
        #1;
        check("Interrupt -- fault response is SLVERR", rresp == 2'b10);
        check("Interrupt -- irq_fault asserted", irq_fault == 1'b1);
    endtask

    // Main
    initial begin
        $dumpfile("tb_iommu_axi_wrapper.vcd");
        $dumpvars(0, tb_iommu_axi_wrapper);

        test_axi_read_bypass();
        test_axi_write_bypass();
        test_axi_read_translated();
        test_axi_write_translated();
        test_fault_response();
        test_register_access();
        test_back_to_back();
        test_interrupt();

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
