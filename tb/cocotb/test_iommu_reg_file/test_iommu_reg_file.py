# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer


# Register offsets
REG_IOMMU_CAP       = 0x00
REG_IOMMU_CTRL      = 0x04
REG_IOMMU_STATUS    = 0x08
REG_DCT_BASE        = 0x0C
REG_FQ_BASE         = 0x10
REG_FQ_HEAD         = 0x14
REG_FQ_TAIL         = 0x18
REG_FQ_HEAD_INC     = 0x1C
REG_FQ_SIZE_LOG2    = 0x20
REG_IOTLB_INV       = 0x24
REG_DC_INV          = 0x28
REG_PERF_IOTLB_HIT  = 0x2C
REG_PERF_IOTLB_MISS = 0x30
REG_PERF_FAULT_CNT  = 0x34
REG_FQ_READ_DATA_LO = 0x38
REG_FQ_READ_DATA_HI = 0x3C

CAP_VALUE = 0x00000081


async def reset_dut(dut):
    dut.srst.value = 1
    dut.reg_wr_valid.value = 0
    dut.reg_wr_addr.value = 0
    dut.reg_wr_data.value = 0
    dut.reg_rd_valid.value = 0
    dut.reg_rd_addr.value = 0
    dut.fault_pending.value = 0
    dut.fq_head.value = 0
    dut.fq_tail.value = 0
    dut.fq_read_data.value = 0
    dut.perf_iotlb_hit.value = 0
    dut.perf_iotlb_miss.value = 0
    dut.perf_fault.value = 0
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


@cocotb.test()
async def test_reset_defaults(dut):
    """Verify default register values after reset."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    assert int(dut.iommu_enable.value) == 0, "iommu_enable should be 0 after reset"
    assert int(dut.fault_irq_en.value) == 0, "fault_irq_en should be 0 after reset"
    assert int(dut.dct_base_ppn.value) == 0, "dct_base_ppn should be 0 after reset"
    assert int(dut.fq_base_ppn.value) == 0, "fq_base_ppn should be 0 after reset"

    # Read capability register
    cap = await reg_read(dut, REG_IOMMU_CAP)
    assert cap == CAP_VALUE, f"Expected CAP={CAP_VALUE:#x}, got {cap:#x}"


@cocotb.test()
async def test_read_write_ctrl(dut):
    """Write and read CTRL, DCT_BASE, FQ_BASE registers."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Write CTRL to enable IOMMU and fault IRQ
    await reg_write(dut, REG_IOMMU_CTRL, 0x3)
    assert int(dut.iommu_enable.value) == 1, "iommu_enable should be 1"
    assert int(dut.fault_irq_en.value) == 1, "fault_irq_en should be 1"

    ctrl = await reg_read(dut, REG_IOMMU_CTRL)
    assert ctrl == 0x3, f"Expected CTRL=0x3, got {ctrl:#x}"

    # Write DCT_BASE
    await reg_write(dut, REG_DCT_BASE, 0x123)
    dct = await reg_read(dut, REG_DCT_BASE)
    assert dct == 0x123, f"Expected DCT_BASE=0x123, got {dct:#x}"

    # Write FQ_BASE
    await reg_write(dut, REG_FQ_BASE, 0x456)
    fq = await reg_read(dut, REG_FQ_BASE)
    assert fq == 0x456, f"Expected FQ_BASE=0x456, got {fq:#x}"


@cocotb.test()
async def test_invalidation_pulses(dut):
    """Write IOTLB_INV and DC_INV and verify pulse outputs."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # The register file uses always_ff: pulse is set on the posedge where
    # reg_wr_valid is sampled high. Use Timer to allow NBA to settle.
    # Write IOTLB_INV with device_id=5
    dut.reg_wr_valid.value = 1
    dut.reg_wr_addr.value = REG_IOTLB_INV
    dut.reg_wr_data.value = 0x05
    await RisingEdge(dut.clk)
    dut.reg_wr_valid.value = 0
    await Timer(1, units="ns")
    # Pulse appears after NBA resolution
    assert int(dut.iotlb_inv_valid.value) == 1, "iotlb_inv_valid should be 1 during pulse"
    assert int(dut.iotlb_inv_device_id.value) == 0x05, "iotlb_inv_device_id should be 5"
    assert int(dut.iotlb_inv_all.value) == 0, "iotlb_inv_all should be 0"
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    # Pulse clears
    assert int(dut.iotlb_inv_valid.value) == 0, "iotlb_inv_valid should be cleared after pulse"

    # Write DC_INV with device_id=0x0A, inv_all=1
    dut.reg_wr_valid.value = 1
    dut.reg_wr_addr.value = REG_DC_INV
    dut.reg_wr_data.value = 0x10A  # device_id=0x0A, inv_all=bit8
    await RisingEdge(dut.clk)
    dut.reg_wr_valid.value = 0
    await Timer(1, units="ns")
    # Pulse appears
    assert int(dut.dc_inv_valid.value) == 1, "dc_inv_valid should be 1 during pulse"
    assert int(dut.dc_inv_device_id.value) == 0x0A, "dc_inv_device_id should be 0x0A"
    assert int(dut.dc_inv_all.value) == 1, "dc_inv_all should be 1"
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.dc_inv_valid.value) == 0, "dc_inv_valid should be cleared after pulse"


@cocotb.test()
async def test_fault_queue_registers(dut):
    """Verify FQ head/tail readback and head increment."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Set fq_head and fq_tail from fault_handler inputs
    dut.fq_head.value = 3
    dut.fq_tail.value = 7
    await RisingEdge(dut.clk)

    head = await reg_read(dut, REG_FQ_HEAD)
    assert head == 3, f"Expected FQ_HEAD=3, got {head}"

    tail = await reg_read(dut, REG_FQ_TAIL)
    assert tail == 7, f"Expected FQ_TAIL=7, got {tail}"

    # Write FQ_HEAD_INC and check the pulse
    dut.reg_wr_valid.value = 1
    dut.reg_wr_addr.value = REG_FQ_HEAD_INC
    dut.reg_wr_data.value = 1
    await RisingEdge(dut.clk)
    dut.reg_wr_valid.value = 0
    await Timer(1, units="ns")
    # Pulse is now active (registered from the write edge, visible after NBA)
    assert int(dut.fq_head_inc.value) == 1, "fq_head_inc should be 1 during pulse"
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.fq_head_inc.value) == 0, "fq_head_inc should be cleared"

    # Verify fault read data registers
    # fault_record_t is 64 bits: {faulting_addr[31:0], reserved1[15:0], device_id[7:0], cause[3:0], reserved0, is_write, is_read, valid}
    # Set a known fault record
    faulting_addr = 0xDEADBEEF
    device_id = 0x42
    cause = 0x3
    is_write = 0
    is_read = 1
    valid = 1
    # Low 32 bits: {reserved1[15:0], device_id[7:0], cause[3:0], reserved0, is_write, is_read, valid}
    low32 = (device_id << 8) | (cause << 4) | (is_write << 2) | (is_read << 1) | valid
    # High 32 bits: faulting_addr
    high32 = faulting_addr
    fq_read_data = (high32 << 32) | low32
    dut.fq_read_data.value = fq_read_data
    await RisingEdge(dut.clk)

    lo = await reg_read(dut, REG_FQ_READ_DATA_LO)
    assert lo == low32, f"Expected FQ_READ_DATA_LO={low32:#x}, got {lo:#x}"

    hi = await reg_read(dut, REG_FQ_READ_DATA_HI)
    assert hi == (faulting_addr & 0xFFFFFFFF), \
        f"Expected FQ_READ_DATA_HI={faulting_addr:#x}, got {hi:#x}"


@cocotb.test()
async def test_irq_generation(dut):
    """IRQ output when fault_pending and fault_irq_en are both set."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # No IRQ initially
    assert int(dut.irq_fault.value) == 0, "irq_fault should be 0 after reset"

    # Enable fault IRQ in CTRL
    await reg_write(dut, REG_IOMMU_CTRL, 0x2)  # bit 1 = fault_irq_en
    assert int(dut.fault_irq_en.value) == 1, "fault_irq_en should be 1"

    # No pending fault yet
    assert int(dut.irq_fault.value) == 0, "irq_fault should be 0 without fault_pending"

    # Assert fault_pending from fault handler
    dut.fault_pending.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.irq_fault.value) == 1, "irq_fault should be 1 with pending fault and IRQ enabled"

    # Clear fault_pending
    dut.fault_pending.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.irq_fault.value) == 0, "irq_fault should clear when fault_pending clears"

    # Disable IRQ, set pending
    dut.fault_pending.value = 1
    await reg_write(dut, REG_IOMMU_CTRL, 0x0)  # disable IRQ
    await RisingEdge(dut.clk)
    assert int(dut.irq_fault.value) == 0, "irq_fault should be 0 when IRQ disabled"
