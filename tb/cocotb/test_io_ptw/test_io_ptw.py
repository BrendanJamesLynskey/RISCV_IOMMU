# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.walk_req_valid.value = 0
    dut.walk_device_id.value = 0
    dut.walk_vpn1.value = 0
    dut.walk_vpn0.value = 0
    dut.walk_pt_root_ppn.value = 0
    dut.walk_is_read.value = 0
    dut.walk_is_write.value = 0
    dut.mem_rd_req_ready.value = 1
    dut.mem_rd_resp_valid.value = 0
    dut.mem_rd_data.value = 0
    dut.mem_rd_error.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


async def mem_responder(dut, mem):
    """Background coroutine that watches for memory read requests and responds."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.mem_rd_req_valid.value) == 1 and int(dut.mem_rd_req_ready.value) == 1:
            addr = int(dut.mem_rd_addr.value)
            word_addr = (addr >> 2) & 0xFFFFFFFF
            data = mem.get(word_addr, 0)
            error = 1 if word_addr not in mem else 0
            # Respond next cycle
            await RisingEdge(dut.clk)
            dut.mem_rd_resp_valid.value = 1
            dut.mem_rd_data.value = data
            dut.mem_rd_error.value = error
            await RisingEdge(dut.clk)
            dut.mem_rd_resp_valid.value = 0
            dut.mem_rd_error.value = 0


async def start_walk(dut, device_id, vpn1, vpn0, root_ppn, is_read, is_write):
    """Issue a walk request and wait for it to be accepted."""
    dut.walk_req_valid.value = 1
    dut.walk_device_id.value = device_id
    dut.walk_vpn1.value = vpn1
    dut.walk_vpn0.value = vpn0
    dut.walk_pt_root_ppn.value = root_ppn
    dut.walk_is_read.value = is_read
    dut.walk_is_write.value = is_write
    await RisingEdge(dut.clk)
    while int(dut.walk_req_ready.value) != 1:
        await RisingEdge(dut.clk)
    dut.walk_req_valid.value = 0


async def wait_walk_done(dut, timeout=100):
    """Wait for walk_done to be asserted."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.walk_done.value) == 1:
            return
    raise TimeoutError("walk_done not asserted within timeout")


@cocotb.test()
async def test_two_level_walk(dut):
    """Successful full two-level Sv32 page table walk."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    # Page table layout:
    # root_ppn = 0x100 -> L1 table at phys addr 0x100_000
    # vpn1 = 5 -> L1 PTE at addr 0x100_000 + 5*4 = 0x100_014
    # L1 PTE = non-leaf pointer to L0 table at ppn 0x200 -> phys addr 0x200_000
    # vpn0 = 3 -> L0 PTE at addr 0x200_000 + 3*4 = 0x200_00C
    # L0 PTE = leaf with ppn=0x300, R=1, W=1, X=0, V=1

    root_ppn = 0x100
    vpn1 = 5
    vpn0 = 3
    l0_ppn = 0x200
    leaf_ppn = 0x300

    # L1 PTE: non-leaf (V=1, R=0, W=0, X=0), PPN = l0_ppn
    # PTE format: {ppn1[11:0], ppn0[9:0], rsw[1:0], D, A, G, U, X, W, R, V}
    # ppn1 = l0_ppn >> 10 = 0, ppn0 = l0_ppn & 0x3FF = 0x200
    l1_pte = (l0_ppn << 10) | 0x1  # V=1, rest=0 (non-leaf)

    # L0 PTE: leaf (V=1, R=1, W=1, X=0), PPN = leaf_ppn
    l0_pte = (leaf_ppn << 10) | 0x7  # V=1, R=1, W=1

    mem = {}
    # L1 PTE address: (root_ppn << 12) + vpn1 * 4 = 0x100000 + 0x14 = 0x100014
    l1_word_addr = (root_ppn << 10) + vpn1  # word address = byte_addr >> 2
    mem[l1_word_addr] = l1_pte

    # L0 PTE address: (l0_ppn << 12) + vpn0 * 4 = 0x200000 + 0xC = 0x20000C
    l0_word_addr = (l0_ppn << 10) + vpn0
    mem[l0_word_addr] = l0_pte

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    await start_walk(dut, device_id=1, vpn1=vpn1, vpn0=vpn0,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 0, "Expected no fault"
    assert int(dut.walk_ppn.value) == leaf_ppn, \
        f"Expected PPN={leaf_ppn:#x}, got {int(dut.walk_ppn.value):#x}"
    assert int(dut.walk_perm_r.value) == 1, "Expected perm_r=1"
    assert int(dut.walk_perm_w.value) == 1, "Expected perm_w=1"
    assert int(dut.walk_is_superpage.value) == 0, "Expected not superpage"


@cocotb.test()
async def test_superpage(dut):
    """L1 leaf (superpage) with aligned PPN."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    root_ppn = 0x100
    vpn1 = 2

    # L1 PTE: leaf with ppn1=0x50, ppn0=0 (aligned), R=1, W=0, X=1, V=1
    # ppn = {ppn1, ppn0} = {0x50, 0x000} = 0x14000
    leaf_ppn1 = 0x50
    leaf_ppn = (leaf_ppn1 << 10) | 0  # ppn0 must be 0 for superpage
    l1_pte = (leaf_ppn << 10) | 0xB  # V=1, R=1, X=1, W=0

    mem = {}
    l1_word_addr = (root_ppn << 10) + vpn1
    mem[l1_word_addr] = l1_pte

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    await start_walk(dut, device_id=0, vpn1=vpn1, vpn0=7,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 0, "Expected no fault for superpage"
    assert int(dut.walk_ppn.value) == leaf_ppn, \
        f"Expected PPN={leaf_ppn:#x}, got {int(dut.walk_ppn.value):#x}"
    assert int(dut.walk_is_superpage.value) == 1, "Expected superpage"
    assert int(dut.walk_perm_r.value) == 1, "Expected perm_r=1"


@cocotb.test()
async def test_l1_invalid(dut):
    """L1 PTE with V=0 should cause PTE_INVALID fault."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    root_ppn = 0x100
    vpn1 = 0

    # L1 PTE: V=0 (invalid)
    l1_pte = 0x0

    mem = {}
    l1_word_addr = (root_ppn << 10) + vpn1
    mem[l1_word_addr] = l1_pte

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    await start_walk(dut, device_id=0, vpn1=vpn1, vpn0=0,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 1, "Expected fault"
    assert int(dut.walk_fault_cause.value) == 0x1, \
        f"Expected CAUSE_PTE_INVALID (0x1), got {int(dut.walk_fault_cause.value):#x}"


@cocotb.test()
async def test_l0_invalid(dut):
    """L0 PTE with V=0 should cause PTE_INVALID fault."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    root_ppn = 0x100
    vpn1 = 1
    vpn0 = 2
    l0_ppn = 0x200

    # L1 PTE: non-leaf pointer
    l1_pte = (l0_ppn << 10) | 0x1  # V=1

    # L0 PTE: invalid (V=0)
    l0_pte = 0x0

    mem = {}
    l1_word_addr = (root_ppn << 10) + vpn1
    mem[l1_word_addr] = l1_pte
    l0_word_addr = (l0_ppn << 10) + vpn0
    mem[l0_word_addr] = l0_pte

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    await start_walk(dut, device_id=0, vpn1=vpn1, vpn0=vpn0,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 1, "Expected fault"
    assert int(dut.walk_fault_cause.value) == 0x1, \
        f"Expected CAUSE_PTE_INVALID (0x1), got {int(dut.walk_fault_cause.value):#x}"


@cocotb.test()
async def test_permission_denied(dut):
    """Read permission denied at L0 leaf."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    root_ppn = 0x100
    vpn1 = 3
    vpn0 = 4
    l0_ppn = 0x200
    leaf_ppn = 0x400

    # L1 PTE: non-leaf
    l1_pte = (l0_ppn << 10) | 0x1

    # L0 PTE: leaf with W=1, R=0 is invalid encoding (W && !R)
    # Instead: leaf with R=0, W=1 -> CAUSE_PTE_INVALID (W=1,R=0 invalid)
    # For CAUSE_READ_DENIED: leaf with R=0, W=0, X=1, V=1
    l0_pte = (leaf_ppn << 10) | 0x9  # V=1, X=1, R=0, W=0

    mem = {}
    l1_word_addr = (root_ppn << 10) + vpn1
    mem[l1_word_addr] = l1_pte
    l0_word_addr = (l0_ppn << 10) + vpn0
    mem[l0_word_addr] = l0_pte

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    # Read to a page with R=0
    await start_walk(dut, device_id=0, vpn1=vpn1, vpn0=vpn0,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 1, "Expected fault for read denied"
    assert int(dut.walk_fault_cause.value) == 0x3, \
        f"Expected CAUSE_READ_DENIED (0x3), got {int(dut.walk_fault_cause.value):#x}"


@cocotb.test()
async def test_memory_error(dut):
    """Memory error during walk causes PTW_ACCESS_FAULT."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())

    root_ppn = 0x100
    vpn1 = 0

    # Empty memory dict -> responder will return error
    mem = {}

    await reset_dut(dut)
    cocotb.start_soon(mem_responder(dut, mem))

    await start_walk(dut, device_id=0, vpn1=vpn1, vpn0=0,
                     root_ppn=root_ppn, is_read=1, is_write=0)
    await wait_walk_done(dut)

    assert int(dut.walk_fault.value) == 1, "Expected fault"
    assert int(dut.walk_fault_cause.value) == 0x8, \
        f"Expected CAUSE_PTW_ACCESS_FAULT (0x8), got {int(dut.walk_fault_cause.value):#x}"
