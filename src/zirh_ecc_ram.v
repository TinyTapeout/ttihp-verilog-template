// =============================================================================
// ZIRH-2 - ECC RAM: 128 bytes, Hamming SECDED per 32-bit word
// zirh_ecc_ram.v
//
// 32 words x 39 stored bits: 32 data + 6 Hamming parity + 1 overall parity.
// Single-bit errors (data OR parity) are corrected on the fly, double-bit
// errors are detected and reported. This block deliberately contains NO TMR:
// the storage is plain flops and the protection IS the code - which is
// exactly what makes it the systematic counterpart to the SEU monitor's
// unprotected chain in beam data.
//
// Behavior:
//   * Read: decode combinationally, return the CORRECTED word. If the
//     stored word had a correctable error, it is repaired in place on the
//     same cycle (scrub-on-read) and evt_corr_o pulses - errors do not sit
//     and accumulate into double-bit losses.
//   * Full-word write: encode and store.
//   * Partial write (byte enables, as SERV issues for sb/sh): single-cycle
//     read-correct-merge-reencode. A correctable error in the untouched
//     bytes is repaired by the rewrite itself.
//   * Double-bit error: evt_uncorr_o pulses; reads return the raw decode
//     (garbage), writes proceed over it. Firmware policy decides what to
//     do; the hardware's job is to make the loss visible, not to hide it.
//
// The array has no reset (a reset tree over 1248 flops for state that
// firmware must initialize anyway would be pure cost). Simulation reads
// X until written; firmware zero-fills at boot.
//
// ack is combinational: like the UART register block, this slave can
// never stall the bus.
// =============================================================================

`default_nettype none

module zirh_ecc_ram (
    input  wire        clk,
    input  wire        rst_n,

    // bus slave: words 0..31 at adr[6:2]
    input  wire        cyc_i,
    input  wire [31:0] adr_i,
    input  wire [31:0] dat_i,
    input  wire [3:0]  sel_i,
    input  wire        we_i,
    output wire [31:0] rdt_o,
    output wire        ack_o,

    // ECC observability, for the housekeeping counters / telemetry
    output reg         evt_corr_o,    // 1-cycle: a word was repaired
    output reg         evt_uncorr_o   // 1-cycle: uncorrectable word touched
);

    // ------------------------------------------------------------------------
    // Hamming SECDED helpers. Codeword positions 1..38: parity at the powers
    // of two (1,2,4,8,16,32), data scattered over the rest, overall parity
    // stored separately as bit [38] of the 39-bit memory word (codeword is
    // kept in [37:0] as positions 1..38).
    // ------------------------------------------------------------------------

    function [38:1] place_data;
        input [31:0] d;
        integer pos, k;
        begin
            place_data = 38'b0;
            k = 0;
            for (pos = 1; pos <= 38; pos = pos + 1)
                if (pos != 1 && pos != 2 && pos != 4 &&
                    pos != 8 && pos != 16 && pos != 32) begin
                    place_data[pos] = d[k];
                    k = k + 1;
                end
        end
    endfunction

    function [37:0] gather_data_ext;   // returns {6'b0, data[31:0]} packing
        input [38:1] cw;
        integer pos, k;
        reg [31:0] d;
        begin
            d = 32'b0;
            k = 0;
            for (pos = 1; pos <= 38; pos = pos + 1)
                if (pos != 1 && pos != 2 && pos != 4 &&
                    pos != 8 && pos != 16 && pos != 32) begin
                    d[k] = cw[pos];
                    k = k + 1;
                end
            gather_data_ext = {6'b0, d};
        end
    endfunction

    function [5:0] syndrome_of;
        input [38:1] cw;
        integer pos, i;
        begin
            syndrome_of = 6'b0;
            for (i = 0; i < 6; i = i + 1)
                for (pos = 1; pos <= 38; pos = pos + 1)
                    if (((pos >> i) & 1) == 1)
                        syndrome_of[i] = syndrome_of[i] ^ cw[pos];
        end
    endfunction

    function [38:0] encode;
        input [31:0] d;
        reg [38:1] cw;
        reg [5:0]  syn;
        integer i;
        begin
            cw  = place_data(d);
            syn = syndrome_of(cw);      // parity slots are 0: syn = parities
            for (i = 0; i < 6; i = i + 1)
                cw[(1 << i)] = syn[i];
            encode = {^cw, cw};         // [38] overall parity, [37:0] cw
        end
    endfunction

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------
    reg [38:0] mem [0:31];

    wire [4:0] idx = adr_i[6:2];

    // ------------------------------------------------------------------------
    // Decode + correct the addressed word (combinational)
    // ------------------------------------------------------------------------
    wire [38:0] raw     = mem[idx];
    wire [38:1] cw_raw  = raw[37:0];
    wire [5:0]  syn     = syndrome_of(cw_raw);
    wire        ovr_bad = (^cw_raw) ^ raw[38];

    // syndrome!=0 & overall wrong  -> single-bit, position = syn, fixable
    // syndrome==0 & overall wrong  -> the overall parity bit itself flipped
    // syndrome!=0 & overall fine   -> double-bit, NOT fixable
    // syn > 38 with overall wrong  -> impossible position: treat as uncorr
    wire correct_cw   = (syn != 6'd0) &  ovr_bad & (syn <= 6'd38);
    wire correct_ovr  = (syn == 6'd0) &  ovr_bad;
    wire uncorr       = ((syn != 6'd0) & ~ovr_bad) |
                        ( ovr_bad & (syn > 6'd38));
    wire had_corr     = correct_cw | correct_ovr;

    wire [38:1] cw_fixed = correct_cw ? (cw_raw ^ (38'b1 << (syn - 1)))
                                      : cw_raw;
    wire [38:0] fixed    = {^cw_fixed, cw_fixed};   // recomputed overall

    wire [37:0] gathered = gather_data_ext(cw_fixed);
    wire [31:0] rd_data  = gathered[31:0];

    // ------------------------------------------------------------------------
    // Bus transaction
    // ------------------------------------------------------------------------
    wire        full_wr  = &sel_i;
    wire [31:0] merged   = {sel_i[3] ? dat_i[31:24] : rd_data[31:24],
                            sel_i[2] ? dat_i[23:16] : rd_data[23:16],
                            sel_i[1] ? dat_i[15:8]  : rd_data[15:8],
                            sel_i[0] ? dat_i[7:0]   : rd_data[7:0]};

    wire do_write = cyc_i & we_i;
    wire do_read  = cyc_i & ~we_i;
    wire do_scrub = do_read & had_corr;

    always @(posedge clk) begin
        if (do_write)      mem[idx] <= encode(full_wr ? dat_i : merged);
        else if (do_scrub) mem[idx] <= fixed;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            evt_corr_o   <= 1'b0;
            evt_uncorr_o <= 1'b0;
        end else begin
            // scrub/rewrite removes the error, so these pulse exactly once
            // even while the master holds cyc across two cycles
            evt_corr_o   <= cyc_i & had_corr;
            evt_uncorr_o <= cyc_i & uncorr;
        end
    end

    assign rdt_o = rd_data;
    assign ack_o = cyc_i;

endmodule

`default_nettype wire
