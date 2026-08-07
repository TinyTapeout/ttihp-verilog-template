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

1. **Placement constraints for TMR replicas.** Prototype phase 1 is DONE
   (2026-08-07), measured on ZIRH-1's final DEF with
   scripts/replica_dist.py:

   - All 387 same-bit replica trios in the design analyzed. Worst same-bit
     separation 3.78 um, median ~7.3 um, maximum 12.2 um.
   - 0% of same-bit pairs closer than 2 um; 25% closer than 5 um; 95%
     closer than 10 um.
   - Interpretation: the placer CLUSTERS same-bit trios rather than
     scattering them - all three replicas feed one voter gate, and
     wirelength optimization pulls them toward it. The clustering is
     structural, so it will not improve on its own in ZIRH-2's denser
     floorplan; if anything it worsens. No pair sits in the classic
     charge-sharing range (<2 um), but a quarter sit in the 3.8-5 um band
     that high-LET events can reach. ZIRH-1's ESCAPE counter puts physics
     numbers on exactly this layout.
   - Rejected idea, for the record: rotating bit order per replica in RTL
     does not help, because the voter gate remains the shared attractor
     for each trio regardless of bit naming.

   Mechanism survey for enforcing separation (phase 2, to be tested):

   - **Macro route - the only one available inside the TT flow today.**
     LibreLane's MACROS config object supports pre-hardened macros with
     explicit per-instance locations. Harden the chain replica
     (zirh_tmr_ff, WIDTH=256) once as a macro, instantiate it three times
     at chosen coordinates. Cost: a standalone LibreLane hardening flow in
     CI (the TT action only hardens the whole tile), LEF/GDS artifacts in
     the repo, timing through macro pins, and TT precheck rules for
     macros. This is the path to prototype next.
   - DEF GROUPS/REGIONS fences: OpenROAD's placers honor them, but
     LibreLane exposes no configuration variable to define them and the
     TT action does not accept custom flow steps. Available only with a
     forked flow; keep as fallback.
   - FP_DEF_TEMPLATE: copies pin locations and die area only, not
     regions. Not applicable.

   If the macro route fails in prototype, the A/B experiment reshapes
   around what the flow can express - possibly two separate seu_mon
   instances at opposite floorplan corners with the coarse separation
   that IO-pin-driven placement gives for free.
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
