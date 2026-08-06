// =============================================================================
// ZIRH-1 - Tiny Tapeout top level
// tt_um_hma_zirh.v
//
// SPDX-License-Identifier: Apache-2.0
//
// SCOPE: this is the bring-up skeleton. It wires the clock/reset block to the
// TT pins and nothing else. What it proves in silicon is narrow but real:
// the clock arrives, the TMR'd reset synchronizer releases, and the TMR'd
// counter runs. That is the first thing to check on the bench and the first
// thing to check under beam.
//
// It does NOT measure anything yet. err_hb_o is a live mismatch pulse, not a
// counter - there is no SEU accumulator, no telemetry, no readout path. Those
// arrive with zirh_seu_mon and zirh_rs422.
//
// ui_in and the bidirectional pins are deliberately left unconnected: pin
// assignment for the peripherals is not settled, and committing to one here
// would mean changing it again later.
// =============================================================================

`default_nettype none

module tt_um_hma_zirh (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // At the nominal 20 MHz, HB_BIT=23 gives a ~1.2 Hz square wave on
  // HEARTBEAT: slow enough to watch on an LED, fast enough to notice
  // when it stops.
  localparam HB_BIT = 23;

  wire rst_n_sys;    // voted + synchronized reset, for the blocks that follow
  wire heartbeat;
  wire tick_div16;
  wire tick_div256;
  wire err_hb;

  zirh_clk_rst #(
      .HB_BIT (HB_BIT)
  ) u_clk_rst (
      .clk           (clk),
      .rst_n_pad     (rst_n),
      .rst_n_o       (rst_n_sys),
      .heartbeat_o   (heartbeat),
      .tick_div16_o  (tick_div16),
      .tick_div256_o (tick_div256),
      .err_hb_o      (err_hb)
  );

  //  uo[0] HEARTBEAT     ~1.2 Hz toggle - clock, reset and TMR counter alive
  //  uo[1] TICK_DIV16    1-cycle strobe every 16 clocks
  //  uo[2] TICK_DIV256   1-cycle strobe every 256 clocks
  //  uo[3] ERR_HB        TMR replica mismatch in the heartbeat counter
  assign uo_out = {4'b0000, err_hb, tick_div256, tick_div16, heartbeat};

  // No bidirectional pins in use yet: drive low, keep all of them as inputs.
  assign uio_out = 8'h00;
  assign uio_oe  = 8'h00;

  // Tie off what is not consumed yet, so the linter stays quiet.
  // rst_n_sys is already used inside zirh_clk_rst; it is named here to make
  // the intent explicit - it is the reset the peripherals will hang off.
  wire _unused = &{ena, ui_in, uio_in, rst_n_sys, 1'b0};

endmodule

`default_nettype wire
