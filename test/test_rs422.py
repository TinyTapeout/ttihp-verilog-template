# =============================================================================
# ZIRH - cocotb unit test for zirh_rs422
#
# Run:  make -C test -f Makefile.rs422
#
# The UART sides are driven by cocotbext-uart (UartSource feeds uart_rx_i,
# UartSink captures uart_tx_o), so the DUT is checked against an independent
# implementation of the protocol, not against itself. The loopback test then
# wires TX to RX through the testbench.
#
# DIV is overridden to 20 in Makefile.rs422: at the 25 MHz testbench clock
# that is 1.25 MBd, keeping each frame to 200 clock cycles.
# =============================================================================

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, with_timeout
from cocotbext.uart import UartSource, UartSink

CLK_PERIOD_NS = 40   # 25 MHz
DIV = 20             # driven onto div_i at reset
BAUD = int(1e9 / CLK_PERIOD_NS / DIV)

FRAME_CYCLES = 10 * DIV  # start + 8 data + stop


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())
    dut.div_i.value = DIV
    dut.rst_n.value = 0
    dut.tx_data_i.value = 0
    dut.tx_valid_i.value = 0
    dut.uart_rx_i.value = 1  # idle line
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def send_byte(dut, value):
    """Push one byte into the TX ready/valid interface."""
    dut.tx_data_i.value = value
    dut.tx_valid_i.value = 1
    await RisingEdge(dut.clk)
    while dut.tx_ready_o.value == 0:  # handshake happened if ready was high
        await RisingEdge(dut.clk)
        break
    dut.tx_valid_i.value = 0


async def wait_tx_idle(dut, timeout_cycles=3 * FRAME_CYCLES):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.tx_ready_o.value == 1:
            return
    raise AssertionError("TX never returned to ready")


async def recv_byte(dut, timeout_cycles=3 * FRAME_CYCLES):
    """Wait for one rx_valid pulse, return the received byte."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.rx_valid_o.value == 1:
            return int(dut.rx_data_o.value)
    raise AssertionError("rx_valid_o never pulsed")


@cocotb.test()
async def test_tx_against_reference_sink(dut):
    """Bytes sent through TX must arrive intact at an independent UART sink."""
    await start(dut)
    sink = UartSink(dut.uart_tx_o, baud=BAUD, bits=8)

    payload = [0x55, 0x00, 0xFF, 0xA7, 0x13]
    for b in payload:
        await send_byte(dut, b)
        await wait_tx_idle(dut)

    for b in payload:
        got = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
        assert got == b, f"sink captured {got:#04x}, sent {b:#04x}"


@cocotb.test()
async def test_rx_against_reference_source(dut):
    """Bytes from an independent UART source must arrive on the RX interface."""
    await start(dut)
    source = UartSource(dut.uart_rx_i, baud=BAUD, bits=8)

    payload = [0x81, 0x7E, 0x00, 0xFF, 0x3C]
    for b in payload:
        await source.write([b])
        got = await recv_byte(dut)
        assert got == b, f"rx_data_o = {got:#04x}, expected {b:#04x}"
        assert dut.rx_frame_err_o.value == 0, "no frame error expected"


@cocotb.test()
async def test_loopback(dut):
    """TX wired to RX in the testbench: every byte must come back identical."""
    await start(dut)

    random.seed(422)
    forward = cocotb.start_soon(_forward_tx_to_rx(dut))
    try:
        for _ in range(20):
            b = random.getrandbits(8)
            await send_byte(dut, b)
            got = await recv_byte(dut)
            assert got == b, f"loopback returned {got:#04x}, sent {b:#04x}"
            await wait_tx_idle(dut)
    finally:
        forward.kill()


async def _forward_tx_to_rx(dut):
    while True:
        await RisingEdge(dut.clk)
        dut.uart_rx_i.value = int(dut.uart_tx_o.value)


async def _count_pulses(dut, flags):
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        flags["ferr"] += int(dut.rx_frame_err_o.value)
        flags["valid"] += int(dut.rx_valid_o.value)


@cocotb.test()
async def test_frame_error_on_bad_stop_bit(dut):
    """A frame whose stop bit is low must pulse rx_frame_err_o, not rx_valid_o."""
    await start(dut)

    # The rx_frame_err_o pulse lands while the stop bit is still being driven,
    # so the watcher must already be running when the frame goes out.
    flags = {"ferr": 0, "valid": 0}
    watcher = cocotb.start_soon(_count_pulses(dut, flags))

    # bit-bang a frame with stop=0 (cocotbext-uart cannot send a broken one)
    value = 0xC3
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [0]  # start, data, BAD stop
    for bit in bits:
        dut.uart_rx_i.value = bit
        await ClockCycles(dut.clk, DIV)
    dut.uart_rx_i.value = 1

    await ClockCycles(dut.clk, DIV)
    watcher.kill()
    assert flags["valid"] == 0, "rx_valid_o must not pulse on a broken frame"
    assert flags["ferr"] == 1, f"expected exactly one ferr pulse, got {flags['ferr']}"


@cocotb.test()
async def test_glitch_on_idle_line_is_ignored(dut):
    """A sub-bit low glitch must not produce a byte or a frame error."""
    await start(dut)

    dut.uart_rx_i.value = 0
    await ClockCycles(dut.clk, DIV // 4)  # much shorter than half a bit
    dut.uart_rx_i.value = 1

    for _ in range(2 * FRAME_CYCLES):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert dut.rx_valid_o.value == 0, "glitch produced a byte"
        assert dut.rx_frame_err_o.value == 0, "glitch produced a frame error"


@cocotb.test()
async def test_tmr_upset_mid_frame_does_not_corrupt_link(dut):
    """Flip a TX bit-counter replica mid-frame: the byte in flight must still
    arrive intact, err_o must pulse, and the link must keep working."""
    await start(dut)
    sink = UartSink(dut.uart_tx_o, baud=BAUD, bits=8)

    await send_byte(dut, 0x5A)
    await ClockCycles(dut.clk, 3 * DIV)  # somewhere inside data bits

    val = int(dut.u_tx_cnt.u_ff_b.q_o.value)
    dut.u_tx_cnt.u_ff_b.q_o.value = val ^ 0x4

    saw_err = False
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.err_o.value == 1:
            saw_err = True
    assert saw_err, "err_o must pulse after a TMR replica flip"

    got = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
    assert got == 0x5A, f"byte in flight corrupted: {got:#04x}"

    # link must still be alive afterwards
    await wait_tx_idle(dut)
    await send_byte(dut, 0xE1)
    got = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
    assert got == 0xE1, f"link broken after upset: {got:#04x}"


@cocotb.test()
async def test_err_quiet_in_normal_operation(dut):
    """err_o must never pulse when nothing is injected."""
    await start(dut)
    source = UartSource(dut.uart_rx_i, baud=BAUD, bits=8)

    await source.write([0xAA])
    await send_byte(dut, 0x99)
    for cycle in range(3 * FRAME_CYCLES):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert dut.err_o.value == 0, f"err_o pulsed at cycle {cycle} with no fault"
