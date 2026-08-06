# =============================================================================
# ZIRH — cocotb unit test for zirh_clk_rst
# Run:  make -C test -f Makefile.clk
# HB_BIT is overridden to 5 in Makefile.clk so the heartbeat is observable
# in a short simulation (toggle every 2^5 = 32 cycles).
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

HB_BIT = 5  # must match Makefile.clk override


async def start(dut, hold_reset_cycles=4):
    cocotb.start_soon(Clock(dut.clk, 40, units="ns").start())
    dut.rst_n_pad.value = 0
    for _ in range(hold_reset_cycles):
        await RisingEdge(dut.clk)
    dut.rst_n_pad.value = 1


@cocotb.test()
async def test_reset_release_is_synchronous(dut):
    """rst_n_o must assert while pad reset held, release within a few clocks."""
    await start(dut)

    # within 3 cycles of pad release, voted reset must deassert
    released = False
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.rst_n_o.value == 1:
            released = True
            break
    assert released, "rst_n_o did not release within 3 cycles of pad deassert"


@cocotb.test()
async def test_sync_replica_upset_is_masked(dut):
    """Corrupt one reset-synchronizer replica: voted reset must not glitch."""
    await start(dut)
    for _ in range(4):
        await RisingEdge(dut.clk)

    # flip one replica's output stage — this is a SET on the reset tree
    dut.u_rs_b.rst_n_sync.value = 0

    await ReadOnly()
    assert dut.rst_n_o.value == 1, "single replica upset must not reset the chip!"

    # replica reloads from the (deasserted) pad next edge — self-clears
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.rst_n_o.value == 1


@cocotb.test()
async def test_heartbeat_toggles_at_expected_period(dut):
    """heartbeat_o must toggle every 2^HB_BIT cycles."""
    await start(dut)
    await RisingEdge(dut.clk)

    # wait for first toggle, then measure the next full half-period
    prev = dut.heartbeat_o.value
    while dut.heartbeat_o.value == prev:
        await RisingEdge(dut.clk)
    count = 0
    prev = dut.heartbeat_o.value
    while dut.heartbeat_o.value == prev:
        await RisingEdge(dut.clk)
        count += 1
    assert count == 2 ** HB_BIT, f"half-period {count}, expected {2**HB_BIT}"


@cocotb.test()
async def test_tick_strobes(dut):
    """tick_div16 must pulse exactly once every 16 cycles."""
    await start(dut)
    for _ in range(2):
        await RisingEdge(dut.clk)

    pulses = 0
    for _ in range(64):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.tick_div16_o.value == 1:
            pulses += 1
    assert pulses == 4, f"expected 4 tick_div16 pulses in 64 cycles, got {pulses}"


@cocotb.test()
async def test_counter_upset_flags_err(dut):
    """A flip in the heartbeat counter must pulse err_hb_o and self-heal."""
    await start(dut)
    for _ in range(4):
        await RisingEdge(dut.clk)

    # corrupt one replica of the TMR'd counter (bit 2 of replica A)
    val = int(dut.u_cnt.u_ff_a.q_o.value)
    dut.u_cnt.u_ff_a.q_o.value = val ^ 0x4

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.err_hb_o.value == 1, "counter replica mismatch must raise err_hb_o"

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.err_hb_o.value == 0, "err_hb_o must clear after self-heal"
