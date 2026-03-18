# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


# Register offsets
REG_IOMMU_CAP    = 0x00
REG_IOMMU_CTRL   = 0x04
REG_DCT_BASE     = 0x0C


async def reset_dut(dut):
    dut.srst.value = 1
    # AXI slave (device side) inputs
    dut.s_axi_awid.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awlen.value = 0
    dut.s_axi_awsize.value = 2
    dut.s_axi_awburst.value = 1
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_wlast.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 1
    dut.s_axi_arid.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_arlen.value = 0
    dut.s_axi_arsize.value = 2
    dut.s_axi_arburst.value = 1
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 1
    # AXI master (memory side) inputs
    dut.m_axi_awready.value = 1
    dut.m_axi_wready.value = 1
    dut.m_axi_bid.value = 0
    dut.m_axi_bresp.value = 0
    dut.m_axi_bvalid.value = 0
    dut.m_axi_arready.value = 1
    dut.m_axi_rid.value = 0
    dut.m_axi_rdata.value = 0
    dut.m_axi_rresp.value = 0
    dut.m_axi_rlast.value = 0
    dut.m_axi_rvalid.value = 0
    # Register interface
    dut.reg_wr_valid.value = 0
    dut.reg_wr_addr.value = 0
    dut.reg_wr_data.value = 0
    dut.reg_rd_valid.value = 0
    dut.reg_rd_addr.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


async def reg_write(dut, addr, data):
    dut.reg_wr_valid.value = 1
    dut.reg_wr_addr.value = addr
    dut.reg_wr_data.value = data
    await RisingEdge(dut.clk)
    dut.reg_wr_valid.value = 0
    await RisingEdge(dut.clk)


async def reg_read(dut, addr):
    dut.reg_rd_valid.value = 1
    dut.reg_rd_addr.value = addr
    await RisingEdge(dut.clk)
    val = int(dut.reg_rd_data.value)
    dut.reg_rd_valid.value = 0
    return val


async def axi_mem_slave(dut, mem):
    """AXI slave on memory side: responds to AR with R, AW+W with B."""
    while True:
        await RisingEdge(dut.clk)
        # Handle read requests
        if int(dut.m_axi_arvalid.value) == 1 and int(dut.m_axi_arready.value) == 1:
            addr = int(dut.m_axi_araddr.value)
            rid = int(dut.m_axi_arid.value)
            word_addr = (addr >> 2) & 0xFFFFFFFF
            data = mem.get(word_addr, 0)
            rresp = 0 if word_addr in mem else 2  # SLVERR if not in mem
            await RisingEdge(dut.clk)
            dut.m_axi_rvalid.value = 1
            dut.m_axi_rdata.value = data
            dut.m_axi_rid.value = rid
            dut.m_axi_rresp.value = rresp
            dut.m_axi_rlast.value = 1
            while True:
                await RisingEdge(dut.clk)
                if int(dut.m_axi_rready.value) == 1:
                    break
            dut.m_axi_rvalid.value = 0
            dut.m_axi_rlast.value = 0

        # Handle write address (AW accepted)
        if int(dut.m_axi_awvalid.value) == 1 and int(dut.m_axi_awready.value) == 1:
            waddr = int(dut.m_axi_awaddr.value)
            wid = int(dut.m_axi_awid.value)
            # Wait for write data
            while True:
                await RisingEdge(dut.clk)
                if int(dut.m_axi_wvalid.value) == 1 and int(dut.m_axi_wready.value) == 1:
                    wdata = int(dut.m_axi_wdata.value)
                    word_addr = (waddr >> 2) & 0xFFFFFFFF
                    mem[word_addr] = wdata
                    break
            # Send write response
            await RisingEdge(dut.clk)
            dut.m_axi_bvalid.value = 1
            dut.m_axi_bid.value = wid
            dut.m_axi_bresp.value = 0  # OKAY
            while True:
                await RisingEdge(dut.clk)
                if int(dut.m_axi_bready.value) == 1:
                    break
            dut.m_axi_bvalid.value = 0


async def axi_slave_read(dut, addr, axi_id):
    """Issue an AXI read as device (slave side), return (data, resp)."""
    dut.s_axi_arvalid.value = 1
    dut.s_axi_araddr.value = addr
    dut.s_axi_arid.value = axi_id
    dut.s_axi_arlen.value = 0
    dut.s_axi_arsize.value = 2
    dut.s_axi_arburst.value = 1
    await RisingEdge(dut.clk)
    while int(dut.s_axi_arready.value) != 1:
        await RisingEdge(dut.clk)
    dut.s_axi_arvalid.value = 0

    # Wait for R response
    dut.s_axi_rready.value = 1
    for _ in range(300):
        await RisingEdge(dut.clk)
        if int(dut.s_axi_rvalid.value) == 1:
            data = int(dut.s_axi_rdata.value)
            resp = int(dut.s_axi_rresp.value)
            dut.s_axi_rready.value = 0
            return data, resp
    raise TimeoutError("AXI read response timeout")


async def axi_slave_write(dut, addr, data, axi_id):
    """Issue an AXI write as device (slave side), return bresp."""
    dut.s_axi_awvalid.value = 1
    dut.s_axi_awaddr.value = addr
    dut.s_axi_awid.value = axi_id
    dut.s_axi_awlen.value = 0
    dut.s_axi_awsize.value = 2
    dut.s_axi_awburst.value = 1
    await RisingEdge(dut.clk)
    while int(dut.s_axi_awready.value) != 1:
        await RisingEdge(dut.clk)
    dut.s_axi_awvalid.value = 0

    # Send write data
    dut.s_axi_wvalid.value = 1
    dut.s_axi_wdata.value = data
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_wlast.value = 1
    await RisingEdge(dut.clk)
    while int(dut.s_axi_wready.value) != 1:
        await RisingEdge(dut.clk)
    dut.s_axi_wvalid.value = 0
    dut.s_axi_wlast.value = 0

    # Wait for B response
    dut.s_axi_bready.value = 1
    for _ in range(300):
        await RisingEdge(dut.clk)
        if int(dut.s_axi_bvalid.value) == 1:
            bresp = int(dut.s_axi_bresp.value)
            dut.s_axi_bready.value = 0
            return bresp
    raise TimeoutError("AXI write response timeout")


def build_device_context(en, rp, wp, fp, mode, pt_root_ppn):
    word0 = ((pt_root_ppn & 0x3FFFFF) << 10) | ((mode & 0xF) << 4) | \
            ((fp & 1) << 3) | ((wp & 1) << 2) | ((rp & 1) << 1) | (en & 1)
    word1 = 0
    return word0, word1


def setup_translation(mem, dct_base_ppn, device_id, pt_root_ppn,
                      vpn1, vpn0, leaf_ppn, leaf_r=1, leaf_w=1):
    """Set up DC + page tables in memory for a standard 2-level translation."""
    dc_w0, dc_w1 = build_device_context(en=1, rp=1, wp=1, fp=0, mode=1,
                                         pt_root_ppn=pt_root_ppn)
    dc_base = dct_base_ppn << 10
    mem[dc_base + device_id * 2] = dc_w0
    mem[dc_base + device_id * 2 + 1] = dc_w1

    l0_table_ppn = pt_root_ppn + 1
    l1_pte = (l0_table_ppn << 10) | 0x1
    mem[(pt_root_ppn << 10) + vpn1] = l1_pte

    l0_pte = (leaf_ppn << 10) | 0x1
    if leaf_r:
        l0_pte |= 0x2
    if leaf_w:
        l0_pte |= 0x4
    mem[(l0_table_ppn << 10) + vpn0] = l0_pte


@cocotb.test()
async def test_axi_read_bypass(dut):
    """AXI read in bypass mode (IOMMU disabled) passes address through."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    # Put some data at the target address
    target_addr = 0x1000
    expected_data = 0xCAFEBABE
    mem[target_addr >> 2] = expected_data

    cocotb.start_soon(axi_mem_slave(dut, mem))

    # IOMMU disabled (default after reset)
    data, resp = await axi_slave_read(dut, addr=target_addr, axi_id=1)
    assert resp == 0, f"Expected OKAY response, got {resp}"
    assert data == expected_data, f"Expected data={expected_data:#x}, got {data:#x}"


@cocotb.test()
async def test_axi_write_bypass(dut):
    """AXI write in bypass mode passes through."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    cocotb.start_soon(axi_mem_slave(dut, mem))

    target_addr = 0x2000
    write_data = 0xDEADC0DE
    bresp = await axi_slave_write(dut, addr=target_addr, data=write_data, axi_id=2)
    assert bresp == 0, f"Expected OKAY bresp, got {bresp}"

    # Verify data was written to memory
    assert mem.get(target_addr >> 2) == write_data, \
        f"Expected mem[{target_addr >> 2:#x}]={write_data:#x}"


@cocotb.test()
async def test_axi_read_translated(dut):
    """AXI read with Sv32 translation."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    pt_root_ppn = 0x20
    device_id = 1  # AXI ID maps to device_id
    leaf_ppn = 0x300

    vpn1 = 2
    vpn0 = 3
    offset = 0x100
    vaddr = (vpn1 << 22) | (vpn0 << 12) | offset

    setup_translation(mem, dct_base_ppn, device_id, pt_root_ppn,
                      vpn1, vpn0, leaf_ppn)

    # Put data at translated address
    translated_addr = (leaf_ppn << 12) | offset
    expected_data = 0x12345678
    mem[translated_addr >> 2] = expected_data

    cocotb.start_soon(axi_mem_slave(dut, mem))

    # Enable IOMMU and set DCT base
    await reg_write(dut, REG_IOMMU_CTRL, 0x1)  # enable
    await reg_write(dut, REG_DCT_BASE, dct_base_ppn)

    data, resp = await axi_slave_read(dut, addr=vaddr, axi_id=device_id)
    assert resp == 0, f"Expected OKAY, got {resp}"
    assert data == expected_data, \
        f"Expected data={expected_data:#x}, got {data:#x}"


@cocotb.test()
async def test_axi_write_translated(dut):
    """AXI write with Sv32 translation."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    pt_root_ppn = 0x20
    device_id = 2
    leaf_ppn = 0x400

    vpn1 = 4
    vpn0 = 5
    offset = 0x200
    vaddr = (vpn1 << 22) | (vpn0 << 12) | offset

    setup_translation(mem, dct_base_ppn, device_id, pt_root_ppn,
                      vpn1, vpn0, leaf_ppn)

    cocotb.start_soon(axi_mem_slave(dut, mem))

    await reg_write(dut, REG_IOMMU_CTRL, 0x1)
    await reg_write(dut, REG_DCT_BASE, dct_base_ppn)

    write_data = 0xBEEFCAFE
    bresp = await axi_slave_write(dut, addr=vaddr, data=write_data, axi_id=device_id)
    assert bresp == 0, f"Expected OKAY, got {bresp}"

    translated_addr = (leaf_ppn << 12) | offset
    assert mem.get(translated_addr >> 2) == write_data, \
        f"Expected data at translated addr"


@cocotb.test()
async def test_axi_fault_response(dut):
    """Fault (disabled context) returns SLVERR on AXI."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    device_id = 3

    # Device context with EN=0
    dc_w0, dc_w1 = build_device_context(en=0, rp=0, wp=0, fp=0, mode=0,
                                         pt_root_ppn=0)
    dc_base = dct_base_ppn << 10
    mem[dc_base + device_id * 2] = dc_w0
    mem[dc_base + device_id * 2 + 1] = dc_w1

    cocotb.start_soon(axi_mem_slave(dut, mem))

    await reg_write(dut, REG_IOMMU_CTRL, 0x1)
    await reg_write(dut, REG_DCT_BASE, dct_base_ppn)

    data, resp = await axi_slave_read(dut, addr=0x1000, axi_id=device_id)
    assert resp == 2, f"Expected SLVERR (2), got {resp}"


@cocotb.test()
async def test_register_access(dut):
    """Write and read IOMMU registers via register interface."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Read capability register
    cap = await reg_read(dut, REG_IOMMU_CAP)
    assert cap == 0x81, f"Expected CAP=0x81, got {cap:#x}"

    # Write and read CTRL
    await reg_write(dut, REG_IOMMU_CTRL, 0x3)
    ctrl = await reg_read(dut, REG_IOMMU_CTRL)
    assert ctrl == 0x3, f"Expected CTRL=0x3, got {ctrl:#x}"

    # Write and read DCT_BASE
    await reg_write(dut, REG_DCT_BASE, 0xABC)
    dct = await reg_read(dut, REG_DCT_BASE)
    assert dct == 0xABC, f"Expected DCT_BASE=0xABC, got {dct:#x}"
