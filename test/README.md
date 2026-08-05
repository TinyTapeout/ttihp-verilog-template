# ZIRH — Test Suite

Tests are written in [cocotb](https://www.cocotb.org/) and run with Icarus Verilog.

## Setup

```sh
pip install cocotb cocotbext-uart pytest
```

## Integration test (full chip via TT harness)

Drives `tt_um_hma_zirh` through the Tiny Tapeout testbench (`tb.v`):

```sh
make -B
```

## Unit tests

Each core block has a standalone makefile (no TT harness, DUT driven directly):

```sh
make -B -f Makefile.tmr     # TMR register: voter, self-healing, 200-shot fault injection
# (more will follow: Makefile.uart, Makefile.ecc, ...)
```

## Waveforms

```sh
make -B WAVES=1
gtkwave tb.vcd            # unit tests: see sim_build/ for the dump file
```

## Synthesis-integrity checks

Simulation passing is NOT enough for TMR — synthesis can silently merge
replicas (it did once; see git history). After RTL changes run:

```sh
bash ../scripts/check_tmr.sh    # from repo root: scripts/check_tmr.sh
```

## Gate-level test

The TT flow's GL test (`GATES=yes`) runs the same cocotb tests against the
post-synthesis netlist. CI runs it automatically on every push.
