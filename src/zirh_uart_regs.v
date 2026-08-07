// =============================================================================
// ZIRH-2 - UART register block (bus slave wrapper around zirh_rs422)
// zirh_uart_regs.v
//
// The command path: firmware talks to the UART through four word registers,
// while telemetry keeps hardware priority on the TX line - the CPU can
// never silence the health stream, only fill its gaps.
//
//   0x0 STATUS  RO  [0] tx_free (SW slot empty)  [1] rx_avail
//                   [2] ferr_sticky  [3] overrun_sticky
//                   any WRITE clears the sticky bits (W1C-style)
//   0x4 TXDATA  WO  byte to transmit; overwrites an unsent byte, so poll
//                   tx_free first
//   0x8 RXDATA  RO  received byte; reading clears rx_avail
//   0xC BAUD    RW  16-bit divisor, resets to RESET_DIV
//
// Hardening: BAUD is a zirh_tmr_reg - a corrupted divisor kills the link
// and every later byte, exactly the failure class TMR exists for. The RX
// byte buffer, sticky flags and the SW TX slot are plain flops: an upset
// there costs one byte or one false flag, both visible and recoverable.
//
// ack is combinational (single-cycle): this block can never stall the bus,
// so the bus watchdog only ever guards truly absent slaves.
// =============================================================================

`default_nettype none

module zirh_uart_regs #(
    parameter integer RESET_DIV = 174
) (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // telemetry byte stream: hardware priority on TX
    input  wire [7:0]  tlm_data_i,
    input  wire        tlm_valid_i,
    output wire        tlm_ready_o,

    // pins
    output wire        uart_tx_o,
    input  wire        uart_rx_i,

    // observability
    output wire        rx_ferr_o,   // live pulse, for pins/telemetry
    output wire        err_o        // TMR mismatch (uart counters or BAUD)
);

    localparam [1:0] R_STATUS = 2'd0, R_TXDATA = 2'd1,
                     R_RXDATA = 2'd2, R_BAUD   = 2'd3;

    wire [1:0] reg_sel = adr_i[3:2];
    wire       rd_rx    = cyc_i & ~we_i & (reg_sel == R_RXDATA);
    wire       wr_tx    = cyc_i &  we_i & (reg_sel == R_TXDATA);
    wire       wr_baud  = cyc_i &  we_i & (reg_sel == R_BAUD);
    wire       wr_stat  = cyc_i &  we_i & (reg_sel == R_STATUS);

    // --- BAUD: TMR'd divisor -------------------------------------------------
    wire [15:0] baud_q;
    wire        baud_err;

    zirh_tmr_reg #(.WIDTH(16), .RESET_VALUE(RESET_DIV[15:0])) u_baud (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (wr_baud),
        .d_i   (dat_i[15:0]),
        .q_o   (baud_q),
        .err_o (baud_err)
    );

    // --- the UART itself -----------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid, rx_ferr, tx_ready, uart_err;

    reg  [7:0] sw_data;
    reg        sw_pend;

    zirh_rs422 #(
        .DIVW (16)
    ) u_uart (
        .clk            (clk),
        .rst_n          (rst_n),
        .div_i          (baud_q),
        .tx_data_i      (tlm_valid_i ? tlm_data_i : sw_data),
        .tx_valid_i     (tlm_valid_i | sw_pend),
        .tx_ready_o     (tx_ready),
        .rx_data_o      (rx_data),
        .rx_valid_o     (rx_valid),
        .rx_frame_err_o (rx_ferr),
        .uart_tx_o      (uart_tx_o),
        .uart_rx_i      (uart_rx_i),
        .err_o          (uart_err)
    );

    assign tlm_ready_o = tx_ready;

    // --- SW transmit slot ----------------------------------------------------
    wire sw_accepted = sw_pend & tx_ready & ~tlm_valid_i;

    always @(posedge clk) begin
        if (!rst_n) begin
            sw_data <= 8'h00;
            sw_pend <= 1'b0;
        end else if (wr_tx) begin
            sw_data <= dat_i[7:0];
            sw_pend <= 1'b1;
        end else if (sw_accepted) begin
            sw_pend <= 1'b0;
        end
    end

    // --- RX buffer + sticky flags --------------------------------------------
    reg [7:0] rx_byte;
    reg       rx_avail, ferr_sticky, ovr_sticky;

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_byte     <= 8'h00;
            rx_avail    <= 1'b0;
            ferr_sticky <= 1'b0;
            ovr_sticky  <= 1'b0;
        end else begin
            if (rx_valid) begin
                rx_byte  <= rx_data;
                if (rx_avail & ~rd_rx) ovr_sticky <= 1'b1;
                rx_avail <= 1'b1;
            end else if (rd_rx) begin
                rx_avail <= 1'b0;
            end
            if (rx_ferr)   ferr_sticky <= 1'b1;
            else if (wr_stat) ferr_sticky <= 1'b0;
            if (wr_stat & ~rx_valid) ovr_sticky <= 1'b0;
        end
    end

    // --- readback ------------------------------------------------------------
    wire [31:0] status = {28'h0, ovr_sticky, ferr_sticky, rx_avail, ~sw_pend};

    assign rdt_o = (reg_sel == R_STATUS) ? status :
                   (reg_sel == R_RXDATA) ? {24'h0, rx_byte} :
                   (reg_sel == R_BAUD)   ? {16'h0, baud_q}  :
                   32'h0;

    assign ack_o = cyc_i;

    assign rx_ferr_o = rx_ferr;
    assign err_o     = uart_err | baud_err;

endmodule

`default_nettype wire
