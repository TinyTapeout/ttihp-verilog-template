// =============================================================================
// ZIRH — TMR library
// zirh_tmr_lib.v
//
// Building blocks for triple modular redundancy:
//   * zirh_voter    : parameterized bitwise majority voter (combinational)
//   * zirh_tmr_ff   : single register replica (one per TMR copy)
//   * zirh_tmr_reg  : self-correcting TMR register with error (SEU) detection
//
// WHY REPLICAS LIVE IN THEIR OWN MODULE:
//   A plain (* keep *) on three identical regs in one module is NOT enough —
//   Yosys opt_merge can still merge identical flip-flops into one register,
//   silently destroying the TMR (verified experimentally; see git history).
//   Merging cannot cross module boundaries, and (* keep_hierarchy *) prevents
//   flattening, so each replica is an instance of zirh_tmr_ff.
//   scripts/check_tmr.sh verifies FF count after synthesis on every run.
//
// Other design notes:
//   - The voted value is fed back into all three replicas every cycle
//     ("autocorrection"): a single flipped replica self-heals on the next
//     clock edge instead of accumulating errors.
//   - err_o pulses for one cycle whenever the replicas disagreed — this is
//     the raw signal the SEU counters in zirh_seu_mon will count.
// =============================================================================

`default_nettype none

// -----------------------------------------------------------------------------
// Bitwise 2-of-3 majority voter
// -----------------------------------------------------------------------------
(* keep_hierarchy *)
module zirh_voter #(
    parameter WIDTH = 1
) (
    input  wire [WIDTH-1:0] a_i,
    input  wire [WIDTH-1:0] b_i,
    input  wire [WIDTH-1:0] c_i,
    output wire [WIDTH-1:0] y_o
);

    // majority(a,b,c) = ab | bc | ca, bitwise
    assign y_o = (a_i & b_i) | (b_i & c_i) | (c_i & a_i);

endmodule

// -----------------------------------------------------------------------------
// One TMR replica. Module boundary + keep_hierarchy = merge-proof.
// -----------------------------------------------------------------------------
(* keep_hierarchy *)
module zirh_tmr_ff #(
    parameter WIDTH = 8,
    parameter [WIDTH-1:0] RESET_VALUE = {WIDTH{1'b0}}
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] d_i,
    output reg  [WIDTH-1:0] q_o
);

    always @(posedge clk) begin
        if (!rst_n) q_o <= RESET_VALUE;
        else        q_o <= d_i;
    end

endmodule

// -----------------------------------------------------------------------------
// Self-correcting TMR register
//
//   q_o    : voted output (use this everywhere downstream)
//   err_o  : 1-cycle pulse when any replica disagreed at the clock edge
//
// Synchronous active-low reset (matches Tiny Tapeout convention).
// -----------------------------------------------------------------------------
(* keep_hierarchy *)
module zirh_tmr_reg #(
    parameter WIDTH  = 8,
    parameter [WIDTH-1:0] RESET_VALUE = {WIDTH{1'b0}}
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             en_i,     // load enable
    input  wire [WIDTH-1:0] d_i,      // data in
    output wire [WIDTH-1:0] q_o,      // voted data out
    output reg              err_o     // replica mismatch detected (SEU!)
);

    wire [WIDTH-1:0] q_a, q_b, q_c;
    wire [WIDTH-1:0] voted;

    zirh_voter #(.WIDTH(WIDTH)) u_voter (
        .a_i (q_a),
        .b_i (q_b),
        .c_i (q_c),
        .y_o (voted)
    );

    assign q_o = voted;

    // Next value: new data when enabled, otherwise the VOTED current value.
    // Feeding back 'voted' (not each replica's own value) is what makes the
    // register self-correcting: a corrupted replica gets overwritten with
    // the majority value at the next edge.
    wire [WIDTH-1:0] nxt = en_i ? d_i : voted;

    zirh_tmr_ff #(.WIDTH(WIDTH), .RESET_VALUE(RESET_VALUE))
        u_ff_a (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(q_a));
    zirh_tmr_ff #(.WIDTH(WIDTH), .RESET_VALUE(RESET_VALUE))
        u_ff_b (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(q_b));
    zirh_tmr_ff #(.WIDTH(WIDTH), .RESET_VALUE(RESET_VALUE))
        u_ff_c (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(q_c));

    // Mismatch = any replica differs from any other
    wire mismatch = |((q_a ^ q_b) | (q_b ^ q_c) | (q_a ^ q_c));

    always @(posedge clk) begin
        if (!rst_n) err_o <= 1'b0;
        else        err_o <= mismatch;   // registered: clean 1-cycle pulse
    end

endmodule

`default_nettype wire
