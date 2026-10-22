`default_nettype none

// STAGE 1: the core on its own.
//   - no input synchronizers (stage 2)
//   - no program loader (stage 3): the testbench preloads memory from uart_tx.hex
//
// Pins:  ui_in[7:0] = input pins 0-7     uio_in[7:0] = input pins 8-15
//        uo_out[7:0] = output pins 0-7
//
// Timing: every instruction takes 1 clock, except
//         DELAY n -> n+1 clocks       WAIT -> stalls until its pin condition holds

module tt_um_pin_core (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
    localparam DEPTH_LOG2 = 6;                 // 64 words of program memory
    localparam DEPTH      = 1 << DEPTH_LOG2;

    // opcodes (top 4 bits of each 16-bit instruction)
    localparam [3:0] OP_NOP = 4'h0, OP_SET  = 4'h1, OP_OUT  = 4'h2, OP_IN  = 4'h3,
                     OP_PULL= 4'h4, OP_PUSH = 4'h5, OP_DELAY= 4'h6, OP_LDX = 4'h7,
                     OP_LDY = 4'h8, OP_WAIT = 4'h9, OP_JMP  = 4'hA;

    // ---- program memory (simulation only for now: filled from a hex file)
    reg [15:0] imem [0:DEPTH-1];
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) imem[i] = 16'h0000;   // unused words = NOP
        $readmemh("uart_tx.hex", imem);
    end

    // ---- state
    reg [DEPTH_LOG2-1:0] pc;          // which instruction runs this clock
    reg [7:0] sr;                     // shift register (data in flight)
    reg [7:0] x, y;                   // loop counters
    reg [7:0] out_reg;                // drives uo_out
    reg       dly_active;             // a DELAY is in progress
    reg [7:0] dly_cnt;                // clocks left in that DELAY

    wire [15:0] pins  = {uio_in, ui_in};          // all 16 input pins
    wire [15:0] instr = imem[pc];                 // fetch (combinational: no wait states)
    wire [3:0]  op    = instr[15:12];

    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= 0;  sr <= 0;  x <= 0;  y <= 0;
            out_reg    <= 8'hFF;      // all pins idle high
            dly_active <= 0;  dly_cnt <= 0;
        end else begin
            pc <= pc + 1'b1;          // default: go to the next instruction
            case (op)
                OP_SET: out_reg[instr[2:0]] <= instr[3];

                OP_OUT: begin         // instr[3]: 0 = LSB first, 1 = MSB first
                    out_reg[instr[2:0]] <= instr[3] ? sr[7] : sr[0];
                    sr <= instr[3] ? {sr[6:0], 1'b0} : {1'b0, sr[7:1]};
                end

                OP_IN: sr <= instr[4] ? {sr[6:0], pins[instr[3:0]]}
                                      : {pins[instr[3:0]], sr[7:1]};

                OP_PULL: sr      <= ui_in;
                OP_PUSH: out_reg <= sr;

                OP_DELAY: begin       // stay on this instruction until the count runs out
                    if (!dly_active) begin
                        if (instr[7:0] != 0) begin
                            dly_active <= 1;
                            dly_cnt    <= instr[7:0];
                            pc         <= pc;           // stall
                        end
                    end else if (dly_cnt == 1) begin
                        dly_active <= 0;                // last stall clock: pc advances
                    end else begin
                        dly_cnt <= dly_cnt - 1;
                        pc      <= pc;                  // stall
                    end
                end

                OP_LDX: x <= instr[7:0];
                OP_LDY: y <= instr[7:0];

                OP_WAIT: if (pins[instr[3:0]] != instr[4]) pc <= pc;   // stall until match

                OP_JMP: case (instr[11:10])
                    2'd0: pc <= instr[5:0];                                         // always
                    2'd1: begin if (x != 0) pc <= instr[5:0]; x <= x - 1; end      // X--
                    2'd2: begin if (y != 0) pc <= instr[5:0]; y <= y - 1; end      // Y--
                    2'd3: if (pins[instr[9:6]]) pc <= instr[5:0];                   // pin high
                endcase

                default: ;            // NOP and unused opcodes do nothing
            endcase
        end
    end

    assign uo_out  = out_reg;
    assign uio_out = 8'd0;
    assign uio_oe  = 8'd0;
    wire _unused = &{ena, 1'b0};
endmodule
