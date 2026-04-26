/*
 * Project   : macos_i2c_rtc_uart
 * File      : uart_rx.sv
 * Summary   : UART receiver (8N1), emits one-cycle valid pulse per byte.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-26
 */
module uart_rx #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int BAUDRATE = 115200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid
);
    localparam int BAUD_DIV      = CLK_HZ / BAUDRATE;
    localparam int HALF_BAUD_DIV = BAUD_DIV / 2;

    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t state;

    logic [$clog2(BAUD_DIV)-1:0] baud_cnt;
    logic [2:0]                  bit_cnt;
    logic [7:0]                  shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= RX_IDLE;
            baud_cnt <= '0;
            bit_cnt  <= '0;
            shreg    <= '0;
            data     <= '0;
            valid    <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (state)
                RX_IDLE: begin
                    baud_cnt <= '0;
                    bit_cnt  <= '0;
                    if (!rx)
                        state <= RX_START;
                end

                RX_START: begin
                    if (baud_cnt == HALF_BAUD_DIV - 1) begin
                        baud_cnt <= '0;
                        if (!rx)
                            state <= RX_DATA;
                        else
                            state <= RX_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                RX_DATA: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt       <= '0;
                        shreg[bit_cnt] <= rx;

                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= '0;
                            state   <= RX_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                RX_STOP: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= '0;
                        state    <= RX_IDLE;

                        if (rx) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: state <= RX_IDLE;
            endcase
        end
    end
endmodule
