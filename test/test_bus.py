# =============================================================================
# ZIRH-2 - cocotb unit test for zirh_bus
#
# Run:  make -C test -f Makefile.bus
#
# Python models the slaves directly on the flattened slave-side vectors:
# slot 1 acks in 1 cycle, slot 2 in 3 cycles, slot 5 never (timeout path).
# TIMEOUT_LOG2 is overridden to 4 (deadline 16 clocks) to keep sims short.
# =============================================================================

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles, Timer

TIMEOUT = 16  # 2^4, must match Makefile.bus override
ERR_RDT = 0xDEADBEEF


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.m_adr_i.value = 0
    dut.m_dat_i.value = 0
    dut.m_sel_i.value = 0xF
    dut.m_we_i.value = 0
    dut.m_cyc_i.value = 0
    dut.s_rdt_i.value = 0
    dut.s_ack_i.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


class BusSlaves:
    """Single owner of the flattened slave-side vectors. Every registered
    slot acks after its latency and serves its read value; concurrent
    coroutines doing read-modify-write on the same vector would race and
    overwrite each other's deposits (measured: they do)."""

    def __init__(self, dut):
        self.dut = dut
        self.slots = {}   # slot -> {"latency": n, "rdt": v, "writes": []}
        self._wait = {}
        self._ack = 0
        cocotb.start_soon(self._run())

    def add(self, slot, latency, rdt):
        self.slots[slot] = {"latency": latency, "rdt": rdt, "writes": []}
        self._wait[slot] = 0
        return self.slots[slot]

    async def _run(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            cyc_v = int(d.s_cyc_o.value)
            rdt_v = 0
            new_ack = 0
            for slot, s in self.slots.items():
                rdt_v |= s["rdt"] << (slot * 32)
                cyc = (cyc_v >> slot) & 1
                acked = (self._ack >> slot) & 1
                if cyc and not acked:
                    self._wait[slot] += 1
                    if self._wait[slot] >= s["latency"]:
                        if int(d.s_we_o.value):
                            s["writes"].append(
                                (int(d.s_adr_o.value), int(d.s_dat_o.value)))
                        new_ack |= 1 << slot
                elif not cyc:
                    self._wait[slot] = 0
            self._ack = new_ack
            d.s_ack_i.value = new_ack
            d.s_rdt_i.value = rdt_v


async def xact(dut, adr, we=0, dat=0, timeout=4 * TIMEOUT):
    """One master transaction; returns (rdt, cycles_to_ack)."""
    await RisingEdge(dut.clk)
    dut.m_adr_i.value = adr
    dut.m_dat_i.value = dat
    dut.m_we_i.value = we
    dut.m_cyc_i.value = 1
    for n in range(timeout):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.m_ack_o.value == 1:
            rdt = int(dut.m_rdt_o.value)
            await RisingEdge(dut.clk)
            dut.m_cyc_i.value = 0
            return rdt, n
    raise AssertionError("master saw no ack at all - bus wedged")


@cocotb.test()
async def test_routing_and_latency(dut):
    """Reads route to the addressed slot and tolerate slave latency."""
    await start(dut)
    bus = BusSlaves(dut)
    bus.add(1, latency=1, rdt=0x11111111)
    bus.add(2, latency=3, rdt=0x22222222)

    rdt, n = await xact(dut, 0x0000_1000)
    assert rdt == 0x11111111, f"slot1 rdt {rdt:#x}"
    rdt, n = await xact(dut, 0x0000_2FF0)
    assert rdt == 0x22222222, f"slot2 rdt {rdt:#x}"
    assert n >= 2, "slot2 must take its 3-cycle latency"


@cocotb.test()
async def test_write_reaches_only_selected_slave(dut):
    """A write lands in the addressed slave and nowhere else."""
    await start(dut)
    bus = BusSlaves(dut)
    s1 = bus.add(1, latency=1, rdt=0)
    s2 = bus.add(2, latency=1, rdt=0)

    await xact(dut, 0x0000_1004, we=1, dat=0xCAFE0001)
    await xact(dut, 0x0000_2008, we=1, dat=0xCAFE0002)

    assert s1["writes"] == [(0x1004, 0xCAFE0001)], f"s1 {s1['writes']}"
    assert s2["writes"] == [(0x2008, 0xCAFE0002)], f"s2 {s2['writes']}"


@cocotb.test()
async def test_cyc_is_exclusive(dut):
    """During a transaction only the addressed slot may see cyc."""
    await start(dut)
    BusSlaves(dut).add(2, latency=3, rdt=0)

    async def watch():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            v = int(dut.s_cyc_o.value)
            assert v & ~(1 << 2) == 0, f"spurious cyc: {v:#04x}"

    w = cocotb.start_soon(watch())
    await xact(dut, 0x0000_2000)
    w.kill()


@cocotb.test()
async def test_unpopulated_slot_times_out(dut):
    """No slave in slot 5: the watchdog completes the transaction with
    ERR_RDT and pulses evt_timeout_o - the CPU is never wedged."""
    await start(dut)

    pulses = 0

    async def count():
        nonlocal pulses
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            pulses += int(dut.evt_timeout_o.value)

    c = cocotb.start_soon(count())
    rdt, n = await xact(dut, 0x0000_5000)
    c.kill()

    assert rdt == ERR_RDT, f"timeout rdt {rdt:#010x}, expected DEADBEEF"
    assert n >= TIMEOUT - 2, f"fired after only {n} cycles"
    assert pulses == 1, f"evt_timeout_o pulsed {pulses}x, expected once"


@cocotb.test()
async def test_bus_alive_after_timeout(dut):
    """The transaction after a timeout must complete normally."""
    await start(dut)
    BusSlaves(dut).add(1, latency=1, rdt=0x5A5A5A5A)

    await xact(dut, 0x0000_5000)          # times out
    rdt, _ = await xact(dut, 0x0000_1000)  # must work
    assert rdt == 0x5A5A5A5A, "bus did not recover after a timeout"


@cocotb.test()
async def test_watchdog_tmr_upset(dut):
    """Flip a watchdog replica mid-transaction: err_o pulses, the count is
    healed by the voter, and no spurious timeout fires."""
    await start(dut)
    BusSlaves(dut).add(2, latency=6, rdt=0x33333333)

    saw_err = False
    spurious = False

    async def watch():
        nonlocal saw_err, spurious
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            saw_err |= bool(dut.err_o.value)
            spurious |= bool(dut.evt_timeout_o.value)

    w = cocotb.start_soon(watch())
    await RisingEdge(dut.clk)
    dut.m_adr_i.value = 0x0000_2000
    dut.m_cyc_i.value = 1
    await ClockCycles(dut.clk, 2)
    # Two measured pitfalls in this injection:
    #  - a deposit made in the edge-callback window is overwritten by the
    #    counting flop's own next-timestep update and simply vanishes, so
    #    inject MID-CYCLE (Timer) where nothing else drives the register;
    #  - XOR 0x3 of a counter value can collide with its natural increment
    #    (1^3 == 2), making the flip a no-op - use the MSB instead.
    await Timer(10, unit="ns")
    val = int(dut.u_wd.u_ff_b.q_o.value)
    dut.u_wd.u_ff_b.q_o.setimmediatevalue(val ^ 0x8)

    rdt = None
    for _ in range(3 * TIMEOUT):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if dut.m_ack_o.value == 1:
            rdt = int(dut.m_rdt_o.value)
            break
    await RisingEdge(dut.clk)
    dut.m_cyc_i.value = 0
    w.kill()

    assert rdt == 0x33333333, f"transaction corrupted: {rdt}"
    assert saw_err, "err_o must flag the replica flip"
    assert not spurious, "healed watchdog must not fire a false timeout"
