`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    reg [1:0] state;
    reg [3:0] count;

    reg red;
    reg yellow;
    reg green;

    parameter RED_STATE    = 2'b00;
    parameter GREEN_STATE  = 2'b01;
    parameter YELLOW_STATE = 2'b10;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= RED_STATE;
            count <= 0;
        end else begin
            count <= count + 1;

            case (state)
                RED_STATE: begin
                    if (count == 4) begin
                        state <= GREEN_STATE;
                        count <= 0;
                    end
                end

                GREEN_STATE: begin
                    if (count == 4) begin
                        state <= YELLOW_STATE;
                        count <= 0;
                    end
                end

                YELLOW_STATE: begin
                    if (count == 2) begin
                        state <= RED_STATE;
                        count <= 0;
                    end
                end

                default: begin
                    state <= RED_STATE;
                    count <= 0;
                end
            endcase
        end
    end

    always @(*) begin
        red = 0;
        yellow = 0;
        green = 0;

        case (state)
            RED_STATE: red = 1;
            GREEN_STATE: green = 1;
            YELLOW_STATE: yellow = 1;
            default: red = 1;
        endcase
    end

    assign uo_out[0] = red;
    assign uo_out[1] = yellow;
    assign uo_out[2] = green;
    assign uo_out[7:3] = 5'b00000;

    assign uio_out = 8'b00000000;
    assign uio_oe  = 8'b00000000;

    wire _unused = &{ena, ui_in, uio_in, 1'b0};

endmodule
