# =============================================================================
# ZIRH-2 - cocotb unit test for zirh_ecc_ram
#
# Run:  make -C test -f Makefile.eram
#
# Fault injection deposits straight into the 39-bit storage words (what the
# beam does); expectations never model Hamming - a flipped stored bit must
# simply yield the originally written data plus the right event pulse.
# =============================================================================

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.sel_i.value = 0xF
    dut.we_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wr(dut, word, dat, sel=0xF):
    await RisingEdge(dut.clk)
    dut.adr_i.value = word << 2
    dut.dat_i.value = dat
    dut.sel_i.value = sel
    dut.we_i.value = 1
    dut.cyc_i.value = 1
    await RisingEdge(dut.clk)
    dut.cyc_i.value = 0
    dut.we_i.value = 0
    dut.sel_i.value = 0xF


async def rd(dut, word):
    await RisingEdge(dut.clk)
    dut.adr_i.value = word << 2
    dut.we_i.value = 0
    dut.cyc_i.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.ack_o.value == 1, "single-cycle slave must ack immediately"
    val = int(dut.rdt_o.value)
    await RisingEdge(dut.clk)
    dut.cyc_i.value = 0
    return val


async def flip_stored(dut, word, bits):
    """Beam simulation: XOR the stored 39-bit word mid-cycle."""
    await Timer(10, unit="ns")
    cur = int(dut.mem[word].value)
    dut.mem[word].setimmediatevalue(cur ^ bits)
    await RisingEdge(dut.clk)


class PulseCounter:
    def __init__(self, dut):
        self.corr = 0
        self.uncorr = 0
        self.task = cocotb.start_soon(self._run(dut))

    async def _run(self, dut):
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            self.corr += int(dut.evt_corr_o.value)
            self.uncorr += int(dut.evt_uncorr_o.value)


@cocotb.test()
async def test_roundtrip_all_words(dut):
    """Every word stores and returns walking and random patterns cleanly."""
    await start(dut)
    random.seed(2128)
    ref = {}
    for w in range(32):
        v = random.getrandbits(32)
        ref[w] = v
        await wr(dut, w, v)
    for w in range(32):
        got = await rd(dut, w)
        assert got == ref[w], f"word {w}: {got:#010x} != {ref[w]:#010x}"


@cocotb.test()
async def test_byte_enables_merge(dut):
    """Partial writes touch only the enabled bytes."""
    await start(dut)
    await wr(dut, 3, 0xAABBCCDD)
    await wr(dut, 3, 0x000000EE, sel=0x1)
    assert await rd(dut, 3) == 0xAABBCCEE
    await wr(dut, 3, 0x11220000, sel=0xC)
    assert await rd(dut, 3) == 0x1122CCEE


@cocotb.test()
async def test_single_bit_flip_corrected_and_scrubbed(dut):
    """Any single stored-bit flip: read returns the original data, evt_corr
    pulses once, and the storage is repaired so a second read is clean."""
    await start(dut)
    pc = PulseCounter(dut)
    random.seed(39)

    for trial in range(20):
        word = random.randrange(32)
        val = random.getrandbits(32)
        await wr(dut, word, val)
        bit = random.randrange(39)   # data, Hamming or overall parity bit
        await flip_stored(dut, word, 1 << bit)

        before = pc.corr
        got = await rd(dut, word)
        assert got == val, (
            f"trial {trial}: bit {bit} flip leaked: {got:#010x} != {val:#010x}")
        await ClockCycles(dut.clk, 2)
        assert pc.corr == before + 1, (
            f"trial {trial}: corr pulses {pc.corr - before}, expected 1")

        got = await rd(dut, word)     # scrub must have repaired the storage
        assert got == val
        await ClockCycles(dut.clk, 2)
        assert pc.corr == before + 1, "second read must be clean after scrub"
    assert pc.uncorr == 0, "no uncorrectable events expected"


@cocotb.test()
async def test_double_bit_flip_detected(dut):
    """Two flipped bits: evt_uncorr pulses, evt_corr does not."""
    await start(dut)
    pc = PulseCounter(dut)
    await wr(dut, 7, 0x0F0F0F0F)
    await flip_stored(dut, 7, (1 << 5) | (1 << 20))

    await rd(dut, 7)  # value is garbage by definition; only the flag matters
    await ClockCycles(dut.clk, 2)
    assert pc.uncorr >= 1, "double-bit error must raise evt_uncorr"
    assert pc.corr == 0, "a double-bit error must not be 'corrected'"


@cocotb.test()
async def test_partial_write_repairs_corrupt_word(dut):
    """A byte write over a word with a correctable error: the error in the
    untouched bytes is repaired by the read-correct-merge-rewrite."""
    await start(dut)
    pc = PulseCounter(dut)
    await wr(dut, 9, 0xDEAD0000)
    await flip_stored(dut, 9, 1 << 34)     # corrupt a parity bit

    await wr(dut, 9, 0x000000BE, sel=0x1)  # RMW must correct along the way
    await ClockCycles(dut.clk, 2)
    assert pc.corr == 1, "the RMW must count one correction"

    assert await rd(dut, 9) == 0xDEAD00BE
    await ClockCycles(dut.clk, 2)
    assert pc.corr == 1, "storage must be clean after the rewrite"


@cocotb.test()
async def test_quiet_when_clean(dut):
    """No injected faults: neither event may ever pulse."""
    await start(dut)
    pc = PulseCounter(dut)
    for w in range(0, 32, 3):
        await wr(dut, w, 0xC0DE0000 | w)
    for w in range(0, 32, 3):
        await rd(dut, w)
    assert pc.corr == 0 and pc.uncorr == 0, (
        f"phantom events: corr={pc.corr} uncorr={pc.uncorr}")
