# ZIRH

**Radiation-Tolerant RISC-V SoC Platform**

*"Zırh" means "armor" in Turkish.*

> Open-source rad-hard-by-design SoC with in-silicon SEU instrumentation, on IHP SG13G2 130 nm. **ZIRH-1**, the platform's first silicon, targets the Tiny Tapeout TTIHP26b shuttle.

## What is this?

ZIRH is a radiation-hardened SoC platform designed to *measure* radiation effects, not just survive them. A TMR-protected [SERV](https://github.com/olofk/serv) RISC-V core runs housekeeping firmware from mask ROM, controls a set of spacecraft-flavored peripherals over a lightweight bus, and streams live SEU (Single Event Upset) statistics out as UART telemetry — so the chip can report on its own health while sitting in a radiation beam.

The scientific goal: compare hardened vs. unhardened structures on the same die, under the same beam, at the same time.

## Architecture (ZIRH-1)

```
                 ┌─────────────────────────────────────────────────┐
                 │                 tt_um_hma_zirh                  │
  clk ──►┌───────┴──────┐                                          │
  rst_n─►│ zirh_clk_rst │ (TMR)                                    │
         └───────┬──────┘                                          │
                 │                                                 │
   ┌─────────────┴────────── zirh_bus (Wishbone-lite) ───────────┐ │
   │        │         │        │        │       │        │       │ │
┌──┴───┐ ┌──┴───┐ ┌───┴──┐ ┌───┴───┐ ┌──┴──┐ ┌──┴───┐ ┌──┴────┐  │ │
│ SERV │ │ ROM  │ │ RAM  │ │RS422/ │ │ CAN │ │ SpW  │ │ NPU   │  │ │
│(TMR) │ │(mask)│ │+ECC  │ │UART   │ │ctrl │ │lite  │ │int8MAC│  │ │
└──────┘ └──────┘ └──────┘ └───────┘ └─────┘ └──────┘ └───────┘  │ │
                                                                 │ │
   ┌──────────────┐   ┌───────────────┐                          │ │
   │ zirh_seu_mon │   │ zirh_sram_dut │                          │ │
   │ FF chains &  │   │ SRAM macros   │                          │ │
   │ SEU counters │   │ (4KB foundry) │                          │ │
   └──────────────┘   └───────────────┘                          │ │
                 └───────────────────────────────────────────────┘ │
                 └─────────────────────────────────────────────────┘
```

### Blocks

| Block | Description | Hardening |
|---|---|---|
| **SERV core** | Bit-serial RV32I, the world's smallest RISC-V | TMR on all state |
| **ROM** | Mask ROM (synthesized constants), holds firmware | Inherently SEU-immune |
| **RAM** | Small DFF-based data RAM | Hamming SECDED ECC |
| **RS422/UART** | Telemetry + command link | TMR control path |
| **CAN** | CAN 2.0A controller (external transceiver required) | TMR on protocol FSMs |
| **SpaceWire-lite** | Data-Strobe encoded link, logic-level | TMR on link FSM |
| **NPU** | Small int8 MAC array | Control TMR'd; **datapath deliberately unprotected** — it is an experiment target |
| **SEU monitor** | Matched TMR'd / unprotected FF chains + error counters | The measurement instrument itself |
| **SRAM DUT** | 4 KB of foundry 6T SRAM macros with pattern-scan FSM, flip counting and address logging (MBU analysis) | Deliberately unprotected — classic SEU cross-section target |

### Design philosophy

- **Frequency is a hardening parameter.** Timing is closed at 50 MHz; nominal operation is 12–20 MHz. The margin buys SET immunity and post-TID timing headroom for free.
- **Protect the control, expose the data.** Control paths (FSMs, CPU state) are TMR'd so the chip never goes silent; selected datapaths are left unprotected so there is something to measure.
- **The chip is its own test bench.** Error injection inputs allow end-to-end validation of every error-handling path on the ground, before beam time is spent.
- **Verification-first.** Simulation passing is not enough: synthesis once silently merged all three TMR replicas into a single register — caught by `scripts/check_tmr.sh`, which now guards every build. If a hardening structure is not verified after synthesis, it does not exist.

## Repository structure

```
zirh/
├── info.yaml            # Tiny Tapeout project manifest
├── src/                 # RTL (Verilog) + SERV vendor copy + config.json
├── test/                # cocotb testbenches + Makefile
├── scripts/             # synthesis-integrity checks (check_tmr.sh)
├── docs/info.md         # datasheet: block diagram, memory map, how to test
└── fw/                  # SERV firmware + ROM generator
```

## Getting started

### Prerequisites

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, Icarus Verilog, Verilator, GTKWave)
- Python 3 with `cocotb` and `cocotbext-uart`
- RISC-V toolchain (`riscv-none-elf-gcc`) for firmware
- [KLayout](https://www.klayout.de/) for GDS inspection and IHP DRC/LVS

### Run the tests

```sh
pip install cocotb cocotbext-uart pytest
make -B -C test                       # integration test (TT harness)
make -B -C test -f Makefile.tmr       # TMR unit test + fault injection
```

### Verify hardening structures survive synthesis

```sh
bash scripts/check_tmr.sh
```

### Hardening (GDS)

Pushing to `main` triggers the Tiny Tapeout GitHub Actions flow (LibreLane, ihp-sg13g2), producing the GDS, DRC/STA reports and a 3D render as CI artifacts.

## Verification strategy

Priority-driven, honestly scoped:

- **P0 — telemetry, SEU monitor, clock/reset:** fully verified, including cocotb fault-injection campaigns (random bit flips into FFs, recovery checked).
- **P1 — UART:** fully verified.
- **P2 — CAN:** loopback + reference-model tests.
- **P3 — SpaceWire-lite, NPU:** smoke-level (link-up + packet echo; golden-model comparison). Known limitations are documented in `docs/info.md`.

## Status

| Milestone | State |
|---|---|
| Repository & CI skeleton | ✅ |
| TMR library (voter, self-correcting register) + fault-injection test | ✅ |
| Clock/reset + UART + telemetry | 🚧 |
| SERV integration + firmware "hello" | ⬜ |
| Peripherals (CAN / SpW / NPU) | ⬜ |
| SRAM macro integration (4 KB) | ⬜ |
| Full-chip fault-injection campaign | ⬜ |
| Tapeout (Tiny Tapeout TTIHP26b shuttle) | ⬜ |
| Silicon bring-up | ⬜ |
| Irradiation testing (Co-60 TID) | ⬜ |

## Methodology

ZIRH-1 is built end-to-end on open-source silicon infrastructure: open PDK, open EDA flow, open IP, open verification — and fabricated on a community MPW shuttle for the cost of a few tiles. This is a deliberate methodology choice, not a compromise: it makes every result in this repository — RTL, hardening structures, testbenches, and eventually beam data — independently reproducible by anyone. Radiation-effects data on open-PDK silicon is scarce; ZIRH exists to add to it, with the full design available for scrutiny next to every measurement.

## Roadmap

- **ZIRH-1** (this repo): first silicon, IHP SG13G2, TTIHP26b — hardening architecture + SEU instrumentation
- FPGA twin (iCE40/ECP5 via Yosys+nextpnr) for hardware fault injection while waiting for silicon
- Carrier PCB: CAN transceiver, RS422 driver/receiver, optional LVDS for SpaceWire
- Co-60 total ionizing dose campaign with live SEU telemetry; beam data published here
- **ZIRH-2**: second-generation platform — candidate directions include full SpaceWire, larger NPU, and cross-process comparison

## External hardware

- CAN transceiver (e.g. TJA1050) — chip exposes logic-level TX/RX
- RS422 driver/receiver (e.g. MAX490) — chip exposes logic-level UART
- Optional LVDS translators for electrically real SpaceWire

## Acknowledgments

Standing on the shoulders of: [SERV](https://github.com/olofk/serv) (Olof Kindgren), [Tiny Tapeout](https://tinytapeout.com) (Matt Venn & team), [TMRG](https://tmrg.web.cern.ch) (CERN), the [IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK) (IHP Microelectronics) and the entire open-silicon community.

## License

Apache-2.0 (see `LICENSE`). Vendored components retain their original licenses.

---

*ZIRH-1 is a research and characterization vehicle. It is not flight-qualified hardware — it is the chip you build so that one day you know how to build that one.*
