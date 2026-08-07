#!/usr/bin/env bash
# =============================================================================
# ZIRH - synthesis integrity check for TMR structures
#
#   bash scripts/check_tmr.sh
#
# WHY THIS EXISTS
#   Passing simulation does not prove a TMR structure survives synthesis.
#   Three identical registers driven by identical logic are, to an optimiser,
#   one register. Yosys will happily collapse them and the resulting netlist
#   simulates identically - the hardening is simply gone.
#
#   The RTL defends against this by giving every replica its own
#   (* keep_hierarchy *) module (see src/zirh_tmr_lib.v). This script is the
#   proof that the defence is still working: it synthesises each block and
#   counts the replica instances and flip-flops that actually survive.
#
#   Measured on the current RTL:
#     with the attributes    -> 79 FFs in zirh_clk_rst  (TMR intact)
#     attributes stripped    -> 26 FFs                  (TMR gone, err_o
#                                                        constant-folded away)
#
# NOTES
#   - Synthesis stops before ABC. ABC is a technology mapper; replica merging
#     happens in the earlier opt/opt_merge passes, so no liberty file or PDK
#     is needed and the check runs in well under a second.
#   - -flatten is passed deliberately: it mimics the LibreLane flow and is
#     exactly the condition under which keep_hierarchy has to hold.
#   - Known fragility, not covered by the pass/fail below: an explicit
#     `opt_merge -share_all` still collapses the replicas despite
#     keep_hierarchy. That pass is not part of the standard flow, but do not
#     add it to a synthesis script.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/src"

if ! command -v yosys >/dev/null 2>&1; then
    echo "ERROR: yosys not found in PATH" >&2
    exit 127
fi

failures=0

# ---------------------------------------------------------------------------
# run_check <label> <top> <expected_replica_instances> <expected_ffs>
#           <replica_module> <source files...>
#
# Synthesises <top> and verifies that <expected_replica_instances> instances
# of <replica_module> and <expected_ffs> flip-flops survive optimisation.
# ---------------------------------------------------------------------------
run_check() {
    local label="$1" top="$2" exp_rep="$3" exp_ff="$4" rep_mod="$5"
    shift 5
    local files=("$@")

    local read_cmds=""
    for f in "${files[@]}"; do
        read_cmds+="read_verilog -sv ${SRC}/${f}; "
    done

    local script="${read_cmds}
        hierarchy -check -top ${top};
        synth -top ${top} -flatten -run begin:fine;
        opt -full;
        techmap;
        opt -full;
        select -count t:*${rep_mod}*;
        stat -top ${top};"

    local out
    if ! out="$(yosys -p "${script}" 2>&1)"; then
        echo "  FAIL  ${label}: yosys returned an error"
        echo "${out}" | tail -5 | sed 's/^/        /'
        failures=$((failures + 1))
        return
    fi

    # Replica instances: "select -count" prints "<N> objects.".
    # It counts cells per module DEFINITION, which is what we want here -
    # each replica is a separate cell in the parent module.
    local got_rep
    got_rep="$(echo "${out}" | grep -oE '^[0-9]+ objects\.$' | grep -oE '^[0-9]+' | head -1)"

    # Flip-flops: taken from the LAST section of `stat`. When the design still
    # has hierarchy that is the "design hierarchy" summary, which multiplies
    # each submodule's cells by its instance count - a plain `select -count`
    # would undercount, since it sees each module definition only once no
    # matter how many times it is instantiated. When everything collapsed into
    # a single module there is no hierarchy summary, and the last section is
    # the top module itself; summing there still reports the real number
    # instead of a misleading zero.
    local got_ff
    got_ff="$(echo "${out}" | awk '/^=== /{s=0} /DFF/{s+=$NF} END{print s+0}')"

    if [ -z "${got_rep}" ]; then
        echo "  FAIL  ${label}: could not parse replica count from yosys output"
        failures=$((failures + 1))
        return
    fi

    local ok=1

    if [ "${got_rep}" -ne "${exp_rep}" ]; then
        echo "  FAIL  ${label}: ${rep_mod} instances = ${got_rep}, expected ${exp_rep}"
        if [ "${got_rep}" -lt "${exp_rep}" ]; then
            echo "        replicas were MERGED - the TMR in ${top} is gone"
        fi
        ok=0
    fi

    if [ "${got_ff}" -ne "${exp_ff}" ]; then
        echo "  FAIL  ${label}: flip-flop count = ${got_ff}, expected ${exp_ff}"
        ok=0
    fi

    if [ "${ok}" -eq 1 ]; then
        echo "  ok    ${label}: ${got_rep}x ${rep_mod}, ${got_ff} FFs"
    else
        failures=$((failures + 1))
    fi
}

echo "ZIRH synthesis integrity check"
echo "------------------------------"

# --- check 1: the TMR register itself -------------------------------------
# zirh_tmr_reg at the default WIDTH=8:
#   3 replica instances, 3 x 8 = 24 data FFs + 1 err_o FF = 25 FFs.
run_check "zirh_tmr_reg  (TMR register replicas)" \
    zirh_tmr_reg 3 25 zirh_tmr_ff \
    zirh_tmr_lib.v

# --- check 2: the clock/reset block ---------------------------------------
# zirh_clk_rst at the default HB_BIT=23 (CW = 24):
#   3 reset-synchronizer replicas x 2 FFs        =  6
#   3 counter replicas x 24 bits                 = 72
#   1 err_hb_o FF                                =  1
#                                                  --
#                                                  79
run_check "zirh_clk_rst  (reset-sync replicas)" \
    zirh_clk_rst 3 79 zirh_rst_sync_rep \
    zirh_tmr_lib.v zirh_clk_rst.v

# --- check 3: the UART -----------------------------------------------------
# zirh_rs422 at the default DIV=174:
#   4 TMR registers in 2 parameterizations (WIDTH=4 and WIDTH=8), so the
#   library expands to 2 zirh_tmr_ff paramods x 3 replicas = 6 instances.
#   FFs: (4+8) x 2 directions x 3 replicas = 72 TMR data
#        + 4 err_o                          =  4
#        + shift/sync/capture (unprotected) = 31   -> 107 total
run_check "zirh_rs422    (UART TMR counters)" \
    zirh_rs422 6 107 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_rs422.v

# --- check 4: the SEU monitor ----------------------------------------------
# zirh_seu_mon at the default N=256, CW=16:
#   5 zirh_tmr_ff paramods (chain N=256, counters CW=16, mode 2, phase 1,
#   warm-up 9) x 3 replicas = 15 instances.
#   FFs: 3x256 TMR chain + 256 plain chain            = 1024
#        + 3 counters x 16 x 3                        =  144
#        + (mode 2 + phase 1 + warm 9) x 3            =   36
#        + 6 err + 3 evt                              =    9   -> 1213 total
run_check "zirh_seu_mon  (chain + counter replicas)" \
    zirh_seu_mon 15 1213 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_seu_mon.v

# --- check 5: the telemetry framer -----------------------------------------
# zirh_tlm at the default INTERVAL_LOG2=16:
#   2 zirh_tmr_ff paramods (interval 16, state 5) x 3 = 6 instances.
#   FFs: (16+5) x 3 TMR = 63, + 2 err, + snapshot/seq/chk/sticky 65 -> 130
run_check "zirh_tlm      (framer control replicas)" \
    zirh_tlm 6 130 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_tlm.v

# --- check 6: the ZIRH-2 bus interconnect ----------------------------------
# zirh_bus at the default TIMEOUT_LOG2=6: the ack watchdog is the only
# state - 1 zirh_tmr_ff paramod x 3 replicas, 6x3 = 18 + 1 err = 19 FFs.
run_check "zirh_bus      (watchdog replicas)" \
    zirh_bus 3 19 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_bus.v

# --- check 7: the ZIRH-2 UART register block --------------------------------
# zirh_uart_regs at RESET_DIV=174: the wrapped rs422 runs DIVW=16, so its
# 4 TMR counters are 2 paramods (w4, w16) + the BAUD register (w16) = 3
# paramods x 3 = 9 instances.
#   FFs: rs422 @16b: (4+16)x2x3=120 TMR + 4 err + 31 plain   = 155
#        + BAUD 16x3 + 1 err                                 =  49
#        + sw slot 9 + rx buffer/flags 11                    =  20  -> 224
run_check "zirh_uart_regs (cmd path replicas)" \
    zirh_uart_regs 9 224 zirh_tmr_ff \
    zirh_tmr_lib.v zirh_rs422.v zirh_uart_regs.v

# --- check 8: the module that actually gets taped out ----------------------
# The two checks above verify the blocks in isolation. This one verifies the
# top level, which is the only netlist that matters: a block can survive on
# its own and still be optimised away once it is instantiated in a context
# where the tool can see that most of its outputs go nowhere.
# 79 (clk_rst) + 107 (rs422) + 9 (echo buffer) + 1213 (seu_mon)
# + 130 (tlm) + 16 control-pin synchronizers (7x3 minus the 5 unused
# ctl_prev bits the optimizer prunes).
run_check "tt_um_hma_zirh (top level)" \
    tt_um_hma_zirh 3 1554 zirh_rst_sync_rep \
    zirh_tmr_lib.v zirh_clk_rst.v zirh_rs422.v zirh_seu_mon.v zirh_tlm.v tt_um_hma_zirh.v

echo "------------------------------"
if [ "${failures}" -eq 0 ]; then
    echo "PASS: all hardening structures survived synthesis"
    exit 0
else
    echo "FAIL: ${failures} check(s) failed - hardening structures did NOT survive"
    exit 1
fi
