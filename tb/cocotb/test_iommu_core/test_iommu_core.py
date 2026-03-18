# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.txn_valid.value = 0
    dut.txn_device_id.value = 0
    dut.txn_vaddr.value = 0
    dut.txn_is_read.value = 0
    dut.txn_is_write.value = 0
    dut.iommu_enable.value = 0
    dut.dct_base_ppn.value = 0
    dut.mem_rd_req_ready.value = 1
    dut.mem_rd_resp_valid.value = 0
    dut.mem_rd_data.value = 0
    dut.mem_rd_error.value = 0
    dut.fault_ready.value = 1
    dut.iotlb_inv_valid.value = 0
    dut.iotlb_inv_device_id.value = 0
    dut.iotlb_inv_all.value = 0
    dut.dc_inv_valid.value = 0
    dut.dc_inv_device_id.value = 0
    dut.dc_inv_all.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


async def mem_responder(dut, mem):
    """Background coroutine: responds to memory read requests from the core."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.mem_rd_req_valid.value) == 1 and int(dut.mem_rd_req_ready.value) == 1:
            addr = int(dut.mem_rd_addr.value)
            word_addr = (addr >> 2) & 0xFFFFFFFF
            if word_addr in mem:
                data = mem[word_addr]
                error = 0
            else:
                data = 0
                error = 1
            await RisingEdge(dut.clk)
            dut.mem_rd_resp_valid.value = 1
            dut.mem_rd_data.value = data
            dut.mem_rd_error.value = error
            await RisingEdge(dut.clk)
            dut.mem_rd_resp_valid.value = 0
            dut.mem_rd_error.value = 0


def build_device_context(en, rp, wp, fp, mode, pt_root_ppn):
    """Build a 64-bit device_context_t value.
    Format: {reserved_w1[31:0], pt_root_ppn[21:0], rsv[1:0], mode[3:0], fp, wp, rp, en}
    """
    word0 = ((pt_root_ppn & 0x3FFFFF) << 10) | ((mode & 0xF) << 4) | \
            ((fp & 1) << 3) | ((wp & 1) << 2) | ((rp & 1) << 1) | (en & 1)
    word1 = 0  # reserved
    return word0, word1


def setup_sv32_memory(mem, dct_base_ppn, device_id, dc_word0, dc_word1,
                      pt_root_ppn, vpn1, vpn0, leaf_ppn,
                      leaf_r=1, leaf_w=1, use_superpage=False):
    """Set up device context and page tables in memory dict."""
    # Device context: 2 words at dct_base + device_id * 8
    dc_base_word = (dct_base_ppn << 10)  # byte addr >> 2 = ppn << 12 >> 2 = ppn << 10
    mem[dc_base_word + device_id * 2] = dc_word0
    mem[dc_base_word + device_id * 2 + 1] = dc_word1

    if use_superpage:
        # L1 PTE: leaf superpage
        # ppn0 must be 0 for aligned superpage
        pte_ppn = leaf_ppn
        l1_pte = (pte_ppn << 10)
        if leaf_r:
            l1_pte |= 0x2  # R
        if leaf_w:
            l1_pte |= 0x4  # W
        l1_pte |= 0x1  # V
        l1_word_addr = (pt_root_ppn << 10) + vpn1
        mem[l1_word_addr] = l1_pte
    else:
        # L1 PTE: non-leaf pointer to L0 table
        l0_table_ppn = pt_root_ppn + 1  # arbitrary L0 table location
        l1_pte = (l0_table_ppn << 10) | 0x1  # V=1, non-leaf
        l1_word_addr = (pt_root_ppn << 10) + vpn1
        mem[l1_word_addr] = l1_pte

        # L0 PTE: leaf
        l0_pte = (leaf_ppn << 10)
        if leaf_r:
            l0_pte |= 0x2  # R
        if leaf_w:
            l0_pte |= 0x4  # W
        l0_pte |= 0x1  # V
        l0_word_addr = (l0_table_ppn << 10) + vpn0
        mem[l0_word_addr] = l0_pte


async def submit_txn(dut, device_id, vaddr, is_read, is_write):
    """Submit a transaction and wait for acceptance."""
    dut.txn_valid.value = 1
    dut.txn_device_id.value = device_id
    dut.txn_vaddr.value = vaddr
    dut.txn_is_read.value = is_read
    dut.txn_is_write.value = is_write
    await RisingEdge(dut.clk)
    while int(dut.txn_ready.value) != 1:
        await RisingEdge(dut.clk)
    dut.txn_valid.value = 0


async def wait_txn_done(dut, timeout=200):
    """Wait for txn_done."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.txn_done.value) == 1:
            return
    raise TimeoutError("txn_done not asserted within timeout")


@cocotb.test()
async def test_bypass(dut):
    """IOMMU disabled: address passes through unchanged."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    dut.iommu_enable.value = 0
    vaddr = 0xABCD1234
    await submit_txn(dut, device_id=1, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)

    paddr = int(dut.txn_paddr.value)
    assert paddr == vaddr, f"Expected paddr={vaddr:#x}, got {paddr:#x}"
    assert int(dut.txn_fault.value) == 0, "Expected no fault in bypass"


@cocotb.test()
async def test_sv32_translation(dut):
    """Full Sv32 translation: DC fetch -> PTW -> translate."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    pt_root_ppn = 0x20
    device_id = 1
    leaf_ppn = 0x300

    # vaddr = {vpn1[9:0], vpn0[9:0], offset[11:0]}
    vpn1 = 5
    vpn0 = 3
    offset = 0x100
    vaddr = (vpn1 << 22) | (vpn0 << 12) | offset

    dc_word0, dc_word1 = build_device_context(
        en=1, rp=1, wp=1, fp=0, mode=1, pt_root_ppn=pt_root_ppn)
    setup_sv32_memory(mem, dct_base_ppn, device_id, dc_word0, dc_word1,
                      pt_root_ppn, vpn1, vpn0, leaf_ppn)

    dut.iommu_enable.value = 1
    dut.dct_base_ppn.value = dct_base_ppn
    cocotb.start_soon(mem_responder(dut, mem))

    await submit_txn(dut, device_id=device_id, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)

    expected_paddr = (leaf_ppn << 12) | offset
    paddr = int(dut.txn_paddr.value)
    assert int(dut.txn_fault.value) == 0, "Expected no fault"
    assert paddr == expected_paddr, \
        f"Expected paddr={expected_paddr:#x}, got {paddr:#x}"


@cocotb.test()
async def test_iotlb_hit_after_miss(dut):
    """Second access to same page should hit in IOTLB (no new PTW)."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    pt_root_ppn = 0x20
    device_id = 2
    leaf_ppn = 0x400

    vpn1 = 1
    vpn0 = 2
    offset1 = 0x010
    offset2 = 0x020
    vaddr1 = (vpn1 << 22) | (vpn0 << 12) | offset1
    vaddr2 = (vpn1 << 22) | (vpn0 << 12) | offset2

    dc_word0, dc_word1 = build_device_context(
        en=1, rp=1, wp=1, fp=0, mode=1, pt_root_ppn=pt_root_ppn)
    setup_sv32_memory(mem, dct_base_ppn, device_id, dc_word0, dc_word1,
                      pt_root_ppn, vpn1, vpn0, leaf_ppn)

    dut.iommu_enable.value = 1
    dut.dct_base_ppn.value = dct_base_ppn
    cocotb.start_soon(mem_responder(dut, mem))

    # First access (miss -> PTW)
    await submit_txn(dut, device_id=device_id, vaddr=vaddr1, is_read=1, is_write=0)
    await wait_txn_done(dut)
    paddr1 = int(dut.txn_paddr.value)
    assert int(dut.txn_fault.value) == 0, "Expected no fault on first access"

    await ClockCycles(dut.clk, 2)

    # Second access (should hit IOTLB)
    await submit_txn(dut, device_id=device_id, vaddr=vaddr2, is_read=1, is_write=0)
    await wait_txn_done(dut)
    paddr2 = int(dut.txn_paddr.value)
    expected2 = (leaf_ppn << 12) | offset2
    assert int(dut.txn_fault.value) == 0, "Expected no fault on second access"
    assert paddr2 == expected2, \
        f"Expected paddr={expected2:#x}, got {paddr2:#x}"


@cocotb.test()
async def test_superpage(dut):
    """Superpage translation via L1 leaf."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    pt_root_ppn = 0x20
    device_id = 3

    vpn1 = 7
    vpn0 = 9
    offset = 0x044
    vaddr = (vpn1 << 22) | (vpn0 << 12) | offset

    # Superpage: leaf_ppn ppn0 must be 0
    leaf_ppn1 = 0x50
    leaf_ppn = (leaf_ppn1 << 10) | 0  # ppn0 = 0

    dc_word0, dc_word1 = build_device_context(
        en=1, rp=1, wp=1, fp=0, mode=1, pt_root_ppn=pt_root_ppn)
    setup_sv32_memory(mem, dct_base_ppn, device_id, dc_word0, dc_word1,
                      pt_root_ppn, vpn1, vpn0, leaf_ppn,
                      use_superpage=True)

    dut.iommu_enable.value = 1
    dut.dct_base_ppn.value = dct_base_ppn
    cocotb.start_soon(mem_responder(dut, mem))

    await submit_txn(dut, device_id=device_id, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)

    # Superpage: paddr = {ppn[21:10], vaddr[21:0]}
    expected_paddr = (leaf_ppn1 << 22) | (vaddr & 0x3FFFFF)
    paddr = int(dut.txn_paddr.value)
    assert int(dut.txn_fault.value) == 0, "Expected no fault"
    assert paddr == expected_paddr, \
        f"Expected paddr={expected_paddr:#x}, got {paddr:#x}"


@cocotb.test()
async def test_device_isolation(dut):
    """Two devices with different page tables produce different translations."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10

    # Device 1: pt_root=0x20, maps vpn1=1,vpn0=0 -> ppn=0x500
    pt_root1 = 0x20
    leaf_ppn1 = 0x500
    dc1_w0, dc1_w1 = build_device_context(en=1, rp=1, wp=1, fp=0, mode=1,
                                           pt_root_ppn=pt_root1)
    setup_sv32_memory(mem, dct_base_ppn, 1, dc1_w0, dc1_w1,
                      pt_root1, 1, 0, leaf_ppn1)

    # Device 2: pt_root=0x30, maps vpn1=1,vpn0=0 -> ppn=0x600
    pt_root2 = 0x30
    leaf_ppn2 = 0x600
    dc2_w0, dc2_w1 = build_device_context(en=1, rp=1, wp=1, fp=0, mode=1,
                                           pt_root_ppn=pt_root2)
    setup_sv32_memory(mem, dct_base_ppn, 2, dc2_w0, dc2_w1,
                      pt_root2, 1, 0, leaf_ppn2)

    dut.iommu_enable.value = 1
    dut.dct_base_ppn.value = dct_base_ppn
    cocotb.start_soon(mem_responder(dut, mem))

    offset = 0x000
    vaddr = (1 << 22) | (0 << 12) | offset

    # Device 1 translation
    await submit_txn(dut, device_id=1, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)
    paddr1 = int(dut.txn_paddr.value)
    assert int(dut.txn_fault.value) == 0
    assert paddr1 == (leaf_ppn1 << 12) | offset, \
        f"Device 1: expected {(leaf_ppn1 << 12) | offset:#x}, got {paddr1:#x}"

    await ClockCycles(dut.clk, 2)

    # Device 2 translation
    await submit_txn(dut, device_id=2, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)
    paddr2 = int(dut.txn_paddr.value)
    assert int(dut.txn_fault.value) == 0
    assert paddr2 == (leaf_ppn2 << 12) | offset, \
        f"Device 2: expected {(leaf_ppn2 << 12) | offset:#x}, got {paddr2:#x}"

    assert paddr1 != paddr2, "Device isolation: addresses should differ"


@cocotb.test()
async def test_fault_recording(dut):
    """Context with EN=0 should produce a fault record."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    mem = {}
    dct_base_ppn = 0x10
    device_id = 5

    # Device context with EN=0
    dc_word0, dc_word1 = build_device_context(en=0, rp=0, wp=0, fp=0, mode=0,
                                               pt_root_ppn=0)
    dc_base_word = (dct_base_ppn << 10)
    mem[dc_base_word + device_id * 2] = dc_word0
    mem[dc_base_word + device_id * 2 + 1] = dc_word1

    dut.iommu_enable.value = 1
    dut.dct_base_ppn.value = dct_base_ppn
    cocotb.start_soon(mem_responder(dut, mem))

    vaddr = 0x1000
    await submit_txn(dut, device_id=device_id, vaddr=vaddr, is_read=1, is_write=0)
    await wait_txn_done(dut)

    assert int(dut.txn_fault.value) == 1, "Expected fault for disabled context"
    assert int(dut.txn_fault_cause.value) == 0x5, \
        f"Expected CAUSE_CTX_INVALID (0x5), got {int(dut.txn_fault_cause.value):#x}"
