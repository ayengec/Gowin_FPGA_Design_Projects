/*
 * Project   : Tang Primer 20K LED Chaser Smoke Test
 * File      : uart_tx.sv
 * Summary   : Compact UART transmitter (8N1) with start-strobe interface.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated
 */
module uart_tx #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int BAUDRATE = 115200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       start,
    input  logic [7:0] data,
    output logic       tx,
    output logic       busy
);
    localparam int CLKS_PER_BIT = CLK_HZ / BAUDRATE;
    localparam int CLK_CNT_W    = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    typedef enum logic [1:0] {
        ST_IDLE  = 2'd0,
        ST_START = 2'd1,
        ST_DATA  = 2'd2,
        ST_STOP  = 2'd3
    } tx_state_t;

    tx_state_t state;
    logic [CLK_CNT_W-1:0] clk_cnt;
    logic [2:0]           bit_idx;
    logic [7:0]           shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            state   <= ST_IDLE;
            clk_cnt <= '0;
            bit_idx <= '0;
            shreg   <= 8'h00;
            tx      <= 1'b1;
            busy    <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    tx      <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= '0;
                    bit_idx <= '0;

                    if (start) begin
                        shreg <= data;
                        busy  <= 1'b1;
                        state <= ST_START;
                    end
                end

                ST_START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        state   <= ST_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                ST_DATA: begin
                    tx <= shreg[0];
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        shreg   <= {1'b0, shreg[7:1]};

                        if (bit_idx == 3'd7) begin
                            bit_idx <= '0;
                            state   <= ST_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= '0;
                        busy    <= 1'b0;
                        state   <= ST_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
