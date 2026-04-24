/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : uart_rx.sv
 * Summary   : UART receiver (8N1), emits one-cycle valid pulse per byte.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-23
 *
 * Implementation style:
 * - No oversampling; we sample once per bit at expected bit center.
 * - This is lightweight and works well when baud clock error is modest.
 * - Start-bit mid-sample check filters short glitches on RX line.
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
    // Number of clock cycles per UART bit and half-bit sample point.
    // Integer division is acceptable here for a simple demo-grade UART.
    localparam int BAUD_DIV       = CLK_HZ / BAUDRATE;
    localparam int HALF_BAUD_DIV  = BAUD_DIV / 2;

    // RX state machine: detect start, sample 8 bits, verify stop.
    typedef enum logic [1:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t state;

    // `baud_cnt` tracks sub-bit timing.
    // `bit_cnt` tracks which payload bit we are sampling (LSB first).
    // `shreg` holds the byte under construction.
    logic [$clog2(BAUD_DIV)-1:0] baud_cnt;
    logic [2:0]                  bit_cnt;
    logic [7:0]                  shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset receiver into idle state.
            state    <= RX_IDLE;
            baud_cnt <= '0;
            bit_cnt  <= '0;
            shreg    <= '0;
            data     <= '0;
            valid    <= 1'b0;
        end else begin
            // `valid` is a one-clock pulse when a full byte is received.
            valid <= 1'b0;

            case (state)
                RX_IDLE: begin
                    // Wait for falling edge of start bit (line goes low).
                    // We do not consume data until start-bit confirmation.
                    baud_cnt <= '0;
                    bit_cnt  <= '0;
                    if (!rx) begin
                        state <= RX_START;
                    end
                end

                RX_START: begin
                    // Sample near center of start bit for better jitter immunity.
                    // If line bounced back high, treat it as false start.
                    if (baud_cnt == HALF_BAUD_DIV - 1) begin
                        baud_cnt <= '0;
                        if (!rx) begin
                            state <= RX_DATA;
                        end else begin
                            state <= RX_IDLE;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                RX_DATA: begin
                    // Sample each data bit at fixed BAUD_DIV interval.
                    // UART sends LSB first, so we store into shreg[bit_cnt].
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
                    // Stop bit should be high in 8N1 framing.
                    // If stop bit is valid, publish byte and pulse `valid`.
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
