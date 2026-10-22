import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CLKS_PER_BIT = 87
START = 0b0000_1000          # uio_in[3] = input pin 11


def tx(dut):    return int(dut.uo_out.value) & 1
def ready(dut): return (int(dut.uo_out.value) >> 1) & 1


async def reset(dut):
    try:
        clk = Clock(dut.clk, 100, unit="ns")     # cocotb 2.x
    except TypeError:
        clk = Clock(dut.clk, 100, units="ns")    # cocotb 1.x
    cocotb.start_soon(clk.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 3)


async def wait_for(dut, cond, limit=2000):
    for _ in range(limit):
        if cond():
            return
        await ClockCycles(dut.clk, 1)
    assert False, "timed out"


async def send(dut, byte):
    dut.ui_in.value = byte
    dut.uio_in.value = START                     # pulse start for one clock
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0


@cocotb.test()
async def idles_high(dut):
    """After reset the firmware runs and leaves TX and READY high."""
    await reset(dut)
    await ClockCycles(dut.clk, 20)
    assert tx(dut) == 1 and ready(dut) == 1


@cocotb.test()
async def exact_bit_timing(dut):
    """Every bit of the frame lasts exactly 87 clocks."""
    await reset(dut)
    for byte in [0x55, 0x00, 0xFF, 0x01, 0x80, 0xA5]:
        await send(dut, byte)
        await wait_for(dut, lambda: tx(dut) == 0)          # start bit begins
        samples = [tx(dut)]
        for _ in range(10 * CLKS_PER_BIT - 1):
            await ClockCycles(dut.clk, 1)
            samples.append(tx(dut))
        expect = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
        for k, bit in enumerate(expect):
            chunk = samples[k * CLKS_PER_BIT:(k + 1) * CLKS_PER_BIT]
            assert chunk == [bit] * CLKS_PER_BIT, f"0x{byte:02X} bit {k} wrong"
        await wait_for(dut, lambda: ready(dut) == 1)


@cocotb.test()
async def ready_marks_the_frame(dut):
    """READY is low for the whole frame and returns high at its end."""
    await reset(dut)
    await send(dut, 0x42)
    await wait_for(dut, lambda: ready(dut) == 0)
    n = 0
    while not ready(dut):
        await ClockCycles(dut.clk, 1)
        n += 1
    assert abs(n - 10 * CLKS_PER_BIT) <= 2, f"frame took {n} clocks"
