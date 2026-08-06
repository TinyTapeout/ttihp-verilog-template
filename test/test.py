# =============================================================================
# ZIRH - integration test for tt_um_hma_zirh through the Tiny Tapeout harness
#
# Run:  make -C test
#
# This drives the design exactly as the TT harness will: only ui_in/uio_in,
# clk, rst_n and ena, observing only the output pins. No hierarchy is reached
# into - the block-level tests in test_clk_rst.py and test_tmr.py do that.
#
# SPDX-License-Identifier: Apache-2.0
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

CLK_PERIOD_NS = 50  # 20 MHz, the nominal clock in info.yaml

# uo_out bit assignment, must match tt_um_hma_zirh.v
HEARTBEAT = 0
TICK16 = 1
TICK256 = 2
ERR_HB = 3


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    # the voted reset is synchronized by a 2-FF chain, so it needs two more
    # clocks after the pad deasserts before the counter starts
    await ClockCycles(dut.clk, 3)


def bit(dut, index):
    return (int(dut.uo_out.value) >> index) & 1


@cocotb.test()
async def test_reset_state(dut):
    """Straight out of reset every output must be low and the IOs must be inputs."""
    await start_and_reset(dut)
    await ReadOnly()

    assert int(dut.uo_out.value) == 0, f"uo_out = {int(dut.uo_out.value):#04x}, expected 0x00"
    assert int(dut.uio_out.value) == 0, "uio_out must be driven low while unused"
    assert int(dut.uio_oe.value) == 0, "all bidirectional pins must stay inputs"


@cocotb.test()
async def test_tick_strobes(dut):
    """TICK16 and TICK256 must strobe at their nominal rates.

    1024 is a multiple of both periods, so the counts are independent of which
    phase the counter happens to be in when we start looking.
    """
    await start_and_reset(dut)

    n16 = 0
    n256 = 0
    for _ in range(1024):
        await RisingEdge(dut.clk)
        await ReadOnly()
        n16 += bit(dut, TICK16)
        n256 += bit(dut, TICK256)

    assert n16 == 64, f"TICK16 pulsed {n16} times in 1024 clocks, expected 64"
    assert n256 == 4, f"TICK256 pulsed {n256} times in 1024 clocks, expected 4"


@cocotb.test()
async def test_no_seu_error_in_clean_operation(dut):
    """ERR_HB must stay low: with no upset injected the replicas never disagree."""
    await start_and_reset(dut)

    for cycle in range(1024):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert bit(dut, ERR_HB) == 0, f"ERR_HB asserted at cycle {cycle} with no fault injected"


@cocotb.test()
async def test_heartbeat_is_not_stuck(dut):
    """HEARTBEAT is counter bit 23, so it stays low for the first 2^23 clocks.

    Simulating 8.4M clocks here would be wasteful - the toggle period itself is
    checked in test_clk_rst.py with HB_BIT lowered to 5. What this catches is a
    heartbeat wired to the wrong bit or stuck high.
    """
    await start_and_reset(dut)

    for cycle in range(4096):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert bit(dut, HEARTBEAT) == 0, f"HEARTBEAT high at cycle {cycle}, too early for bit 23"
