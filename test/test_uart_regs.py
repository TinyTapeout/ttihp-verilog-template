# =============================================================================
# ZIRH-2 - cocotb unit test for zirh_uart_regs
#
# Run:  make -C test -f Makefile.uregs
#
# The bus master is modeled directly on the slave ports; the UART line is
# checked against cocotbext-uart. RESET_DIV is overridden to 20.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly, Timer, with_timeout
from cocotbext.uart import UartSource, UartSink

CLK_NS = 40
DIV = 20                      # must match Makefile.uregs override
BAUD = int(1e9 / CLK_NS / DIV)

R_STATUS, R_TXDATA, R_RXDATA, R_BAUD = 0x0, 0x4, 0x8, 0xC


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.cyc_i.value = 0
    dut.adr_i.value = 0
    dut.dat_i.value = 0
    dut.we_i.value = 0
    dut.tlm_data_i.value = 0
    dut.tlm_valid_i.value = 0
    dut.uart_rx_i.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def bus_read(dut, adr):
    await RisingEdge(dut.clk)
    dut.adr_i.value = adr
    dut.we_i.value = 0
    dut.cyc_i.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert dut.ack_o.value == 1, "single-cycle slave must ack immediately"
    val = int(dut.rdt_o.value)
    await RisingEdge(dut.clk)
    dut.cyc_i.value = 0
    return val


async def bus_write(dut, adr, dat):
    await RisingEdge(dut.clk)
    dut.adr_i.value = adr
    dut.dat_i.value = dat
    dut.we_i.value = 1
    dut.cyc_i.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.cyc_i.value = 0
    dut.we_i.value = 0


async def wait_status_bit(dut, bit, value, timeout=40 * DIV):
    for _ in range(timeout):
        s = await bus_read(dut, R_STATUS)
        if (s >> bit) & 1 == value:
            return s
    raise AssertionError(f"STATUS bit {bit} never became {value}")


@cocotb.test()
async def test_reset_state(dut):
    """After reset: SW slot free, nothing received, BAUD at its default."""
    await start(dut)
    s = await bus_read(dut, R_STATUS)
    assert s & 1 == 1, "tx_free must be set after reset"
    assert s & 0xE == 0, "rx_avail and stickies must be clear"
    assert await bus_read(dut, R_BAUD) == DIV, "BAUD must reset to RESET_DIV"


@cocotb.test()
async def test_tx_through_registers(dut):
    """A byte written to TXDATA appears on the line; tx_free handshake works."""
    await start(dut)
    sink = UartSink(dut.uart_tx_o, baud=BAUD, bits=8)

    await bus_write(dut, R_TXDATA, 0xA5)
    got = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
    assert got == 0xA5, f"line carried {got:#04x}"
    await wait_status_bit(dut, 0, 1)  # slot frees up again


@cocotb.test()
async def test_rx_through_registers(dut):
    """A byte on the line raises rx_avail; reading RXDATA returns and clears it."""
    await start(dut)
    source = UartSource(dut.uart_rx_i, baud=BAUD, bits=8)

    await source.write([0x3C])
    await wait_status_bit(dut, 1, 1)
    assert await bus_read(dut, R_RXDATA) == 0x3C
    s = await bus_read(dut, R_STATUS)
    assert (s >> 1) & 1 == 0, "rx_avail must clear after the read"


@cocotb.test()
async def test_overrun_sticky_and_clear(dut):
    """Two bytes without a read: overrun sets; a STATUS write clears it."""
    await start(dut)
    source = UartSource(dut.uart_rx_i, baud=BAUD, bits=8)

    await source.write([0x01, 0x02])
    await ClockCycles(dut.clk, 25 * DIV)  # both frames done
    s = await bus_read(dut, R_STATUS)
    assert (s >> 3) & 1 == 1, "overrun sticky must be set"
    assert await bus_read(dut, R_RXDATA) == 0x02, "buffer holds the newest byte"

    await bus_write(dut, R_STATUS, 0)
    s = await bus_read(dut, R_STATUS)
    assert (s >> 3) & 1 == 0, "STATUS write must clear the sticky"


@cocotb.test()
async def test_baud_register_reprograms_the_link(dut):
    """Write a new divisor, transmit, and decode at the NEW baud rate."""
    await start(dut)
    new_div = 40
    await bus_write(dut, R_BAUD, new_div)
    assert await bus_read(dut, R_BAUD) == new_div

    sink = UartSink(dut.uart_tx_o, baud=int(1e9 / CLK_NS / new_div), bits=8)
    await bus_write(dut, R_TXDATA, 0x96)
    got = (await with_timeout(sink.read(1), 200_000, "ns"))[0]
    assert got == 0x96, f"byte at reprogrammed baud: {got:#04x}"


@cocotb.test()
async def test_telemetry_has_priority(dut):
    """With a telemetry byte pending, the SW byte waits its turn: the line
    carries the tlm byte first, then the SW byte."""
    await start(dut)
    sink = UartSink(dut.uart_tx_o, baud=BAUD, bits=8)

    dut.tlm_data_i.value = 0x5A
    dut.tlm_valid_i.value = 1
    await bus_write(dut, R_TXDATA, 0xC3)
    await ClockCycles(dut.clk, 2)
    # tlm byte accepted; drop valid so the SW byte can follow
    dut.tlm_valid_i.value = 0

    first = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
    second = (await with_timeout(sink.read(1), 200_000, "ns"))[0]
    assert first == 0x5A, f"telemetry must win the line, got {first:#04x}"
    assert second == 0xC3, f"SW byte must follow, got {second:#04x}"


@cocotb.test()
async def test_baud_tmr_upset(dut):
    """Flip one BAUD replica mid-operation: err_o pulses, the divisor heals,
    and the next byte still decodes at the programmed rate."""
    await start(dut)
    sink = UartSink(dut.uart_tx_o, baud=BAUD, bits=8)

    await Timer(10, unit="ns")  # mid-cycle, where a deposit survives
    val = int(dut.u_baud.u_ff_b.q_o.value)
    dut.u_baud.u_ff_b.q_o.setimmediatevalue(val ^ 0x0010)

    saw_err = False
    for _ in range(3):
        await RisingEdge(dut.clk)
        await ReadOnly()
        saw_err |= bool(dut.err_o.value)
    assert saw_err, "err_o must flag the BAUD replica flip"

    await bus_write(dut, R_TXDATA, 0x7E)
    got = (await with_timeout(sink.read(1), 100_000, "ns"))[0]
    assert got == 0x7E, "link must still run at the healed divisor"


@cocotb.test()
async def test_frame_error_sticky(dut):
    """A broken stop bit sets the ferr sticky; a STATUS write clears it."""
    await start(dut)

    value = 0x99
    bits = [0] + [(value >> i) & 1 for i in range(8)] + [0]  # bad stop
    for bit in bits:
        dut.uart_rx_i.value = bit
        await ClockCycles(dut.clk, DIV)
    dut.uart_rx_i.value = 1
    await ClockCycles(dut.clk, 2 * DIV)

    s = await bus_read(dut, R_STATUS)
    assert (s >> 2) & 1 == 1, "ferr sticky must be set"
    await bus_write(dut, R_STATUS, 0)
    s = await bus_read(dut, R_STATUS)
    assert (s >> 2) & 1 == 0, "STATUS write must clear ferr"
