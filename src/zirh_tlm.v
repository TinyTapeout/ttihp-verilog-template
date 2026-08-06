// =============================================================================
// ZIRH - telemetry framer
// zirh_tlm.v
//
// Periodically snapshots the SEU monitor and streams a fixed 10-byte frame
// out over a ready/valid byte interface (the UART TX, through the top's
// arbiter). No commands needed: the chip reports its own health as long as
// clock, reset and this block are alive - which is precisely why its control
// state is TMR'd.
//
// FRAME (10 bytes, all sent MSB-of-word first):
//   0  0x5A  'Z'  sync
//   1  0x52  'R'  sync
//   2  STATUS     {seq[3:0], armed, infra, mode[1:0]}
//   3  PLAIN[15:8]    4  PLAIN[7:0]
//   5  RAW[15:8]      6  RAW[7:0]
//   7  ESCAPE[15:8]   8  ESCAPE[7:0]
//   9  XOR of bytes 0..8
//
//   seq   : rolling frame counter - gaps reveal dropped/skipped frames
//   infra : an err_infra pulse occurred since the previous snapshot (sticky,
//           cleared at each snapshot)
//
// Hardening split:
//   * TMR: the interval countdown and the busy/index state - an upset there
//     is the difference between telemetry pausing and telemetry dying.
//   * Plain: the snapshot buffer, sequence and checksum registers - an upset
//     there corrupts one frame, and the checksum makes that visible on the
//     ground. Frames are cheap; the link is not.
//
// The snapshot is atomic: all counters and status latch in the same cycle,
// so a frame is always internally consistent even while counters move.
// If the trigger fires while a frame is still going out (only possible under
// extreme backpressure), that frame is skipped and seq shows the gap.
// =============================================================================

`default_nettype none

module zirh_tlm #(
    parameter integer INTERVAL_LOG2 = 16  // clocks between frames = 2^this
) (
    input  wire        clk,
    input  wire        rst_n,

    // from zirh_seu_mon
    input  wire [15:0] cnt_plain_i,
    input  wire [15:0] cnt_raw_i,
    input  wire [15:0] cnt_escape_i,
    input  wire        armed_i,
    input  wire [1:0]  mode_i,
    input  wire        err_infra_i,   // 1-cycle pulses, latched sticky here

    // byte stream out (to the UART through the top's arbiter)
    output wire [7:0]  tx_data_o,
    output wire        tx_valid_o,
    input  wire        tx_ready_i,

    output wire        err_o          // own TMR replica mismatch
);

    localparam integer IW = INTERVAL_LOG2;
    localparam [3:0] LAST_IDX = 4'd9;

    // --- frame interval: TMR'd countdown, fires at 0 and reloads ------------
    wire [IW-1:0] intv_q;
    wire          intv_err;
    wire          fire = (intv_q == {IW{1'b0}});

    zirh_tmr_reg #(.WIDTH(IW), .RESET_VALUE({IW{1'b1}})) u_intv (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (1'b1),
        .d_i   (fire ? {IW{1'b1}} : intv_q - {{(IW-1){1'b0}}, 1'b1}),
        .q_o   (intv_q),
        .err_o (intv_err)
    );

    // --- frame engine state: TMR'd {busy, idx} ------------------------------
    wire [4:0] st_q;
    wire       st_err;
    wire       busy = st_q[4];
    wire [3:0] idx  = st_q[3:0];

    wire start = fire & ~busy;
    wire adv   = busy & tx_ready_i;          // current byte accepted
    // ">=" not "==": if an uncorrected upset ever pushed idx past LAST_IDX,
    // the frame still terminates instead of free-running forever.
    wire done  = adv & (idx >= LAST_IDX);

    wire [4:0] st_nxt = start ? 5'b1_0000 :
                        done  ? 5'b0_0000 :
                                {1'b1, idx + 4'd1};

    zirh_tmr_reg #(.WIDTH(5)) u_st (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (start | adv),
        .d_i   (st_nxt),
        .q_o   (st_q),
        .err_o (st_err)
    );

    // --- snapshot (plain: one bad frame is visible via the checksum) --------
    reg [15:0] s_plain, s_raw, s_esc;
    reg        s_armed, s_infra;
    reg [1:0]  s_mode;
    reg [3:0]  seq;
    reg        infra_sticky;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_plain      <= 16'h0;
            s_raw        <= 16'h0;
            s_esc        <= 16'h0;
            s_armed      <= 1'b0;
            s_infra      <= 1'b0;
            s_mode       <= 2'b00;
            seq          <= 4'h0;
            infra_sticky <= 1'b0;
        end else begin
            infra_sticky <= start ? 1'b0 : (infra_sticky | err_infra_i);
            if (start) begin
                s_plain <= cnt_plain_i;
                s_raw   <= cnt_raw_i;
                s_esc   <= cnt_escape_i;
                s_armed <= armed_i;
                s_infra <= infra_sticky | err_infra_i;
                s_mode  <= mode_i;
                seq     <= seq + 4'd1;
            end
        end
    end

    // --- byte mux + running XOR checksum ------------------------------------
    wire [7:0] status = {seq, s_armed, s_infra, s_mode};

    reg [7:0] chk;
    reg [7:0] byte_mux;
    always @(*) begin
        case (idx)
            4'd0:    byte_mux = 8'h5A;
            4'd1:    byte_mux = 8'h52;
            4'd2:    byte_mux = status;
            4'd3:    byte_mux = s_plain[15:8];
            4'd4:    byte_mux = s_plain[7:0];
            4'd5:    byte_mux = s_raw[15:8];
            4'd6:    byte_mux = s_raw[7:0];
            4'd7:    byte_mux = s_esc[15:8];
            4'd8:    byte_mux = s_esc[7:0];
            default: byte_mux = chk;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n)     chk <= 8'h00;
        else if (start) chk <= 8'h00;
        else if (adv && idx < LAST_IDX) chk <= chk ^ byte_mux;
    end

    assign tx_data_o  = byte_mux;
    assign tx_valid_o = busy;

    assign err_o = intv_err | st_err;

endmodule

`default_nettype wire
