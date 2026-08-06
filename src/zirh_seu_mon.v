// =============================================================================
// ZIRH - SEU monitor
// zirh_seu_mon.v
//
// The measurement instrument itself: matched protected/unprotected storage
// under the same beam, on the same die, at the same time.
//
// STRUCTURE - two circulating shift chains of identical length N:
//
//   * PLAIN chain: N ordinary flops. A known bit stream circulates; the bit
//     leaving the chain is compared with the bit that entered N cycles ago.
//     A flipped bit travels to the exit, is counted ONCE, and leaves the
//     ring - the chain re-arms itself with no scrub logic.
//
//   * TMR chain: the same ring built from three zirh_tmr_ff replicas with a
//     majority voter, voted feedback (self-healing, same principle as
//     zirh_tmr_reg). Two things are counted separately:
//       - RAW    : any replica disagreement (1-cycle pulse - the voted
//                  feedback heals the flip on the next edge). This is the
//                  raw upset rate of TMR'd storage.
//       - ESCAPE : the voted exit bit is wrong. Single upsets can not do
//                  this; a same-bit double upset can. Expected to be ~zero;
//                  this counter IS the experiment's headline number.
//
//   The TMR chain is built directly from zirh_tmr_ff + zirh_voter rather
//   than zirh_tmr_reg because it needs per-replica fault injection, which
//   the library register deliberately does not expose. The verified library
//   stays untouched.
//
// PATTERNS (mode_i): 00 all-zeros, 01 all-ones, 1x checkerboard. The
//   checkerboard phase generator and all counters are zirh_tmr_reg - an
//   upset in the instrument's own bookkeeping must not fabricate data.
//   Their mismatch pulses are exposed on err_infra_o and deliberately NOT
//   counted: infrastructure upsets are not part of the measurement.
//
// INJECTION (ground validation, per the "chip is its own test bench" rule):
//   inj_plain_i  - flip one mid-chain bit of the plain chain   -> PLAIN +1
//   inj_tmr_i    - flip the same bit in ONE TMR replica        -> RAW   +1
//   inj_escape_i - flip that bit in ALL THREE replicas         -> ESCAPE +1
//   Each is a 1-cycle pulse; each must produce exactly one count. The
//   escape injection proves the one path that real beam time may never
//   exercise.
//
// WARM-UP: after reset or a mode change the rings hold stale bits, so
//   counting is suppressed for N+4 cycles while the new pattern fills the
//   pipeline. N must be EVEN (checkerboard alignment at the exit).
// =============================================================================

`default_nettype none

module zirh_seu_mon #(
    parameter integer N  = 256,       // chain length, must be even
    parameter integer CW = 16         // counter width
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  mode_i,        // 00 zeros, 01 ones, 1x checkerboard
    input  wire        clear_i,       // sync clear of the three counters

    input  wire        inj_plain_i,   // 1-cycle: flip plain chain mid-bit
    input  wire        inj_tmr_i,     // 1-cycle: flip one TMR replica mid-bit
    input  wire        inj_escape_i,  // 1-cycle: flip all three replicas

    input  wire [1:0]  sel_i,         // counter select for rd_data_o
    output wire [CW-1:0] rd_data_o,

    // parallel counter/state outputs for the telemetry framer (wires only;
    // the rd_data_o mux stays the pin-facing read port)
    output wire [CW-1:0] cnt_plain_o,
    output wire [CW-1:0] cnt_raw_o,
    output wire [CW-1:0] cnt_escape_o,
    output wire [1:0]    mode_o,

    output wire        evt_plain_o,   // 1-cycle event pulses (bench scope)
    output wire        evt_raw_o,
    output wire        evt_escape_o,
    output wire        armed_o,       // low during warm-up

    output wire        err_infra_o    // instrument's own TMR mismatches
);

    localparam integer INJ_POS = N / 2;
    localparam integer WW = $clog2(N + 5);   // warm-up counter width
    localparam [WW-1:0] WARM_LOAD = N + 4;

    // -------------------------------------------------------------------------
    // Pattern source
    // -------------------------------------------------------------------------
    wire [1:0] mode_q;
    wire       mode_err;

    zirh_tmr_reg #(.WIDTH(2)) u_mode (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (1'b1),
        .d_i   (mode_i),
        .q_o   (mode_q),
        .err_o (mode_err)
    );

    wire mode_change = (mode_q != mode_i);

    wire phase_q;
    wire phase_err;

    zirh_tmr_reg #(.WIDTH(1)) u_phase (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (1'b1),
        .d_i   (~phase_q),
        .q_o   (phase_q),
        .err_o (phase_err)
    );

    wire in_bit = mode_q[1] ? phase_q : mode_q[0];

    // With N even, the checkerboard bit leaving the ring equals the bit
    // entering it, so one comparison value serves every mode.
    wire expected_bit = in_bit;

    // -------------------------------------------------------------------------
    // Warm-up: count nothing until the pattern has filled both rings
    // -------------------------------------------------------------------------
    wire [WW-1:0] warm_q;
    wire          warm_err;

    zirh_tmr_reg #(.WIDTH(WW), .RESET_VALUE(WARM_LOAD)) u_warm (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (mode_change | (|warm_q)),
        .d_i   (mode_change ? WARM_LOAD : warm_q - {{(WW-1){1'b0}}, 1'b1}),
        .q_o   (warm_q),
        .err_o (warm_err)
    );

    wire armed = (warm_q == {WW{1'b0}});
    assign armed_o = armed;

    // -------------------------------------------------------------------------
    // PLAIN chain: the unprotected target
    // -------------------------------------------------------------------------
    reg  [N-1:0] plain_q;
    wire [N-1:0] plain_nxt = {plain_q[N-2:0], in_bit}
                             ^ ({{(N-1){1'b0}}, inj_plain_i} << INJ_POS);

    always @(posedge clk) begin
        if (!rst_n) plain_q <= {N{1'b0}};
        else        plain_q <= plain_nxt;
    end

    wire plain_evt = armed & (plain_q[N-1] != expected_bit);

    // -------------------------------------------------------------------------
    // TMR chain: three replicas, voted feedback, per-replica injection
    // -------------------------------------------------------------------------
    wire [N-1:0] ch_a, ch_b, ch_c, ch_voted;

    zirh_voter #(.WIDTH(N)) u_ch_voter (
        .a_i (ch_a),
        .b_i (ch_b),
        .c_i (ch_c),
        .y_o (ch_voted)
    );

    wire [N-1:0] inj_mask = {{(N-1){1'b0}}, 1'b1} << INJ_POS;
    wire [N-1:0] ch_base  = {ch_voted[N-2:0], in_bit}
                            ^ (inj_escape_i ? inj_mask : {N{1'b0}});
    wire [N-1:0] ch_d_a   = ch_base
                            ^ (inj_tmr_i ? inj_mask : {N{1'b0}});

    zirh_tmr_ff #(.WIDTH(N)) u_ch_a
        (.clk(clk), .rst_n(rst_n), .d_i(ch_d_a),  .q_o(ch_a));
    zirh_tmr_ff #(.WIDTH(N)) u_ch_b
        (.clk(clk), .rst_n(rst_n), .d_i(ch_base), .q_o(ch_b));
    zirh_tmr_ff #(.WIDTH(N)) u_ch_c
        (.clk(clk), .rst_n(rst_n), .d_i(ch_base), .q_o(ch_c));

    wire raw_evt    = armed & (|((ch_a ^ ch_b) | (ch_b ^ ch_c) | (ch_a ^ ch_c)));
    wire escape_evt = armed & (ch_voted[N-1] != expected_bit);

    // -------------------------------------------------------------------------
    // Counters: saturating, TMR'd - beam data must not wrap or be fabricated
    // -------------------------------------------------------------------------
    wire [CW-1:0] cnt_plain_q, cnt_raw_q, cnt_escape_q;
    wire          cnt_plain_err, cnt_raw_err, cnt_escape_err;

    localparam [CW-1:0] CNT_MAX = {CW{1'b1}};

    zirh_tmr_reg #(.WIDTH(CW)) u_cnt_plain (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (clear_i | (plain_evt & (cnt_plain_q != CNT_MAX))),
        .d_i   (clear_i ? {CW{1'b0}} : cnt_plain_q + {{(CW-1){1'b0}}, 1'b1}),
        .q_o   (cnt_plain_q),
        .err_o (cnt_plain_err)
    );

    zirh_tmr_reg #(.WIDTH(CW)) u_cnt_raw (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (clear_i | (raw_evt & (cnt_raw_q != CNT_MAX))),
        .d_i   (clear_i ? {CW{1'b0}} : cnt_raw_q + {{(CW-1){1'b0}}, 1'b1}),
        .q_o   (cnt_raw_q),
        .err_o (cnt_raw_err)
    );

    zirh_tmr_reg #(.WIDTH(CW)) u_cnt_escape (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (clear_i | (escape_evt & (cnt_escape_q != CNT_MAX))),
        .d_i   (clear_i ? {CW{1'b0}} : cnt_escape_q + {{(CW-1){1'b0}}, 1'b1}),
        .q_o   (cnt_escape_q),
        .err_o (cnt_escape_err)
    );

    // -------------------------------------------------------------------------
    // Readout + event pulses
    // -------------------------------------------------------------------------
    // sel 11 returns a signature word: constant ID byte for read-path
    // bring-up, plus live status. [15:8]=0x5A [3]=armed [1:0]=mode
    assign rd_data_o =
        (sel_i == 2'b00) ? cnt_plain_q  :
        (sel_i == 2'b01) ? cnt_raw_q    :
        (sel_i == 2'b10) ? cnt_escape_q :
        {8'h5A, {(CW-12){1'b0}}, armed, 1'b0, mode_q};

    assign cnt_plain_o  = cnt_plain_q;
    assign cnt_raw_o    = cnt_raw_q;
    assign cnt_escape_o = cnt_escape_q;
    assign mode_o       = mode_q;

    reg evt_plain_r, evt_raw_r, evt_escape_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            evt_plain_r  <= 1'b0;
            evt_raw_r    <= 1'b0;
            evt_escape_r <= 1'b0;
        end else begin
            evt_plain_r  <= plain_evt;
            evt_raw_r    <= raw_evt;
            evt_escape_r <= escape_evt;
        end
    end

    assign evt_plain_o  = evt_plain_r;
    assign evt_raw_o    = evt_raw_r;
    assign evt_escape_o = evt_escape_r;

    assign err_infra_o = mode_err | phase_err | warm_err |
                         cnt_plain_err | cnt_raw_err | cnt_escape_err;

endmodule

`default_nettype wire
