// =============================================================================
// ZIRH - RS422/UART link
// zirh_rs422.v
//
// 8N1, LSB first, fixed divisor. The chip exposes logic-level TX/RX; the
// RS422 electrical layer is an external transceiver on the carrier board.
//
// Hardening: "protect the control, expose the data."
//   * TMR (zirh_tmr_reg) on everything that decides WHEN things happen:
//     bit counters and baud counters, for both directions. An upset there
//     desynchronizes the link and every later byte is garbage - that is the
//     failure mode this block must not have, because it carries telemetry.
//   * Plain flops on the data path (shift registers, RX capture): an upset
//     there corrupts one byte and the link keeps running. Frame-level
//     detection belongs to the telemetry protocol, not here.
//   * The RX input synchronizer is deliberately NOT triplicated: it samples
//     an asynchronous pin, so its replicas could legitimately disagree at
//     the metastability boundary and the voter would turn one marginal
//     sample into three. A flip here is one corrupted bit sample - data
//     path by nature, even though it is a control-looking structure.
//
//   err_o pulses whenever any TMR replica disagreed - wire it to the SEU
//   counters like every other err output in the design.
//
// The divisor is a runtime input (div_i): ZIRH-1's top drives it with the
// constant 174 (20 MHz / 174 = 114.9 kBd, -0.22% from 115200); ZIRH-2's
// register wrapper drives it from a TMR'd bus-writable register. Changing
// div_i mid-frame corrupts at most the frame in flight.
// =============================================================================

`default_nettype none

module zirh_rs422 #(
    parameter integer DIVW = 8    // divisor width; div_i >= 4
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [DIVW-1:0] div_i, // clk cycles per bit

    // TX: byte in, ready/valid
    input  wire [7:0] tx_data_i,
    input  wire       tx_valid_i,
    output wire       tx_ready_o,

    // RX: byte out, 1-cycle valid pulse
    output wire [7:0] rx_data_o,
    output wire       rx_valid_o,     // clean byte received
    output wire       rx_frame_err_o, // 1-cycle pulse: stop bit was low

    // pins (to the RS422 transceiver)
    output wire       uart_tx_o,
    input  wire       uart_rx_i,

    // SEU observability: any TMR replica mismatch, 1-cycle pulse
    output wire       err_o
);

    localparam integer BW = DIVW;
    wire [BW-1:0] BAUD_MAX = div_i - {{(BW-1){1'b0}}, 1'b1};
    wire [BW-1:0] HALF_MAX = (div_i >> 1) - {{(BW-1){1'b0}}, 1'b1};

    // -------------------------------------------------------------------------
    // TX
    //
    // tx_shift holds {stop, data[7:0], start} and shifts out LSB first,
    // refilling with 1s so the line returns to idle by construction.
    // -------------------------------------------------------------------------
    wire [3:0]    tx_cnt_q;      // bits remaining, 10 -> 0
    wire [BW-1:0] tx_baud_q;
    wire          tx_cnt_err, tx_baud_err;

    wire tx_busy  = |tx_cnt_q;
    assign tx_ready_o = ~tx_busy;

    wire tx_load = tx_valid_i & tx_ready_o;
    wire tx_tick = tx_busy & (tx_baud_q == {BW{1'b0}});

    zirh_tmr_reg #(.WIDTH(4)) u_tx_cnt (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (tx_load | tx_tick),
        .d_i   (tx_load ? 4'd10 : tx_cnt_q - 4'd1),
        .q_o   (tx_cnt_q),
        .err_o (tx_cnt_err)
    );

    zirh_tmr_reg #(.WIDTH(BW)) u_tx_baud (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (tx_load | tx_busy),
        .d_i   ((tx_load | tx_tick) ? BAUD_MAX : tx_baud_q - {{(BW-1){1'b0}}, 1'b1}),
        .q_o   (tx_baud_q),
        .err_o (tx_baud_err)
    );

    reg [9:0] tx_shift;   // data path: deliberately unprotected
    always @(posedge clk) begin
        if (!rst_n)       tx_shift <= 10'h3FF;
        else if (tx_load) tx_shift <= {1'b1, tx_data_i, 1'b0};
        else if (tx_tick) tx_shift <= {1'b1, tx_shift[9:1]};
    end

    assign uart_tx_o = tx_shift[0];

    // -------------------------------------------------------------------------
    // RX
    //
    // Falling edge on the synchronized line starts a frame. The first sample
    // lands DIV/2 cycles later (middle of the start bit), then one sample per
    // DIV. Ten samples fill rx_shift: bit0 = start, bits8:1 = data,
    // bit9 = stop. A high start sample means line glitch: dropped silently.
    // A held-low line (break) yields one frame error per 10 bit times.
    // -------------------------------------------------------------------------
    reg rx_meta, rx_sync, rx_prev;   // see header: intentionally not TMR'd
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            rx_prev <= 1'b1;
        end else begin
            rx_meta <= uart_rx_i;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;
        end
    end

    wire [3:0]    rx_cnt_q;      // samples remaining, 10 -> 0
    wire [BW-1:0] rx_baud_q;
    wire          rx_cnt_err, rx_baud_err;

    wire rx_busy  = |rx_cnt_q;
    wire rx_start = ~rx_busy & rx_prev & ~rx_sync;
    wire rx_tick  = rx_busy & (rx_baud_q == {BW{1'b0}});
    wire rx_done  = rx_tick & (rx_cnt_q == 4'd1);

    zirh_tmr_reg #(.WIDTH(4)) u_rx_cnt (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (rx_start | rx_tick),
        .d_i   (rx_start ? 4'd10 : rx_cnt_q - 4'd1),
        .q_o   (rx_cnt_q),
        .err_o (rx_cnt_err)
    );

    zirh_tmr_reg #(.WIDTH(BW)) u_rx_baud (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (rx_start | rx_busy),
        .d_i   (rx_start ? HALF_MAX :
                (rx_tick ? BAUD_MAX : rx_baud_q - {{(BW-1){1'b0}}, 1'b1})),
        .q_o   (rx_baud_q),
        .err_o (rx_baud_err)
    );

    reg [9:0] rx_shift;   // data path: deliberately unprotected
    wire [9:0] rx_nxt = {rx_sync, rx_shift[9:1]};
    always @(posedge clk) begin
        if (!rst_n)       rx_shift <= 10'h0;
        else if (rx_tick) rx_shift <= rx_nxt;
    end

    wire rx_start_ok = ~rx_nxt[0];

    reg [7:0] rx_data;
    reg       rx_valid, rx_ferr;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_data  <= 8'h00;
            rx_valid <= 1'b0;
            rx_ferr  <= 1'b0;
        end else begin
            rx_valid <= rx_done & rx_start_ok &  rx_nxt[9];
            rx_ferr  <= rx_done & rx_start_ok & ~rx_nxt[9];
            if (rx_done & rx_start_ok)
                rx_data <= rx_nxt[8:1];
        end
    end

    assign rx_data_o      = rx_data;
    assign rx_valid_o     = rx_valid;
    assign rx_frame_err_o = rx_ferr;

    // -------------------------------------------------------------------------
    assign err_o = tx_cnt_err | tx_baud_err | rx_cnt_err | rx_baud_err;

endmodule

`default_nettype wire
