# =============================================================================
# ZIRH — cocotb unit test for zirh_tmr_reg
#
# Run with:  make -C test -f Makefile.tmr
#
# This is also ZIRH's very first fault-injection campaign: we flip bits in
# individual replicas from Python and check that
#   1) the voted output never shows the corruption,
#   2) err_o pulses exactly when a mismatch existed,
#   3) the corrupted replica self-heals on the next clock edge.
# =============================================================================

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer

CLK_PERIOD_NS = 40  # 25 MHz — irrelevant for logic, keeps waveforms readable


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    dut.rst_n.value = 0
    dut.en_i.value = 0
    dut.d_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load(dut, value):
    """Load a value through the normal en/d port."""
    dut.d_i.value = value
    dut.en_i.value = 1
    await RisingEdge(dut.clk)
    dut.en_i.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset_and_load(dut):
    """Basic sanity: reset value, then normal loads propagate to q_o."""
    await start_clock(dut)
    await reset(dut)

    assert dut.q_o.value == 0, "q_o should be RESET_VALUE (0) after reset"
    assert dut.err_o.value == 0, "no error expected after reset"

    for value in [0xA5, 0x00, 0xFF, 0x3C]:
        await load(dut, value)
        assert dut.q_o.value == value, f"q_o={int(dut.q_o.value):#x}, expected {value:#x}"
        assert dut.err_o.value == 0, "no error expected during normal operation"


@cocotb.test()
async def test_single_replica_upset_is_masked(dut):
    """Flip one replica: q_o must stay correct, err_o must pulse, replica must heal."""
    await start_clock(dut)
    await reset(dut)

    await load(dut, 0xA5)

    # --- inject: flip one bit of replica r_b (deposit onto the internal reg)
    corrupted = 0xA5 ^ 0x10
    dut.u_ff_b.q_o.value = corrupted

    # Let combinational logic settle within this cycle
    await ReadOnly()
    assert dut.q_o.value == 0xA5, "voter must mask a single corrupted replica"

    # --- next edge: err_o pulses (mismatch existed), replica self-heals
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.err_o.value == 1, "err_o must pulse after a replica mismatch"
    assert dut.u_ff_b.q_o.value == 0xA5, "corrupted replica must self-heal from voted value"
    assert dut.q_o.value == 0xA5, "q_o must remain correct throughout"

    # --- one more edge: error pulse must clear (it was a single upset)
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.err_o.value == 0, "err_o must be a single-cycle pulse"


@cocotb.test()
async def test_random_injection_campaign(dut):
    """Mini campaign: N random single-replica upsets, zero functional failures."""
    await start_clock(dut)
    await reset(dut)

    random.seed(1907)  # reproducibility
    n_injections = 200
    detected = 0

    for _ in range(n_injections):
        value = random.getrandbits(8)
        await load(dut, value)

        replica = random.choice([dut.u_ff_a.q_o, dut.u_ff_b.q_o, dut.u_ff_c.q_o])
        flip = 1 << random.randrange(8)
        replica.value = value ^ flip

        await ReadOnly()
        assert dut.q_o.value == value, "single upset must never reach q_o"

        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.err_o.value == 1:
            detected += 1
        assert dut.q_o.value == value, "q_o corrupted after clock edge"

        await RisingEdge(dut.clk)

    # Every injection changed one replica, so every one must be detected
    assert detected == n_injections, (
        f"detected {detected}/{n_injections} injected upsets"
    )
    dut._log.info(f"fault injection campaign: {detected}/{n_injections} upsets "
                  f"masked and detected — TMR works")


@cocotb.test()
async def test_double_upset_is_not_masked_silently(dut):
    """Two corrupted replicas defeat majority voting (expected!) — but err_o
    still flags the disagreement. Documents the known limit of TMR."""
    await start_clock(dut)
    await reset(dut)

    await load(dut, 0x0F)

    # Same-bit corruption in TWO replicas → majority is wrong
    bad = 0x0F ^ 0x01
    dut.u_ff_a.q_o.value = bad
    dut.u_ff_b.q_o.value = bad

    await ReadOnly()
    assert dut.q_o.value == bad, "double upset is expected to defeat the voter"

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.err_o.value == 1, "disagreement must still be detected"
