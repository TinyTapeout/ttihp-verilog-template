# ZIRH

**Z**ero-budget **I**rradiation-**R**esistant **H**ardened SoC — an open-source radiation-hardening experiment chip on IHP SG13G2.

*"Zırh" means "armor" in Turkish.*

> Built with a fully open-source flow, targeting the [Tiny Tapeout](https://tinytapeout.com) TTIHP26b shuttle on IHP SG13G2. Total budget: a few tiles and a lot of stubbornness.

## What is this?

ZIRH is a small radiation-hardened SoC designed to *measure* radiation effects, not just survive them. A TMR-protected [SERV](https://github.com/olofk/serv) RISC-V core runs housekeeping firmware from mask ROM, controls a set of spacecraft-flavored peripherals over a lightweight bus, and streams live SEU (Single Event Upset) statistics out as UART telemetry — so the chip can report on its own health while sitting in a radiation beam.

The scientific goal: compare hardened vs. unhardened structures on the same die, under the same beam, at the same time.

## Architecture

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
   │ FF chains &  │   │ SRAM macro    │                          │ │
   │ SEU counters │   │ (foundry 1KB) │                          │ │
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
| **SRAM DUT** | Foundry-provided 1 KB 6T SRAM macro with pattern-scan FSM, flip counting and address logging (MBU analysis) | Deliberately unprotected — classic SEU cross-section target |

### Design philosophy

- **Frequency is a hardening parameter.** Timing is closed well above the operating frequency; the chip runs slow on purpose, buying SET immunity and post-TID timing margin for free.
- **Protect the control, expose the data.** Control paths (FSMs, CPU state) are TMR'd so the chip never goes silent; selected datapaths are left unprotected so there is something to measure.
- **The chip is its own test bench.** Error injection inputs allow end-to-end validation of every error-handling path on the ground, before beam time is spent.

## Repository structure

```
zirh/
├── info.yaml            # Tiny Tapeout project manifest
├── src/                 # RTL (Verilog) + SERV vendor copy
├── test/                # cocotb testbenches + Makefile
├── docs/info.md         # datasheet: block diagram, memory map, how to test
├── fw/                  # SERV firmware + ROM generator
└── config.json          # OpenLane configuration
```

## Getting started

### Prerequisites

- [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, Icarus Verilog, Verilator, GTKWave)
- Python 3 with `cocotb` and `cocotbext-uart`
- RISC-V toolchain (`riscv-none-elf-gcc`) for firmware

### Run the tests

```bash
pip install cocotb cocotbext-uart
make -B -C test
```

### Lint

```bash
verilator --lint-only -Wall src/*.v
```

### Quick synthesis sanity check

```bash
yosys -p "read_verilog src/*.v; synth -top tt_um_hma_zirh; stat"
scripts/check_tmr.sh   # verifies TMR replicas survived synthesis
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
| Repository & CI skeleton | 🚧 |
| TMR library + clock/reset | 🚧 |
| UART + telemetry | ⬜ |
| SERV integration + firmware "hello" | ⬜ |
| Peripherals (CAN / SpW / NPU) | ⬜ |
| SRAM macro integration | ⬜ |
| Fault-injection campaign | ⬜ |
| Tapeout (Tiny Tapeout TTIHP26b shuttle) | ⬜ |
| Silicon bring-up | ⬜ |
| Irradiation testing (Co-60 TID) | ⬜ |

## Roadmap after silicon

- FPGA twin (iCE40/ECP5 via Yosys+nextpnr) for hardware fault injection while waiting for the chip
- Carrier PCB: CAN transceiver, RS422 driver/receiver, optional LVDS for SpaceWire
- Co-60 total ionizing dose campaign with live SEU telemetry
- Publication of all measurement data in this repository

## External hardware

- CAN transceiver (e.g. TJA1050) — chip exposes logic-level TX/RX
- RS422 driver/receiver (e.g. MAX490) — chip exposes logic-level UART
- Optional LVDS translators for electrically real SpaceWire

## Acknowledgments

Standing on the shoulders of: [SERV](https://github.com/olofk/serv) (Olof Kindgren), [Tiny Tapeout](https://tinytapeout.com) (Matt Venn & team), [TMRG](https://tmrg.web.cern.ch) (CERN), the [IHP Open PDK](https://github.com/IHP-GmbH/IHP-Open-PDK) (IHP Microelectronics) and the entire open-silicon community.

## License

Apache-2.0 (see `LICENSE`). Vendored components retain their original licenses.

---

*ZIRH is a research/education project. It is not flight-qualified hardware — it is the chip you build so that one day you know how to build that one.*
