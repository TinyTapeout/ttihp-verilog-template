// =============================================================================
// ZIRH-2 - single-master bus interconnect
// zirh_bus.v
//
// The smallest thing SERV can talk through: Wishbone-flavored cyc/ack, one
// master (the SERV data bus), up to 8 slave slots decoded from 4 KB regions
// (adr[14:12]). No bursts, no arbitration, no pipelining - one transaction
// in flight, held until ack.
//
// Hardening: the interconnect is deliberately almost stateless. Decode and
// muxing are combinational; an SET there can corrupt at most the one
// transaction in flight, which is the data-path cost we accept everywhere
// else. The ONE piece of state is the ack watchdog, and it is the piece
// that must not fail: a slave that never acks (unpopulated slot, or a
// peripheral wedged by an upset) would hang the CPU forever. The watchdog
// counter is therefore a zirh_tmr_reg. On timeout the bus completes the
// transaction itself with ERR_RDT (reads as 0xDEADBEEF) and pulses
// evt_timeout_o - the CPU keeps running and telemetry reports the event.
//
// Slave-side ports are flattened vectors (Verilog-2005 has no port
// arrays): slave i owns s_rdt_i[i*32 +: 32] and bit i of s_cyc_o/s_ack_i.
// Address, write data, byte select and we are broadcast; only the selected
// slave sees its cyc raised.
// =============================================================================

`default_nettype none

module zirh_bus #(
    parameter integer TIMEOUT_LOG2 = 6   // ack deadline = 2^this clocks
) (
    input  wire         clk,
    input  wire         rst_n,

    // master (SERV dbus)
    input  wire [31:0]  m_adr_i,
    input  wire [31:0]  m_dat_i,
    input  wire [3:0]   m_sel_i,
    input  wire         m_we_i,
    input  wire         m_cyc_i,
    output wire [31:0]  m_rdt_o,
    output wire         m_ack_o,

    // 8 slave slots, 4 KB each: slot = m_adr_i[14:12]
    output wire [7:0]   s_cyc_o,
    output wire [31:0]  s_adr_o,
    output wire [31:0]  s_dat_o,
    output wire [3:0]   s_sel_o,
    output wire         s_we_o,
    input  wire [255:0] s_rdt_i,     // slave i: s_rdt_i[i*32 +: 32]
    input  wire [7:0]   s_ack_i,

    // observability
    output wire         evt_timeout_o,  // 1-cycle pulse: watchdog fired
    output wire         err_o           // watchdog TMR replica mismatch
);

    localparam integer TW = TIMEOUT_LOG2;
    localparam [31:0] ERR_RDT = 32'hDEAD_BEEF;

    wire [2:0] slot = m_adr_i[14:12];

    // --- ack watchdog: the bus's only state, TMR'd ---------------------------
    wire [TW-1:0] wd_q;
    wire          wd_err;

    wire slave_ack = s_ack_i[slot];
    wire fired     = m_cyc_i & (wd_q == {TW{1'b1}});
    wire done      = slave_ack | fired;

    // counts while a transaction waits; clears the cycle it completes or
    // the master drops cyc
    zirh_tmr_reg #(.WIDTH(TW)) u_wd (
        .clk   (clk),
        .rst_n (rst_n),
        .en_i  (1'b1),
        .d_i   ((m_cyc_i & ~done) ? wd_q + {{(TW-1){1'b0}}, 1'b1}
                                  : {TW{1'b0}}),
        .q_o   (wd_q),
        .err_o (wd_err)
    );

    // --- routing -------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_cyc
            assign s_cyc_o[i] = m_cyc_i & (slot == i[2:0]) & ~fired;
        end
    endgenerate

    assign s_adr_o = m_adr_i;
    assign s_dat_o = m_dat_i;
    assign s_sel_o = m_sel_i;
    assign s_we_o  = m_we_i;

    assign m_rdt_o = fired ? ERR_RDT : s_rdt_i[slot*32 +: 32];
    assign m_ack_o = done & m_cyc_i;

    assign evt_timeout_o = fired;
    assign err_o         = wd_err;

endmodule

`default_nettype wire
