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

  // --- UART, wired as a hardware echo --------------------------------------
  // No CPU and no bus yet, so the UART echoes every received byte back.
  // That makes the link testable end-to-end on the bench with nothing but a
  // serial adapter: type a byte, get it back, and both directions plus all
  // four TMR'd counters have been exercised in real silicon.
  //
  // The 1-deep pending buffer absorbs the case where a byte finishes
  // arriving while the echo of the previous one is still going out
  // (back-to-back frames from the sender). At equal baud rates TX drains as
  // fast as RX fills, so one slot is enough by construction.
  wire [7:0] rx_data;
  wire       rx_valid, rx_ferr;
  wire       tx_ready;
  wire       err_uart;
  wire       uart_tx;

  reg  [7:0] pend_data;
  reg        pend_valid;

  zirh_rs422 #(
      .DIV (174)             // 20 MHz / 174 = 114.9 kBd (115200 -0.22%)
  ) u_uart (
      .clk            (clk),
      .rst_n          (rst_n_sys),
      .tx_data_i      (pend_data),
      .tx_valid_i     (pend_valid),
      .tx_ready_o     (tx_ready),
      .rx_data_o      (rx_data),
      .rx_valid_o     (rx_valid),
      .rx_frame_err_o (rx_ferr),
      .uart_tx_o      (uart_tx),
      .uart_rx_i      (ui_in[3]),
      .err_o          (err_uart)
  );

  always @(posedge clk) begin
    if (!rst_n_sys) begin
      pend_data  <= 8'h00;
      pend_valid <= 1'b0;
    end else if (rx_valid) begin
      pend_data  <= rx_data;
      pend_valid <= 1'b1;
    end else if (pend_valid && tx_ready) begin
      pend_valid <= 1'b0;
    end
  end

  // --- SEU monitor ----------------------------------------------------------
  // Control pins (all level signals from the bench / RP2040, so each one is
  // 2-FF synchronized; INJ and CLEAR are additionally edge-detected so a
  // held-high pin fires exactly once):
  //
  //   ui[1:0] SEL      counter select: 0 plain, 1 raw, 2 escape, 3 signature
  //   ui[2]   SEL_HI   0: low byte on uio, 1: high byte
  //   ui[4]   MODE0    pattern: 00 zeros, 01 ones, 1x checkerboard
  //   ui[5]   MODE1
  //   ui[6]   INJ      rising edge injects into the target SEL points at:
  //                    sel 0 -> plain chain, 1 -> one TMR replica,
  //                    sel 2 -> all three replicas (escape path)
  //   ui[7]   CLEAR    rising edge zeroes the counters
  //
  // KNOWN LIMITATION: the input synchronizers are plain flops. An upset there
  // can fabricate one INJ or CLEAR edge. During beam campaigns the control
  // lines are grounded externally; a spurious CLEAR is visible in telemetry
  // as a counter drop, a spurious INJ as exactly +1.
  wire [6:0] ctl_pins = {ui_in[7], ui_in[6], ui_in[5], ui_in[4],
                         ui_in[2], ui_in[1], ui_in[0]};
  reg  [6:0] ctl_meta, ctl_q, ctl_prev;
  always @(posedge clk) begin
    if (!rst_n_sys) begin
      ctl_meta <= 7'b0;
      ctl_q    <= 7'b0;
      ctl_prev <= 7'b0;
    end else begin
      ctl_meta <= ctl_pins;
      ctl_q    <= ctl_meta;
      ctl_prev <= ctl_q;
    end
  end

  wire [1:0] seu_sel   = ctl_q[1:0];
  wire       sel_hi    = ctl_q[2];
  wire [1:0] seu_mode  = ctl_q[4:3];
  wire       inj_edge  = ctl_q[5] & ~ctl_prev[5];
  wire       clr_edge  = ctl_q[6] & ~ctl_prev[6];

  wire [15:0] seu_rd;
  wire        evt_plain, evt_raw, evt_escape, seu_armed, err_infra;

  zirh_seu_mon #(
      .N  (256),
      .CW (16)
  ) u_seu_mon (
      .clk          (clk),
      .rst_n        (rst_n_sys),
      .mode_i       (seu_mode),
      .clear_i      (clr_edge),
      .inj_plain_i  (inj_edge & (seu_sel == 2'd0)),
      .inj_tmr_i    (inj_edge & (seu_sel == 2'd1)),
      .inj_escape_i (inj_edge & (seu_sel == 2'd2)),
      .sel_i        (seu_sel),
      .rd_data_o    (seu_rd),
      .evt_plain_o  (evt_plain),
      .evt_raw_o    (evt_raw),
      .evt_escape_o (evt_escape),
      .armed_o      (seu_armed),
      .err_infra_o  (err_infra)
  );

  wire seu_evt = evt_plain | evt_raw | evt_escape;

  //  uo[0] HEARTBEAT     ~1.2 Hz toggle - clock, reset and TMR counter alive
  //  uo[1] TICK_DIV16    1-cycle strobe every 16 clocks
  //  uo[2] TICK_DIV256   1-cycle strobe every 256 clocks
  //  uo[3] ERR_HB        TMR replica mismatch in the heartbeat counter
  //  uo[4] UART_TX       echo of every byte received on ui[3]
  //  uo[5] ERR_UART      TMR replica mismatch in the UART counters
  //  uo[6] RX_FERR       1-cycle pulse: broken frame on the RX line
  //  uo[7] SEU_EVT       1-cycle pulse per monitor event (scope the beam live)
  assign uo_out = {seu_evt, rx_ferr, err_uart, uart_tx,
                   err_hb, tick_div256, tick_div16, heartbeat};

  // uio[7:0] = RD_DATA: the byte of the selected counter (SEL, SEL_HI).
  // Outputs once the synchronized reset releases; inputs during reset.
  assign uio_out = sel_hi ? seu_rd[15:8] : seu_rd[7:0];
  assign uio_oe  = {8{rst_n_sys}};

  // Tie off what is not consumed yet, so the linter stays quiet.
  // err_infra and seu_armed travel over the telemetry link once zirh_tlm
  // exists; until then armed is readable in the signature word (SEL=3).
  wire _unused = &{ena, uio_in, err_infra, seu_armed, 1'b0};

endmodule

`default_nettype wire
