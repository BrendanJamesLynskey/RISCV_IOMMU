# Brendan Lynskey 2025
import cocotb
from cocotb.triggers import Timer


def pack_device_context(reserved_w1=0, pt_root_ppn=0, rsv=0, mode=0, fp=0, wp=0, rp=0, en=0):
    """Pack device_context_t fields into a 64-bit integer.

    Layout (MSB to LSB in packed struct):
      reserved_w1[31:0] | pt_root_ppn[21:0] | rsv[1:0] | mode[3:0] | fp | wp | rp | en
    """
    val = 0
    val |= (reserved_w1 & 0xFFFFFFFF) << 32
    val |= (pt_root_ppn & 0x3FFFFF) << 10
    val |= (rsv & 0x3) << 8
    val |= (mode & 0xF) << 4
    val |= (fp & 0x1) << 3
    val |= (wp & 0x1) << 2
    val |= (rp & 0x1) << 1
    val |= (en & 0x1)
    return val


# Fault cause codes (matching iommu_pkg.sv)
CAUSE_NONE             = 0x0
CAUSE_CTX_INVALID      = 0x5
CAUSE_CTX_READ_DENIED  = 0x6
CAUSE_CTX_WRITE_DENIED = 0x7


@cocotb.test()
async def test_ctx_disabled(dut):
    """EN=0 should produce CAUSE_CTX_INVALID fault."""
    ctx = pack_device_context(en=0, mode=1, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")

    assert int(dut.ctx_fault.value) == 1, "Expected fault when EN=0"
    assert int(dut.ctx_fault_cause.value) == CAUSE_CTX_INVALID, \
        f"Expected CAUSE_CTX_INVALID (0x5), got {hex(int(dut.ctx_fault_cause.value))}"


@cocotb.test()
async def test_read_write_permissions(dut):
    """Test all R/W permission combinations."""
    # Read permitted
    ctx = pack_device_context(en=1, mode=1, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 0, "Expected no fault for permitted read"

    # Read denied (rp=0)
    ctx = pack_device_context(en=1, mode=1, rp=0, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 1, "Expected fault for denied read"
    assert int(dut.ctx_fault_cause.value) == CAUSE_CTX_READ_DENIED, \
        f"Expected CAUSE_CTX_READ_DENIED, got {hex(int(dut.ctx_fault_cause.value))}"

    # Write permitted
    ctx = pack_device_context(en=1, mode=1, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 0
    dut.is_write.value = 1
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 0, "Expected no fault for permitted write"

    # Write denied (wp=0)
    ctx = pack_device_context(en=1, mode=1, rp=1, wp=0)
    dut.ctx.value = ctx
    dut.is_read.value = 0
    dut.is_write.value = 1
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 1, "Expected fault for denied write"
    assert int(dut.ctx_fault_cause.value) == CAUSE_CTX_WRITE_DENIED, \
        f"Expected CAUSE_CTX_WRITE_DENIED, got {hex(int(dut.ctx_fault_cause.value))}"


@cocotb.test()
async def test_translation_modes(dut):
    """Test Bare, Sv32, and invalid modes."""
    # Bare mode (mode=0000): no translation needed
    ctx = pack_device_context(en=1, mode=0, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 0, "Expected no fault in bare mode"
    assert int(dut.needs_translation.value) == 0, "Expected needs_translation=0 in bare mode"
    assert int(dut.ctx_valid.value) == 1, "Expected ctx_valid=1 in bare mode"

    # Sv32 mode (mode=0001): translation needed
    ctx = pack_device_context(en=1, mode=1, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 0, "Expected no fault in Sv32 mode"
    assert int(dut.needs_translation.value) == 1, "Expected needs_translation=1 in Sv32 mode"
    assert int(dut.ctx_valid.value) == 1, "Expected ctx_valid=1 in Sv32 mode"

    # Invalid mode (mode=0010): should fault
    ctx = pack_device_context(en=1, mode=2, rp=1, wp=1)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 1, "Expected fault for invalid mode"
    assert int(dut.ctx_fault_cause.value) == CAUSE_CTX_INVALID, \
        f"Expected CAUSE_CTX_INVALID for invalid mode, got {hex(int(dut.ctx_fault_cause.value))}"


@cocotb.test()
async def test_combined(dut):
    """Context with mixed settings -- read on write-only device."""
    # Write-only device: rp=0, wp=1
    ctx = pack_device_context(en=1, mode=1, rp=0, wp=1, pt_root_ppn=0x3FFFF)
    dut.ctx.value = ctx
    dut.is_read.value = 1
    dut.is_write.value = 0
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 1, "Expected fault for read on write-only device"
    assert int(dut.ctx_fault_cause.value) == CAUSE_CTX_READ_DENIED, \
        "Expected CAUSE_CTX_READ_DENIED"

    # Now try write on same device -- should succeed
    dut.is_read.value = 0
    dut.is_write.value = 1
    await Timer(1, units="ns")
    assert int(dut.ctx_fault.value) == 0, "Expected no fault for write on write-only device"
    assert int(dut.needs_translation.value) == 1, "Expected needs_translation=1 for Sv32 mode"
