// =============================================================================
// ZIRH — clock & reset infrastructure
// zirh_clk_rst.v
//
//   * zirh_rst_sync_rep : one 2-FF reset synchronizer replica
//   * zirh_clk_rst      : TMR'd reset synchronizer + TMR'd heartbeat +
//                         slow-tick enable strobes
//
// Design decisions (RADHARD rationale):
//   - SINGLE CLOCK DOMAIN. No divided clocks are generated: derived clocks
//     complicate CTS and add SET-sensitive clock roots. Anything slow runs
//     on the main clock with an enable strobe (tick_*).
//   - The reset path is the most SET-critical net on the chip (an upset
//     there resets everything), so the synchronizer is triplicated: three
//     independent 2-FF chains, majority-voted. Replicas live in their own
//     (* keep_hierarchy *) module so synthesis cannot merge them (see the
//     zirh_tmr_lib.v story).
//   - Heartbeat runs on a TMR'd counter, independent of CPU and bus: if
//     HEARTBEAT blinks, clock+reset+TMR are alive — first thing checked
//     on the bench and under beam.
// =============================================================================

`default_nettype none

// -----------------------------------------------------------------------------
// One reset-synchronizer replica: classic 2-FF chain.
// No reset on these FFs — they flush to the pad value within 2 cycles.
// -----------------------------------------------------------------------------
(* keep_hierarchy *)
module zirh_rst_sync_rep (
    input  wire clk,
    input  wire rst_n_pad,   // asynchronous/dirty reset from the pad
    output reg  rst_n_sync   // synchronized replica output
);

    (* keep *) reg meta;

    always @(posedge clk) begin
        meta       <= rst_n_pad;
        rst_n_sync <= meta;
    end

endmodule

// -----------------------------------------------------------------------------
// Clock & reset block
// -----------------------------------------------------------------------------
(* keep_hierarchy *)
module zirh_clk_rst #(
    parameter HB_BIT = 23    // heartbeat toggles at clk / 2^(HB_BIT+1)
                             // 20 MHz, HB_BIT=23 -> ~1.2 Hz blink
) (
    input  wire clk,
    input  wire rst_n_pad,   // raw reset from TT harness

    output wire rst_n_o,     // voted, synchronized reset for the whole SoC
    output wire heartbeat_o, // slow toggle, drive an LED/pin directly

    // slow enable strobes (1-cycle pulses), all in the main clock domain
    output wire tick_div16_o,
    output wire tick_div256_o,

    // SEU observability: mismatch pulses from internal TMR structures
    output wire err_hb_o     // heartbeat counter replica mismatch
);

    // --- TMR'd reset synchronizer -------------------------------------------
    wire rs_a, rs_b, rs_c;

    zirh_rst_sync_rep u_rs_a (.clk(clk), .rst_n_pad(rst_n_pad), .rst_n_sync(rs_a));
    zirh_rst_sync_rep u_rs_b (.clk(clk), .rst_n_pad(rst_n_pad), .rst_n_sync(rs_b));
    zirh_rst_sync_rep u_rs_c (.clk(clk), .rst_n_pad(rst_n_pad), .rst_n_sync(rs_c));

    zirh_voter #(.WIDTH(1)) u_rst_voter (
        .a_i(rs_a), .b_i(rs_b), .c_i(rs_c), .y_o(rst_n_o)
    );

    // --- TMR'd free-running counter: heartbeat + tick strobes ---------------
    localparam CW = HB_BIT + 1;

    wire [CW-1:0] cnt_q;

    zirh_tmr_reg #(.WIDTH(CW)) u_cnt (
        .clk   (clk),
        .rst_n (rst_n_o),
        .en_i  (1'b1),
        .d_i   (cnt_q + {{(CW-1){1'b0}}, 1'b1}),
        .q_o   (cnt_q),
        .err_o (err_hb_o)
    );

    assign heartbeat_o   = cnt_q[HB_BIT];
    assign tick_div16_o  = (cnt_q[3:0] == 4'hF);
    assign tick_div256_o = (cnt_q[7:0] == 8'hFF);

endmodule

`default_nettype wire
