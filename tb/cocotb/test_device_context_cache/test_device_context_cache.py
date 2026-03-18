# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


def pack_device_context(reserved_w1=0, pt_root_ppn=0, rsv=0, mode=0, fp=0, wp=0, rp=0, en=0):
    """Pack device_context_t fields into a 64-bit integer.

    Layout (MSB to LSB in packed struct):
      reserved_w1[31:0] | pt_root_ppn[21:0] | rsv[1:0] | mode[3:0] | fp | wp | rp | en
    Total: 32 + 22 + 2 + 4 + 1 + 1 + 1 + 1 = 64 bits
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


async def reset_dut(dut):
    dut.srst.value = 1
    dut.lookup_valid.value = 0
    dut.lookup_device_id.value = 0
    dut.refill_valid.value = 0
    dut.refill_device_id.value = 0
    dut.refill_ctx.value = 0
    dut.inv_valid.value = 0
    dut.inv_device_id.value = 0
    dut.inv_all.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


async def do_refill(dut, device_id, ctx_packed):
    """Refill for one cycle then deassert."""
    dut.refill_valid.value = 1
    dut.refill_device_id.value = device_id
    dut.refill_ctx.value = ctx_packed
    await RisingEdge(dut.clk)
    dut.refill_valid.value = 0
    await RisingEdge(dut.clk)


async def do_lookup(dut, device_id):
    """Perform a lookup, return (hit, ctx_value). ctx_value only valid when hit=1."""
    dut.lookup_valid.value = 1
    dut.lookup_device_id.value = device_id
    await RisingEdge(dut.clk)
    hit = int(dut.lookup_hit.value)
    ctx_val = 0
    if hit:
        ctx_val = int(dut.lookup_ctx.value)
    dut.lookup_valid.value = 0
    return hit, ctx_val


async def refill_and_touch(dut, device_id, ctx_packed):
    """Refill an entry and then look it up to update LRU."""
    await do_refill(dut, device_id, ctx_packed)
    await do_lookup(dut, device_id)


@cocotb.test()
async def test_reset_miss(dut):
    """Lookup after reset returns miss."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    hit, _ = await do_lookup(dut, device_id=1)
    assert hit == 0, "Expected miss after reset"


@cocotb.test()
async def test_refill_hit(dut):
    """Refill one entry then lookup -- should hit with correct context."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ctx = pack_device_context(pt_root_ppn=0x12345, mode=1, rp=1, wp=1, en=1)
    await do_refill(dut, device_id=5, ctx_packed=ctx)

    hit, ctx_out = await do_lookup(dut, device_id=5)
    assert hit == 1, "Expected hit after refill"
    assert ctx_out == ctx, f"Expected ctx={hex(ctx)}, got {hex(ctx_out)}"

    # Different device should miss
    hit, _ = await do_lookup(dut, device_id=6)
    assert hit == 0, "Expected miss for different device_id"


@cocotb.test()
async def test_invalidation(dut):
    """Selective and global invalidation."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    ctx1 = pack_device_context(pt_root_ppn=0x100, mode=1, rp=1, wp=1, en=1)
    ctx2 = pack_device_context(pt_root_ppn=0x200, mode=1, rp=1, wp=0, en=1)
    await refill_and_touch(dut, device_id=1, ctx_packed=ctx1)
    await refill_and_touch(dut, device_id=2, ctx_packed=ctx2)

    # Selective invalidation of device 1
    dut.inv_valid.value = 1
    dut.inv_device_id.value = 1
    dut.inv_all.value = 0
    await RisingEdge(dut.clk)
    dut.inv_valid.value = 0
    await RisingEdge(dut.clk)

    hit, _ = await do_lookup(dut, device_id=1)
    assert hit == 0, "Expected miss for invalidated device 1"
    hit, _ = await do_lookup(dut, device_id=2)
    assert hit == 1, "Expected hit for device 2 (not invalidated)"

    # Global invalidation
    dut.inv_valid.value = 1
    dut.inv_all.value = 1
    await RisingEdge(dut.clk)
    dut.inv_valid.value = 0
    dut.inv_all.value = 0
    await RisingEdge(dut.clk)

    hit, _ = await do_lookup(dut, device_id=2)
    assert hit == 0, "Expected miss after global invalidation"


@cocotb.test()
async def test_capacity_eviction(dut):
    """Overflow the cache (8 entries), check LRU eviction."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    depth = 8

    # Fill all 8 entries, touching each to update LRU
    for i in range(depth):
        ctx = pack_device_context(pt_root_ppn=0x1000 + i, mode=1, rp=1, wp=1, en=1)
        await refill_and_touch(dut, device_id=i, ctx_packed=ctx)

    # Add a 9th entry -- evicts LRU
    ctx_new = pack_device_context(pt_root_ppn=0x9999, mode=1, rp=1, wp=1, en=1)
    await do_refill(dut, device_id=0xFE, ctx_packed=ctx_new)

    # New entry should hit
    hit, ctx_out = await do_lookup(dut, device_id=0xFE)
    assert hit == 1, "Expected hit for newly added entry"

    # One of the original 8 should be evicted
    hits = 0
    for i in range(depth):
        hit, _ = await do_lookup(dut, device_id=i)
        hits += hit
    assert hits == depth - 1, f"Expected {depth-1} hits after eviction, got {hits}"
