// =============================================================================
// ZIRH - phase 4 separation test top
// macro/p4_sep_test.v
//
// Three instances of the hardened zirh_tmr_ff256 macro, wired exactly like
// the seu_mon TMR ring (bitwise voter, voted feedback, one seed bit in).
// The point is not the logic - it is the three instances being pinned to
// explicit, far-apart coordinates through the MACROS config object, and the
// flow carrying that through to a clean GDS.
//
// Deliberately NOT the ZIRH-1 top: three 216x235 um macros plus ZIRH-1's
// remaining logic would fill ~98% of a 4x2 tile and never place. The
// mechanism proof needs only the macros and their voter.
// =============================================================================

`default_nettype none

module p4_sep_test (
    input  wire clk,
    input  wire rst_n,
    input  wire seed_i,
    output wire ok_o,     // xor-reduce of the voted ring, keeps logic alive
    output wire err_o     // registered replica-disagreement flag
);

  wire [255:0] qa, qb, qc;

  // bitwise 2-of-3 majority, same expression as zirh_voter
  wire [255:0] voted = (qa & qb) | (qb & qc) | (qa & qc);
  wire [255:0] nxt   = {voted[254:0], seed_i};

  zirh_tmr_ff256 u_ch_a (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(qa));
  zirh_tmr_ff256 u_ch_b (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(qb));
  zirh_tmr_ff256 u_ch_c (.clk(clk), .rst_n(rst_n), .d_i(nxt), .q_o(qc));

  assign ok_o = ^voted;

  reg err_r;
  always @(posedge clk) begin
    if (!rst_n) err_r <= 1'b0;
    else        err_r <= |((qa ^ qb) | (qb ^ qc) | (qa ^ qc));
  end
  assign err_o = err_r;

endmodule

`default_nettype wire
