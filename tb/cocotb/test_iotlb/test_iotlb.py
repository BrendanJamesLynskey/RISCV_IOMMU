# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.lookup_valid.value = 0
    dut.lookup_device_id.value = 0
    dut.lookup_vpn1.value = 0
    dut.lookup_vpn0.value = 0
    dut.refill_valid.value = 0
    dut.refill_device_id.value = 0
    dut.refill_vpn1.value = 0
    dut.refill_vpn0.value = 0
    dut.refill_ppn.value = 0
    dut.refill_perm_r.value = 0
    dut.refill_perm_w.value = 0
    dut.refill_is_superpage.value = 0
    dut.inv_valid.value = 0
    dut.inv_device_id.value = 0
    dut.inv_all.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


async def do_refill(dut, device_id, vpn1, vpn0, ppn, perm_r, perm_w, is_superpage):
    """Perform a refill for one cycle then deassert."""
    dut.refill_valid.value = 1
    dut.refill_device_id.value = device_id
    dut.refill_vpn1.value = vpn1
    dut.refill_vpn0.value = vpn0
    dut.refill_ppn.value = ppn
    dut.refill_perm_r.value = perm_r
    dut.refill_perm_w.value = perm_w
    dut.refill_is_superpage.value = is_superpage
    await RisingEdge(dut.clk)
    dut.refill_valid.value = 0
    await RisingEdge(dut.clk)


async def do_lookup(dut, device_id, vpn1, vpn0):
    """Perform a lookup and return (hit, ppn, perm_r, perm_w, is_superpage).
    Only ppn/perm/superpage values are meaningful when hit=1."""
    dut.lookup_valid.value = 1
    dut.lookup_device_id.value = device_id
    dut.lookup_vpn1.value = vpn1
    dut.lookup_vpn0.value = vpn0
    await RisingEdge(dut.clk)
    hit = int(dut.lookup_hit.value)
    ppn = 0
    perm_r = 0
    perm_w = 0
    is_sp = 0
    if hit:
        ppn = int(dut.lookup_ppn.value)
        perm_r = int(dut.lookup_perm_r.value)
        perm_w = int(dut.lookup_perm_w.value)
        is_sp = int(dut.lookup_is_superpage.value)
    dut.lookup_valid.value = 0
    return hit, ppn, perm_r, perm_w, is_sp


async def refill_and_touch(dut, device_id, vpn1, vpn0, ppn, perm_r, perm_w, is_superpage):
    """Refill an entry and then look it up to update LRU, so the next refill
    doesn't overwrite the same slot."""
    await do_refill(dut, device_id, vpn1, vpn0, ppn, perm_r, perm_w, is_superpage)
    await do_lookup(dut, device_id, vpn1, vpn0)


@cocotb.test()
async def test_reset_miss(dut):
    """Lookup after reset returns miss."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    hit, _, _, _, _ = await do_lookup(dut, device_id=1, vpn1=0x10, vpn0=0x20)
    assert hit == 0, "Expected miss after reset"


@cocotb.test()
async def test_refill_and_hit(dut):
    """Refill one entry then lookup -- should hit."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    await do_refill(dut, device_id=1, vpn1=0x10, vpn0=0x20, ppn=0x2BCDE, perm_r=1, perm_w=1, is_superpage=0)

    hit, ppn, perm_r, perm_w, is_sp = await do_lookup(dut, device_id=1, vpn1=0x10, vpn0=0x20)
    assert hit == 1, "Expected hit after refill"
    assert ppn == 0x2BCDE, f"Expected ppn=0x2BCDE, got {hex(ppn)}"
    assert perm_r == 1, "Expected perm_r=1"
    assert perm_w == 1, "Expected perm_w=1"
    assert is_sp == 0, "Expected is_superpage=0"


@cocotb.test()
async def test_device_isolation(dut):
    """Same VPN, different device IDs are independent entries."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Refill for device 1 and touch it so LRU moves away
    await refill_and_touch(dut, device_id=1, vpn1=0x10, vpn0=0x20, ppn=0x11111, perm_r=1, perm_w=0, is_superpage=0)
    # Refill for device 2 with same VPN but different PPN
    await refill_and_touch(dut, device_id=2, vpn1=0x10, vpn0=0x20, ppn=0x22222, perm_r=0, perm_w=1, is_superpage=0)

    # Lookup device 1
    hit, ppn, perm_r, perm_w, _ = await do_lookup(dut, device_id=1, vpn1=0x10, vpn0=0x20)
    assert hit == 1, "Expected hit for device 1"
    assert ppn == 0x11111, f"Expected ppn=0x11111 for device 1, got {hex(ppn)}"
    assert perm_r == 1, "Expected perm_r=1 for device 1"
    assert perm_w == 0, "Expected perm_w=0 for device 1"

    # Lookup device 2
    hit, ppn, perm_r, perm_w, _ = await do_lookup(dut, device_id=2, vpn1=0x10, vpn0=0x20)
    assert hit == 1, "Expected hit for device 2"
    assert ppn == 0x22222, f"Expected ppn=0x22222 for device 2, got {hex(ppn)}"
    assert perm_r == 0, "Expected perm_r=0 for device 2"
    assert perm_w == 1, "Expected perm_w=1 for device 2"

    # Lookup device 3 (never refilled) -- should miss
    hit, _, _, _, _ = await do_lookup(dut, device_id=3, vpn1=0x10, vpn0=0x20)
    assert hit == 0, "Expected miss for device 3"


@cocotb.test()
async def test_superpage(dut):
    """Superpage refill matches any vpn0."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Refill superpage
    await do_refill(dut, device_id=5, vpn1=0x3F, vpn0=0, ppn=0x100, perm_r=1, perm_w=1, is_superpage=1)

    # Lookup with different vpn0 values -- should all hit
    for vpn0 in [0x00, 0x55, 0xFF, 0x3FF]:
        hit, ppn, _, _, is_sp = await do_lookup(dut, device_id=5, vpn1=0x3F, vpn0=vpn0)
        assert hit == 1, f"Expected superpage hit with vpn0={hex(vpn0)}"
        assert ppn == 0x100, f"Expected ppn=0x100, got {hex(ppn)}"
        assert is_sp == 1, "Expected is_superpage=1"

    # Different vpn1 should miss
    hit, _, _, _, _ = await do_lookup(dut, device_id=5, vpn1=0x3E, vpn0=0)
    assert hit == 0, "Expected miss for different vpn1"


@cocotb.test()
async def test_invalidation(dut):
    """Selective and global invalidation."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Refill entries for device 1 and device 2, touching each to move LRU
    await refill_and_touch(dut, device_id=1, vpn1=0x01, vpn0=0x01, ppn=0x100, perm_r=1, perm_w=1, is_superpage=0)
    await refill_and_touch(dut, device_id=2, vpn1=0x02, vpn0=0x02, ppn=0x200, perm_r=1, perm_w=1, is_superpage=0)

    # Selective invalidation: invalidate device 1 only
    dut.inv_valid.value = 1
    dut.inv_device_id.value = 1
    dut.inv_all.value = 0
    await RisingEdge(dut.clk)
    dut.inv_valid.value = 0
    await RisingEdge(dut.clk)

    # Device 1 should miss, device 2 should still hit
    hit, _, _, _, _ = await do_lookup(dut, device_id=1, vpn1=0x01, vpn0=0x01)
    assert hit == 0, "Expected miss for invalidated device 1"
    hit, _, _, _, _ = await do_lookup(dut, device_id=2, vpn1=0x02, vpn0=0x02)
    assert hit == 1, "Expected hit for device 2 (not invalidated)"

    # Global invalidation
    dut.inv_valid.value = 1
    dut.inv_all.value = 1
    await RisingEdge(dut.clk)
    dut.inv_valid.value = 0
    dut.inv_all.value = 0
    await RisingEdge(dut.clk)

    hit, _, _, _, _ = await do_lookup(dut, device_id=2, vpn1=0x02, vpn0=0x02)
    assert hit == 0, "Expected miss after global invalidation"


@cocotb.test()
async def test_capacity_eviction(dut):
    """Overflow the TLB (16 entries), check LRU eviction."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    depth = 16

    # Fill all 16 entries, touching each after refill to update LRU
    for i in range(depth):
        await refill_and_touch(dut, device_id=i, vpn1=0x10, vpn0=0x20, ppn=0x1000 + i,
                               perm_r=1, perm_w=1, is_superpage=0)

    # Add a 17th entry -- should evict the LRU entry
    await do_refill(dut, device_id=0xFF, vpn1=0x10, vpn0=0x20, ppn=0x9999,
                    perm_r=1, perm_w=1, is_superpage=0)

    # The new entry should hit
    hit, ppn, _, _, _ = await do_lookup(dut, device_id=0xFF, vpn1=0x10, vpn0=0x20)
    assert hit == 1, "Expected hit for newly added entry 0xFF"
    assert ppn == 0x9999, f"Expected ppn=0x9999, got {hex(ppn)}"

    # Count how many of the original 16 still hit -- should be 15 (one evicted)
    hits = 0
    for i in range(depth):
        hit, _, _, _, _ = await do_lookup(dut, device_id=i, vpn1=0x10, vpn0=0x20)
        hits += hit
    assert hits == depth - 1, f"Expected {depth-1} hits after eviction, got {hits}"
