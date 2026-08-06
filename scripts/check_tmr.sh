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

# --- check 3: the module that actually gets taped out ----------------------
# The two checks above verify the blocks in isolation. This one verifies the
# top level, which is the only netlist that matters: a block can survive on
# its own and still be optimised away once it is instantiated in a context
# where the tool can see that most of its outputs go nowhere.
# Same 79 FFs - the top adds only wiring and constants.
run_check "tt_um_hma_zirh (top level)" \
    tt_um_hma_zirh 3 79 zirh_rst_sync_rep \
    zirh_tmr_lib.v zirh_clk_rst.v tt_um_hma_zirh.v

echo "------------------------------"
if [ "${failures}" -eq 0 ]; then
    echo "PASS: all hardening structures survived synthesis"
    exit 0
else
    echo "FAIL: ${failures} check(s) failed - hardening structures did NOT survive"
    exit 1
fi
