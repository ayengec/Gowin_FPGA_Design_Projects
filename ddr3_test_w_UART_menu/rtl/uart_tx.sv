/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : uart_tx.sv
 * Summary   : UART transmitter (8N1), one byte per start pulse.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated
 *
 * Frame format (8N1):
 * - 1 start bit (0)
 * - 8 data bits, LSB first
 * - 1 stop bit (1)
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
    // Number of system clock cycles for one UART bit period.
    // For this project we keep it simple with integer divide.
    localparam int BAUD_DIV = CLK_HZ / BAUDRATE;

    // `baud_cnt` waits one full bit time between shifts.
    // `bit_cnt` tracks transmitted frame bits (0..9).
    // `shreg` stores full frame including start/stop bits.
    logic [$clog2(BAUD_DIV)-1:0] baud_cnt;
    logic [3:0]                  bit_cnt;
    logic [9:0]                  shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            // UART idle line level is logic 1.
            tx       <= 1'b1;
            busy     <= 1'b0;
            baud_cnt <= '0;
            bit_cnt  <= '0;
            shreg    <= 10'h3FF;
        end else begin
            if (!busy) begin
                // Idle path: wait for a one-cycle `start` strobe.
                if (start) begin
                    // Build full frame once, then shift it out bit-by-bit.
                    // Ordering below makes shreg[0] the start bit.
                    shreg    <= {1'b1, data, 1'b0};
                    tx       <= 1'b0;
                    busy     <= 1'b1;
                    baud_cnt <= '0;
                    bit_cnt  <= 4'd0;
                end
            end else begin
                // Active transmit path:
                // every BAUD_DIV cycles we move to next frame bit.
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= '0;
                    bit_cnt  <= bit_cnt + 1'b1;
                    shreg    <= {1'b1, shreg[9:1]};
                    tx       <= shreg[1];

                    if (bit_cnt == 4'd9) begin
                        // End of frame after start + 8 data + stop.
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
