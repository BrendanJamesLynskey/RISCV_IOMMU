# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles


def pack_fault_record(faulting_addr=0, reserved1=0, device_id=0, cause=0,
                      reserved0=0, is_write=0, is_read=0, valid=0):
    """Pack fault_record_t into a 64-bit integer.

    Layout (MSB to LSB in packed struct):
      faulting_addr[31:0] | reserved1[15:0] | device_id[7:0] | cause[3:0] |
      reserved0[0] | is_write[0] | is_read[0] | valid[0]
    Total: 32 + 16 + 8 + 4 + 1 + 1 + 1 + 1 = 64 bits
    """
    val = 0
    val |= (faulting_addr & 0xFFFFFFFF) << 32
    val |= (reserved1 & 0xFFFF) << 16
    val |= (device_id & 0xFF) << 8
    val |= (cause & 0xF) << 4
    val |= (reserved0 & 0x1) << 3
    val |= (is_write & 0x1) << 2
    val |= (is_read & 0x1) << 1
    val |= (valid & 0x1)
    return val


async def reset_dut(dut):
    dut.srst.value = 1
    dut.fault_valid.value = 0
    dut.fault_record.value = 0
    dut.head_inc.value = 0
    await ClockCycles(dut.clk, 4)
    dut.srst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset_empty(dut):
    """After reset, queue is empty: head=tail=0, no fault_pending, not full."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    assert int(dut.head.value) == 0, f"Expected head=0, got {int(dut.head.value)}"
    assert int(dut.tail.value) == 0, f"Expected tail=0, got {int(dut.tail.value)}"
    assert int(dut.fault_pending.value) == 0, "Expected fault_pending=0 after reset"
    assert int(dut.queue_full.value) == 0, "Expected queue_full=0 after reset"
    assert int(dut.fault_ready.value) == 1, "Expected fault_ready=1 after reset"


@cocotb.test()
async def test_write_and_pending(dut):
    """Write one fault record, verify tail advances and fault_pending asserts."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Write one fault record
    rec = pack_fault_record(faulting_addr=0xDEADBEEF, device_id=0x42,
                            cause=0x3, is_read=1, valid=1)
    dut.fault_valid.value = 1
    dut.fault_record.value = rec
    await RisingEdge(dut.clk)
    dut.fault_valid.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.tail.value) == 1, f"Expected tail=1, got {int(dut.tail.value)}"
    assert int(dut.head.value) == 0, f"Expected head=0, got {int(dut.head.value)}"
    assert int(dut.fault_pending.value) == 1, "Expected fault_pending=1"

    # Advance head -- should clear pending
    dut.head_inc.value = 1
    await RisingEdge(dut.clk)
    dut.head_inc.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.head.value) == 1, f"Expected head=1, got {int(dut.head.value)}"
    assert int(dut.fault_pending.value) == 0, "Expected fault_pending=0 after head increment"


@cocotb.test()
async def test_full_queue(dut):
    """Fill queue to capacity, verify fault_ready deasserts."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    depth = 16  # FAULT_QUEUE_DEPTH

    # Fill queue to capacity (depth - 1 entries makes it full because circular buffer)
    for i in range(depth - 1):
        rec = pack_fault_record(faulting_addr=0x1000 + i, device_id=i,
                                cause=0x1, is_read=1, valid=1)
        dut.fault_valid.value = 1
        dut.fault_record.value = rec
        await RisingEdge(dut.clk)
    dut.fault_valid.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.queue_full.value) == 1, "Expected queue_full=1 after filling"
    assert int(dut.fault_ready.value) == 0, "Expected fault_ready=0 when full"
    assert int(dut.fault_pending.value) == 1, "Expected fault_pending=1"

    # Advance head by 1 -- should free one slot
    dut.head_inc.value = 1
    await RisingEdge(dut.clk)
    dut.head_inc.value = 0
    await RisingEdge(dut.clk)

    assert int(dut.queue_full.value) == 0, "Expected queue_full=0 after head increment"
    assert int(dut.fault_ready.value) == 1, "Expected fault_ready=1 after head increment"


@cocotb.test()
async def test_wraparound(dut):
    """Write and read enough records to wrap around the circular buffer."""
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    depth = 16

    # Write and consume records to wrap around
    for cycle in range(depth + 4):
        # Write a record
        rec = pack_fault_record(faulting_addr=0x2000 + cycle, device_id=cycle & 0xFF,
                                cause=0x1, is_read=1, valid=1)
        dut.fault_valid.value = 1
        dut.fault_record.value = rec
        await RisingEdge(dut.clk)
        dut.fault_valid.value = 0

        # Consume (advance head)
        dut.head_inc.value = 1
        await RisingEdge(dut.clk)
        dut.head_inc.value = 0
        await RisingEdge(dut.clk)

    # After wrap-around, head and tail should have wrapped
    head = int(dut.head.value)
    tail = int(dut.tail.value)
    assert head == tail, f"Expected head==tail (empty queue after consuming all), got head={head}, tail={tail}"
    assert int(dut.fault_pending.value) == 0, "Expected fault_pending=0 after consuming all records"
