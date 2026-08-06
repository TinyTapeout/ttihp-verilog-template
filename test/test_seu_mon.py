# =============================================================================
# ZIRH - cocotb unit test for zirh_seu_mon
#
# Run:  make -C test -f Makefile.seu
#
# N is overridden to 16 in Makefile.seu so warm-up is 20 cycles and a bit
# crosses the ring in 16. Injections use both the ports (as firmware will)
# and direct deposits into the replica registers (as the beam will).
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly

N = 16          # must match Makefile.seu override
WARMUP = N + 4

SEL_PLAIN = 0
SEL_RAW = 1
SEL_ESCAPE = 2
SEL_SIG = 3

MODE_ZEROS = 0
MODE_ONES = 1
MODE_CHECKER = 2


async def start(dut, mode=MODE_ZEROS):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.mode_i.value = mode
    dut.clear_i.value = 0
    dut.inj_plain_i.value = 0
    dut.inj_tmr_i.value = 0
    dut.inj_escape_i.value = 0
    dut.sel_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, WARMUP + 4)  # come out armed


async def read_counter(dut, sel):
    await RisingEdge(dut.clk)  # leave the ReadOnly phase a prior read ended in
    dut.sel_i.value = sel
    await RisingEdge(dut.clk)
    await ReadOnly()
    return int(dut.rd_data_o.value)


async def counters(dut):
    return [await read_counter(dut, s) for s in (SEL_PLAIN, SEL_RAW, SEL_ESCAPE)]


async def pulse(dut, signal):
    await RisingEdge(dut.clk)
    signal.value = 1
    await RisingEdge(dut.clk)
    signal.value = 0


@cocotb.test()
async def test_quiet_after_warmup_all_modes(dut):
    """No injections: every counter must stay at zero in every pattern mode."""
    for mode in (MODE_ZEROS, MODE_ONES, MODE_CHECKER):
        await start(dut, mode)
        await ClockCycles(dut.clk, 4 * N)
        assert await counters(dut) == [0, 0, 0], f"phantom counts in mode {mode}"
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert dut.err_infra_o.value == 0, "err_infra_o pulsed with no fault"
        await RisingEdge(dut.clk)  # leave ReadOnly before the next start()


@cocotb.test()
async def test_signature_word(dut):
    """sel=3 must return the ID byte, armed flag and current mode."""
    await start(dut, MODE_CHECKER)
    sig = await read_counter(dut, SEL_SIG)
    assert (sig >> 8) == 0x5A, f"ID byte {sig >> 8:#x}, expected 0x5a"
    assert (sig >> 3) & 1 == 1, "armed bit must be set after warm-up"
    assert sig & 3 == MODE_CHECKER, "mode bits wrong in signature"


@cocotb.test()
async def test_plain_injection_port(dut):
    """inj_plain_i: exactly one PLAIN count, others untouched, then quiet."""
    await start(dut, MODE_CHECKER)
    await pulse(dut, dut.inj_plain_i)
    await ClockCycles(dut.clk, 2 * N)  # flip travels to the exit and leaves
    assert await counters(dut) == [1, 0, 0], "expected exactly one PLAIN count"
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [1, 0, 0], "count must not repeat - ring re-arms"


@cocotb.test()
async def test_tmr_injection_port(dut):
    """inj_tmr_i: one RAW count, no ESCAPE - the voter must mask it."""
    await start(dut, MODE_ONES)
    await pulse(dut, dut.inj_tmr_i)
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [0, 1, 0], (
        "single-replica upset: RAW must count once, ESCAPE must stay 0")


@cocotb.test()
async def test_escape_injection_port(dut):
    """inj_escape_i: all three replicas agree on the wrong bit - one ESCAPE
    count, and RAW must NOT count (there is no disagreement to see)."""
    await start(dut, MODE_ZEROS)
    await pulse(dut, dut.inj_escape_i)
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [0, 0, 1], (
        "triple upset: ESCAPE must count once, RAW must stay 0")


@cocotb.test()
async def test_beam_deposit_on_plain_chain(dut):
    """Deposit straight into the plain flops (what the beam does): one count
    per flipped bit, each counted as it exits the ring."""
    await start(dut, MODE_ZEROS)
    val = int(dut.plain_q.value)
    dut.plain_q.value = val ^ 0b0110  # two bits flipped by one 'particle'
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [2, 0, 0], "two flipped bits = two counts"


@cocotb.test()
async def test_beam_deposit_on_tmr_replica(dut):
    """Deposit into one replica register: RAW counts once (voted feedback
    heals it next edge), voted stream never wrong."""
    await start(dut, MODE_CHECKER)
    val = int(dut.u_ch_b.q_o.value)
    dut.u_ch_b.q_o.value = val ^ (1 << 5)
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [0, 1, 0], "replica flip: RAW once, no ESCAPE"


@cocotb.test()
async def test_event_pulses(dut):
    """evt_raw_o must pulse for exactly one cycle on a replica flip."""
    await start(dut, MODE_ZEROS)
    val = int(dut.u_ch_a.q_o.value)
    dut.u_ch_a.q_o.value = val ^ (1 << 3)

    pulses = 0
    for _ in range(2 * N):
        await RisingEdge(dut.clk)
        await ReadOnly()
        pulses += int(dut.evt_raw_o.value)
    assert pulses == 1, f"evt_raw_o pulsed {pulses} cycles, expected 1"


@cocotb.test()
async def test_clear(dut):
    """clear_i must zero all three counters."""
    await start(dut, MODE_ZEROS)
    await pulse(dut, dut.inj_plain_i)
    await pulse(dut, dut.inj_tmr_i)
    await pulse(dut, dut.inj_escape_i)
    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [1, 1, 1], "setup: one count in each"

    await pulse(dut, dut.clear_i)
    assert await counters(dut) == [0, 0, 0], "clear_i must zero every counter"


@cocotb.test()
async def test_mode_change_rearms_warmup(dut):
    """Switching patterns must suppress counting until the ring refills -
    otherwise every mode change would fabricate up to N events."""
    await start(dut, MODE_ZEROS)
    dut.mode_i.value = MODE_ONES     # ring full of zeros, expecting ones
    await ClockCycles(dut.clk, WARMUP + N + 4)
    assert await counters(dut) == [0, 0, 0], (
        "mode change fabricated counts - warm-up did not re-arm")


@cocotb.test()
async def test_counter_saturates(dut):
    """A counter at max must stick, not wrap - beam totals must be trustable."""
    await start(dut, MODE_ZEROS)
    # preload all three replicas of the plain counter to MAX-1
    for ff in (dut.u_cnt_plain.u_ff_a, dut.u_cnt_plain.u_ff_b,
               dut.u_cnt_plain.u_ff_c):
        ff.q_o.value = 0xFFFE
    await pulse(dut, dut.inj_plain_i)
    await ClockCycles(dut.clk, 2 * N)
    assert await read_counter(dut, SEL_PLAIN) == 0xFFFF, "must reach MAX"

    await pulse(dut, dut.inj_plain_i)
    await ClockCycles(dut.clk, 2 * N)
    assert await read_counter(dut, SEL_PLAIN) == 0xFFFF, "must saturate, not wrap"


@cocotb.test()
async def test_infra_upset_flags_but_does_not_count(dut):
    """Flip a counter replica: err_infra_o pulses, the counter value heals,
    and no measurement counter moves - the instrument must not poison its
    own data."""
    await start(dut, MODE_ZEROS)
    val = int(dut.u_cnt_raw.u_ff_c.q_o.value)
    dut.u_cnt_raw.u_ff_c.q_o.value = val ^ 0x10

    saw_infra = False
    for _ in range(4):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_infra |= bool(dut.err_infra_o.value)
    assert saw_infra, "err_infra_o must flag an instrument upset"

    await ClockCycles(dut.clk, 2 * N)
    assert await counters(dut) == [0, 0, 0], (
        "instrument upset must not appear in the measurement")
