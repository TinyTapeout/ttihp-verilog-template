# ZIRH-2 scope draft

Status: draft for discussion. Nothing here is committed until ZIRH-1
silicon data exists; the decision gates below say which parts wait for it.

## Mission shift

ZIRH-1 answers a storage question: what are the SEU rates of plain versus
TMR flip-flops on this PDK, and how often is TMR defeated. ZIRH-2 answers a
system question: **does a hardened computing element keep executing under
beam, and which of its protections actually earn their area.** The chip
runs firmware continuously and its telemetry proves, frame by frame, that
it is still running it correctly.

## The headline experiment: placement A/B

ZIRH-1's known gap is that TMR replicas are placed with no separation
constraint, so one particle can defeat the voter; its ESCAPE counter
measures how often. ZIRH-2 turns that gap into the experiment:

- Chain A: TMR ring, placement-constrained (replicas forcibly separated)
- Chain B: identical TMR ring, tool-placed (the ZIRH-1 situation)
- Same die, same beam: ESCAPE(A) versus ESCAPE(B) is a direct measurement
  of what placement separation buys, in one number

This is the single highest-value addition and it reuses zirh_seu_mon
almost unchanged. It is also the riskiest flow work (see risks).

## Area reality

Numbers that gate everything (measured on ZIRH-1, not estimated):

- 4x2 tile, 60% target density: ~156k um2 usable; ZIRH-1 uses 158k (61%)
- One sg13g2 flop: ~49 um2. TMR bit: ~3.3x a plain bit after voter
- Rule burned into this project: combinational cost of TMR (voters,
  comparison trees) roughly doubles flop-only estimates. Estimate nothing;
  synthesize early and measure

Consequence: **ZIRH-2 targets an 8x2 tile** (2x the area, ~312k um2
usable at 60%). Even so, a DFF-based RAM is a trap: 256 bytes of
DFF RAM is ~2048 flops = ~100k um2 before ECC - a third of the whole
budget. RAM sizing is therefore a P0 design decision, not a detail.

## Block list

P0 - the chip does not tape out without these:

| Block | Notes |
|---|---|
| zirh_bus | Single-master, read/write strobe + ready; no burst, no arbitration. Smallest thing SERV can talk through |
| SERV core (TMR state) | Bit-serial RV32I. Small enough that full TMR on its state is affordable; vendor copy in src/, pinned commit |
| Mask ROM + fw/ | Synthesized-constant ROM. Firmware: housekeeping loop that reads the monitor, computes a liveness signature, writes telemetry fields. riscv-none-elf-gcc + ROM generator script |
| ECC RAM | Hamming SECDED (32+7). Size set by measurement, likely 64-128 bytes. Correctable/uncorrectable counters exported to telemetry |
| zirh_seu_mon v2 | The placement A/B pair above; N per chain sized to remaining area |
| zirh_rs422 + command path | RX becomes a real command port (baud divisor register, counter clear, mode select via bus); TX keeps telemetry priority |
| zirh_tlm v2 | Versioned frame (spare STATUS encoding or a length byte). New fields: CPU liveness signature, ECC corrected/uncorrected, per-chain ESCAPE. Ground station extends, stays backward compatible with ZIRH-1 frames |

P1 - included if area and schedule allow, in this order:

| Block | Notes |
|---|---|
| SRAM DUT | Foundry SRAM macro + pattern-scan FSM, MBU address logging. GATED on an open question: sg13g2 SRAM macro availability in the TT flow - investigate before designing anything |
| zirh_can | CAN 2.0A, TMR on protocol FSM. Needs 2 pins |

P2 - explicitly out unless P0+P1 land early and small:

- SpaceWire-lite, NPU. Both were ZIRH-1 promises once; they are the first
  cut for the same reason they were cut then.

## Flow work (not RTL, but on the critical path)

1. **Placement constraints for TMR replicas.** The A/B experiment needs a
   way to pin or fence replica instances in OpenROAD/LibreLane. Candidate
   mechanisms (all unproven in the TT flow): instance-level place blockages,
   hardening replicas as macros, or post-placement move scripts. Prototype
   on ZIRH-1's netlist FIRST, before any ZIRH-2 RTL - if no mechanism
   works, the headline experiment collapses and the scope reshapes.
2. check_tmr.sh extended per block, as in ZIRH-1 (positive + negative).
3. FPGA twin from day one - SERV firmware development against the twin,
   not against simulation only.
4. GL gating in CI unchanged.

## Decision gates

| Gate | Blocks waiting on it |
|---|---|
| ZIRH-1 silicon ESCAPE data | Final priority of placement A/B; chain sizing |
| SRAM macro availability in TT/IHP flow | SRAM DUT exists or not |
| Placement-constraint prototype on ZIRH-1 netlist | The A/B experiment; possibly the whole ZIRH-2 shape |
| Shuttle calendar (next IHP shuttle) | Everything; scope cuts follow the date |

## Risks, named

- **Area estimates.** ZIRH-1's utilization estimate was off by 5x until
  synthesis said otherwise. Every P0 block gets synthesized standalone and
  measured before integration; the budget table lives in this file and is
  updated with measured numbers only.
- **ROM size.** Synthesized-constant ROM area grows linearly with firmware
  size; the housekeeping loop must fit in ~1 KB or the ROM eats the RAM
  budget. Firmware size is a hardware constraint here.
- **SERV integration depth.** SERV is external IP; TMR-wrapping its state
  without forking it needs care (register file is the bulk - SERV's RF is
  SRAM/shift-register based, decide protection story explicitly).
- **Placement flow.** Named above; prototype first.

## What ZIRH-1 hands over

Verified TMR library, UART, telemetry framer and monitor architecture;
check_tmr methodology with its negative test; the CI shape (test + GL +
precheck gating); the FPGA twin flow; the ground station. ZIRH-2 is these
plus a computer, minus nothing.
