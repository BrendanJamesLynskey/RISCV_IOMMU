# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.access_valid.value = 0
    dut.access_idx.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset(dut):
    """LRU index is 0 after reset."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    await RisingEdge(dut.clk)
    assert dut.lru_idx.value == 0, f"Expected lru_idx=0 after reset, got {dut.lru_idx.value}"


@cocotb.test()
async def test_sequential_access(dut):
    """Access entries 0..N-1 sequentially and verify LRU changes."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    depth = 16  # default DEPTH parameter

    # Access entries 0 through depth-1
    for i in range(depth):
        dut.access_valid.value = 1
        dut.access_idx.value = i
        await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)

    # After accessing all entries 0..15 in order, LRU should point to 0
    # (the least recently accessed)
    lru = int(dut.lru_idx.value)
    assert lru == 0, f"Expected lru_idx=0 after sequential access of all entries, got {lru}"


@cocotb.test()
async def test_lru_eviction(dut):
    """Access pattern leaves a known entry as LRU candidate."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # After reset, LRU is 0. Access entry 0 to move it out of LRU position.
    dut.access_valid.value = 1
    dut.access_idx.value = 0
    await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)

    lru_after = int(dut.lru_idx.value)
    # After accessing 0, the LRU should no longer be 0
    assert lru_after != 0, f"Expected lru_idx != 0 after accessing entry 0, got {lru_after}"

    # Now access the current LRU entry, and it should change again
    prev_lru = lru_after
    dut.access_valid.value = 1
    dut.access_idx.value = prev_lru
    await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)

    new_lru = int(dut.lru_idx.value)
    assert new_lru != prev_lru, \
        f"Expected lru_idx to change after accessing previous LRU entry {prev_lru}, still got {new_lru}"


@cocotb.test()
async def test_rapid_access(dut):
    """Back-to-back accesses on consecutive cycles."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Rapidly access entries 3, 7, 1, 15
    for idx in [3, 7, 1, 15]:
        dut.access_valid.value = 1
        dut.access_idx.value = idx
        await RisingEdge(dut.clk)
    dut.access_valid.value = 0
    await RisingEdge(dut.clk)

    # LRU should NOT be any of the recently accessed entries
    lru = int(dut.lru_idx.value)
    assert lru not in [3, 7, 1, 15], \
        f"LRU index {lru} should not be one of the recently accessed entries [3,7,1,15]"
