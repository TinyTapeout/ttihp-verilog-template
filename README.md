# ZIRH

**Radiation-Tolerant Experiment Chip**

*"Zirh" means "armor" in Turkish.*

> ZIRH-1: a self-reporting SEU measurement instrument on IHP SG13G2 130 nm,
> targeting the Tiny Tapeout TTIHP26b shuttle. Open PDK, open flow, open RTL,
> open verification.

## What is this?

ZIRH-1 measures radiation effects instead of merely surviving them. Matched
protected and unprotected storage sits on the same die, under the same beam,
at the same time; hardened counters track three separately meaningful event
rates; and a telemetry framer streams the results out over UART with no CPU,
no commands and no external prompting. If the chip is alive, it tells you so,
and it tells you what the beam is doing to it.

The scientific target: cross-section data for plain versus TMR-protected
storage on an open 130 nm PDK, with the full design published next to every
measurement.

## Architecture

```
                 tt_um_hma_zirh          1554 FF, 61% of a 4x2 tile
  clk ---> +--------------+
  rst_n--> | zirh_clk_rst |  TMR reset synchronizer, TMR heartbeat, ticks
           +------+-------+
                  | rst_n_sys
   +--------------+--------------------------------------------+
   |                          |                        |       |
+--+-----------+  +-----------+-----------+  +---------+--+    |
| zirh_seu_mon |  | zirh_tlm              |  | zirh_rs422 |    |
| 256b plain   |  | 10-byte frame         |  | UART       |    |
| ring +       |->| every 3.3 ms          |->| 114.9 kBd  |--> UART_TX
| 3x256b TMR   |  | seq, checksum,        |  | TMR timing |<-- UART_RX
| ring, 3 cnt  |  | atomic snapshot       |  | + echo     |    |
+--------------+  +-----------------------+  +------------+    |
      ^  |                                                     |
   INJ/  RD_DATA[7:0], SEU_EVT, live status pins --------------+
   MODE/SEL
```

| Block | Function | Hardening |
|---|---|---|
| `zirh_clk_rst` | Reset synchronizer, heartbeat, tick strobes | Fully TMR (3x 2-FF reset sync, voted; TMR counter) |
| `zirh_seu_mon` | The instrument: matched circulating rings + 3 counters | Targets deliberately unprotected; counters and bookkeeping TMR |
| `zirh_rs422` | UART link (logic-level; RS422 driver on the carrier) | Bit/baud counters TMR; shift registers plain by design |
| `zirh_tlm` | Telemetry framer | Interval and frame state TMR; snapshot plain, checksum-covered |
| `zirh_tmr_lib` | Voter, TMR flop, self-correcting TMR register | The building blocks themselves |

## The experiment

Two circulating shift rings of identical length (N=256) hold the same
pattern (zeros, ones or checkerboard). A flipped bit travels to the ring
exit, is counted once, and leaves; the rings re-arm themselves with no scrub
logic. Three counters, three different physical questions:

| Counter | Counts | Meaning |
|---|---|---|
| PLAIN | Flips in the unprotected ring | Classic SEU cross-section |
| RAW | Any TMR replica disagreement (self-heals in 1 cycle) | Upset rate of protected storage |
| ESCAPE | The voted bit is wrong | TMR defeated: same-bit multiple upset. Expected ~zero; the headline number |

Counters are 16-bit, saturating and TMR'd: beam totals must neither wrap nor
be fabricated by an upset in the instrument itself. Instrument upsets are
flagged (telemetry `infra` bit) and deliberately not counted.

Every error path is verifiable on the ground before beam time: the INJ pin
flips one plain bit, one TMR replica bit, or the same bit in all three
replicas - the last one proves the ESCAPE path, which a real beam may never
exercise.

## Telemetry

Every 2^16 clocks (3.3 ms at 20 MHz, ~300 frames/s) a 10-byte frame goes out
on UART_TX at 114.9 kBd (115200 -0.22%), 8N1:

```
0   0x5A  'Z'
1   0x52  'R'
2   STATUS   {seq[3:0], armed, infra, mode[1:0]}
3-4 PLAIN    16-bit, big-endian
5-6 RAW
7-8 ESCAPE
9   XOR of bytes 0..8
```

The snapshot is atomic (all fields latch in one cycle), `seq` gaps expose
dropped frames, and the checksum makes any corrupted frame visible on the
ground. Between frames the UART echoes received bytes back (best-effort
link check; telemetry has priority on the line).

## Pinout

| Pin | Name | Function |
|---|---|---|
| `ui[1:0]` | SEL | Counter select: 0 plain, 1 raw, 2 escape, 3 signature |
| `ui[2]` | SEL_HI | Byte select for RD_DATA |
| `ui[3]` | UART_RX | Command/echo input, idles high |
| `ui[5:4]` | MODE | Pattern: 00 zeros, 01 ones, 1x checkerboard |
| `ui[6]` | INJ | Rising edge: inject into the target SEL points at |
| `ui[7]` | CLEAR | Rising edge: zero the counters |
| `uo[0]` | HEARTBEAT | ~1.2 Hz; clock+reset+TMR alive |
| `uo[1]` | TICK_DIV16 | Strobe every 16 clocks |
| `uo[2]` | TICK_DIV256 | Strobe every 256 clocks |
| `uo[3]` | ERR_HB | Heartbeat counter replica mismatch |
| `uo[4]` | UART_TX | Telemetry + echo |
| `uo[5]` | ERR_UART | UART counter replica mismatch |
| `uo[6]` | RX_FERR | Broken RX frame |
| `uo[7]` | SEU_EVT | One pulse per monitor event (scope the beam live) |
| `uio[7:0]` | RD_DATA | Selected counter byte; output after reset |

Bring-up needs nothing but a serial adapter: check HEARTBEAT, read the
signature word (SEL=3 returns ID byte 0x5A plus armed/mode), fire one
injection per counter, watch telemetry report exactly +1 each time.

## Measured on the hardened design

Numbers below are from the LibreLane flow on the actual GDS, not estimates:

| Metric | Value |
|---|---|
| Flip-flops (post-P&R netlist) | 1554, matching RTL bit for bit |
| Core utilization | 61% of a 4x2 tile |
| Worst setup slack | +11.4 ns against the 50 MHz constraint (fmax ~116 MHz; nominal operation 20 MHz) |
| Hold slack / TNS | +0.11 ns / 0 |
| DRC (route + Magic), LVS, antenna | 0 / 0 / 0 |
| TT precheck (incl. KLayout SG13G2 DRC) | 10/10 pass |
| Gate-level test | full integration suite passes on the post-synthesis netlist, telemetry frame included |

## Verification

Six cocotb suites, every block fault-injected, plus a synthesis integrity
check. Simulation passing is not enough for TMR: the optimizer merges
identical replicas, and the netlist still simulates correctly with the
hardening silently gone. Measured on this RTL: stripping the
`keep_hierarchy` attributes collapses `zirh_clk_rst` from 79 to 26 flops.
`scripts/check_tmr.sh` synthesises every block and the top and verifies the
replica and flop counts that actually survive - and it fails correctly on
RTL with the attributes stripped (verified both ways).

```sh
pip install -r test/requirements.txt
make -C test                    # integration via the TT harness (7 tests)
make -C test -f Makefile.tmr    # TMR register: 200-shot injection campaign
make -C test -f Makefile.clk    # clock/reset
make -C test -f Makefile.rs422  # UART, checked against cocotbext-uart
make -C test -f Makefile.seu    # SEU monitor: all counters, all inject paths
make -C test -f Makefile.tlm    # telemetry framer
bash scripts/check_tmr.sh       # hardening survives synthesis (6 checks)
```

The integration suite drives nothing but the TT pins, so CI runs the same
tests against the gate-level netlist on every push.

## Design philosophy

- **Protect the control, expose the data.** Control state that can kill a
  block permanently (counters, FSMs, reset) is TMR'd; data that costs one
  byte or one frame (shift registers, snapshots) is plain, with corruption
  made visible downstream (checksum, frame errors). Applied uniformly in
  every block.
- **The chip is its own test bench.** Every error-handling path is
  exercisable from the pins, on the ground, before beam time is spent.
- **Frequency is a hardening parameter.** Timing closes at 50 MHz; the chip
  runs at 20. The margin is SET immunity and post-TID headroom.
- **Verification-first.** If a hardening structure is not verified after
  synthesis, it does not exist.

## Repository structure

```
zirh/
  info.yaml              Tiny Tapeout manifest (sources, pinout)
  src/                   RTL: tmr_lib, clk_rst, rs422, seu_mon, tlm, top
  test/                  cocotb suites + per-block makefiles
  scripts/check_tmr.sh   synthesis integrity check
  host/zirh_ground.py    ground station: telemetry decoder (serial/file/selftest)
  docs/info.md           datasheet
```

The ground station decodes the mixed telemetry+echo stream, validates
checksums, tracks sequence gaps and counter deltas, and logs CSV for beam
campaigns. `python3 host/zirh_ground.py --selftest` runs it against a
hostile synthetic stream with no hardware.

## Status

| Milestone | State |
|---|---|
| TMR library + fault-injection tests | done |
| Clock/reset, UART, SEU monitor, telemetry | done, RTL + GL verified |
| Hardened GDS, DRC/LVS clean, TT precheck | done |
| Tapeout (TTIHP26b shuttle) | pending submission |
| Silicon bring-up | waiting for silicon |
| Irradiation campaign (Co-60 TID), beam data published here | planned |

## Roadmap: ZIRH-2

ZIRH-1 fills its tile (61% utilization; the area went to the instrument, as
it should). Everything below moves to the second platform:

- SERV RISC-V core (TMR) + mask ROM firmware, bus, ECC RAM
- CAN 2.0A and SpaceWire-lite links, int8 NPU as an unprotected datapath target
- Foundry SRAM macros as an MBU cross-section target
- Placement-aware TMR: ZIRH-1's replicas are placed by the tool with no
  separation constraint, so a single particle can defeat the voter -
  ZIRH-1's ESCAPE counter measures exactly how often; ZIRH-2 constrains it
- FPGA twin (iCE40/ECP5) for hardware fault injection

## External hardware

None required: all pins are logic-level, and bring-up works with any 3.3 V
serial adapter. A carrier board with an RS422 driver/receiver (e.g. MAX490)
makes the UART link electrically flight-representative.

## Acknowledgments

Standing on the shoulders of: [Tiny Tapeout](https://tinytapeout.com)
(Matt Venn and team), the [IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK)
(IHP Microelectronics), [TMRG](https://tmrg.web.cern.ch) (CERN),
[SERV](https://github.com/olofk/serv) (Olof Kindgren, planned for ZIRH-2)
and the open-silicon community.

## License

Apache-2.0 (see `LICENSE`).

---

*ZIRH-1 is a research and characterization vehicle, not flight-qualified
hardware. It is the chip you build so that one day you know how to build
that one.*
