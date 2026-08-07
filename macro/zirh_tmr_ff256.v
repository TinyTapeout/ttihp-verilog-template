// =============================================================================
// ZIRH - macro wrapper for one TMR chain replica
// macro/zirh_tmr_ff256.v
//
// Concrete, non-parameterized top for hardening zirh_tmr_ff WIDTH=256 as a
// standalone macro. This exists for the ZIRH-2 placement prototype: three
// instances of this macro placed at explicit coordinates (LibreLane MACROS
// object) is the only replica-separation mechanism available inside the
// Tiny Tapeout flow - see docs/ZIRH2-SCOPE.md.
//
// Note the interface is deliberately the raw replica, not the voted
// register: the voter must stay OUTSIDE the macro, in the parent, so that
// each of the three macro instances remains an independent replica.
// =============================================================================

`default_nettype none

module zirh_tmr_ff256 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [255:0] d_i,
    output wire [255:0] q_o
);

  zirh_tmr_ff #(
      .WIDTH (256)
  ) u_core (
      .clk   (clk),
      .rst_n (rst_n),
      .d_i   (d_i),
      .q_o   (q_o)
  );

endmodule

`default_nettype wire
