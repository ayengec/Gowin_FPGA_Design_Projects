/*
 * Project   : macos_i2c_rtc_uart
 * File      : uart_tx.sv
 * Summary   : UART transmitter (8N1), one byte per start pulse.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-26
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
    // One UART bit period in system clock cycles.
    localparam int BAUD_DIV = CLK_HZ / BAUDRATE;

    logic [$clog2(BAUD_DIV)-1:0] baud_cnt;
    logic [3:0]                  bit_cnt;
    logic [9:0]                  shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx       <= 1'b1;
            busy     <= 1'b0;
            baud_cnt <= '0;
            bit_cnt  <= '0;
            shreg    <= 10'h3FF;
        end else begin
            if (!busy) begin
                if (start) begin
                    // Frame = stop(1), data[7:0], start(0)
                    shreg    <= {1'b1, data, 1'b0};
                    tx       <= 1'b0;
                    busy     <= 1'b1;
                    baud_cnt <= '0;
                    bit_cnt  <= 4'd0;
                end
            end else begin
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= '0;
                    bit_cnt  <= bit_cnt + 1'b1;
                    shreg    <= {1'b1, shreg[9:1]};
                    tx       <= shreg[1];

                    if (bit_cnt == 4'd9) begin
                        busy <= 1'b0;
                        tx   <= 1'b1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end
        end
    end
endmodule
