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
UART_TX = 4
ERR_UART = 5
RX_FERR = 6

# the top instantiates zirh_rs422 with the silicon divisor
UART_DIV = 174
UART_BAUD = int(1e9 / CLK_PERIOD_NS / UART_DIV)


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0x08  # ui[3] is the UART RX line: it idles HIGH
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
    """Straight out of reset: UART_TX idles high, everything else low,
    all bidirectional IOs must be inputs."""
    await start_and_reset(dut)
    await ReadOnly()

    expected = 1 << UART_TX  # a UART line at rest is high by definition
    assert int(dut.uo_out.value) == expected, (
        f"uo_out = {int(dut.uo_out.value):#04x}, expected {expected:#04x}")
    assert int(dut.uio_out.value) == 0, "RD_DATA must read 0 (counters cleared)"
    assert int(dut.uio_oe.value) == 0xFF, (
        "uio must turn into the RD_DATA output bus once reset releases")


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


# ui pin map (must match tt_um_hma_zirh.v): [1:0] SEL, [2] SEL_HI,
# [3] UART_RX (idles high), [5:4] MODE, [6] INJ, [7] CLEAR
def _ui(sel=0, hi=0, mode=0, inj=0, clear=0):
    return sel | (hi << 2) | 0x08 | (mode << 4) | (inj << 6) | (clear << 7)


SEU_N = 256  # chain length instantiated in the top
SEU_WARMUP = SEU_N + 4


async def _seu_read(dut, sel, hi):
    dut.ui_in.value = _ui(sel=sel, hi=hi)
    await ClockCycles(dut.clk, 5)  # 2-FF sync + mux settle
    await ReadOnly()
    val = int(dut.uio_out.value)
    await RisingEdge(dut.clk)
    return val


async def _seu_read16(dut, sel):
    lo = await _seu_read(dut, sel, 0)
    hi = await _seu_read(dut, sel, 1)
    return (hi << 8) | lo


async def _seu_pulse(dut, sel, clear=False):
    """Drive INJ (or CLEAR) high for a few cycles - edge detection in the
    top must turn a held pin into exactly one event."""
    dut.ui_in.value = _ui(sel=sel, inj=0 if clear else 1, clear=1 if clear else 0)
    await ClockCycles(dut.clk, 4)
    dut.ui_in.value = _ui(sel=sel)
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_seu_monitor_pins(dut):
    """Full pin-level session with the SEU monitor: signature, one injection
    per counter through the shared INJ pin, then CLEAR. This is exactly the
    bring-up script for the bench, and it runs against the GL netlist too."""
    await start_and_reset(dut)
    await ClockCycles(dut.clk, SEU_WARMUP + 8)  # let the monitor arm

    sig = await _seu_read16(dut, 3)
    assert (sig >> 8) == 0x5A, f"signature ID {sig >> 8:#x}, expected 0x5a"
    assert (sig >> 3) & 1 == 1, "armed bit must be set after warm-up"

    assert await _seu_read16(dut, 0) == 0, "PLAIN must start at 0"
    assert await _seu_read16(dut, 1) == 0, "RAW must start at 0"
    assert await _seu_read16(dut, 2) == 0, "ESCAPE must start at 0"

    # inject into the plain chain (SEL=0): one count after the bit exits
    await _seu_pulse(dut, sel=0)
    await ClockCycles(dut.clk, SEU_N + 8)
    assert await _seu_read16(dut, 0) == 1, "PLAIN must count exactly 1"
    assert await _seu_read16(dut, 1) == 0, "RAW untouched by plain injection"

    # inject into one TMR replica (SEL=1): RAW counts, ESCAPE must not
    await _seu_pulse(dut, sel=1)
    await ClockCycles(dut.clk, 8)
    assert await _seu_read16(dut, 1) == 1, "RAW must count exactly 1"
    assert await _seu_read16(dut, 2) == 0, "voter must mask a single replica"

    # inject into all three replicas (SEL=2): ESCAPE counts, RAW stays
    await _seu_pulse(dut, sel=2)
    await ClockCycles(dut.clk, SEU_N + 8)
    assert await _seu_read16(dut, 2) == 1, "ESCAPE must count exactly 1"
    assert await _seu_read16(dut, 1) == 1, "no replica disagreement on escape"

    # clear wipes everything
    await _seu_pulse(dut, sel=0, clear=True)
    for sel in (0, 1, 2):
        assert await _seu_read16(dut, sel) == 0, f"counter {sel} not cleared"


async def _uart_send(dut, value):
    """Bit-bang one 8N1 frame into ui[3], LSB first, one bit per UART_DIV clocks.

    cocotbext-uart is used at unit level (test_rs422.py); here the frame is
    driven clock-synchronously because a bit-select of the ui_in vector is not
    a signal handle Icarus can hand to UartSource.
    """
    await RisingEdge(dut.clk)  # leave the ReadOnly phase a capture may end in
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [1]
    for bit in bits:
        cur = int(dut.ui_in.value)
        dut.ui_in.value = (cur & ~0x08) | (bit << 3)
        await ClockCycles(dut.clk, UART_DIV)


async def _uart_capture(dut, timeout_cycles=25 * UART_DIV):
    """Recover one 8N1 frame from uo[4]: wait for the start edge, sample at
    mid-bit. Returns the data byte; asserts on a broken stop bit."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if bit(dut, UART_TX) == 0:
            break
    else:
        raise AssertionError("no start bit seen on UART_TX")

    await ClockCycles(dut.clk, UART_DIV // 2)
    samples = []
    for _ in range(9):  # 8 data + stop
        await ClockCycles(dut.clk, UART_DIV)
        await ReadOnly()
        samples.append(bit(dut, UART_TX))
    assert samples[8] == 1, "broken stop bit on UART_TX"
    return sum(b << i for i, b in enumerate(samples[:8]))


@cocotb.test()
async def test_uart_echo(dut):
    """Every byte sent into ui[3] must come back on uo[4]: the hardware echo
    exercises RX, the pending buffer and TX - all four TMR'd counters."""
    await start_and_reset(dut)
    await ClockCycles(dut.clk, 4)

    for value in [0x55, 0x00, 0xFF, 0xA7]:
        await _uart_send(dut, value)
        got = await _uart_capture(dut)
        assert got == value, f"echo returned {got:#04x}, sent {value:#04x}"

    await RisingEdge(dut.clk)
    await ReadOnly()
    assert bit(dut, ERR_UART) == 0, "ERR_UART asserted with no fault injected"
    assert bit(dut, RX_FERR) == 0, "RX_FERR asserted for clean frames"


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
