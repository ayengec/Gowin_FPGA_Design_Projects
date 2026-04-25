/*
 * Project   : macos_tft18_spi_dht22
 * File      : spi_tx_byte.sv
 * Summary   : Small SPI mode-0 byte transmitter (MSB-first).
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Protocol behavior:
 * - CPOL=0, CPHA=0
 * - Data is driven on falling-side preparation and sampled by target on rising edge.
 */
module spi_tx_byte #(
    parameter int HALF_PERIOD_CLKS = 2
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    input  logic [7:0] data,

    output logic       busy,
    output logic       done_pulse,
    output logic       sclk,
    output logic       mosi
);
    localparam int HALF_CLKS = (HALF_PERIOD_CLKS > 0) ? HALF_PERIOD_CLKS : 1;
    localparam int DIV_W     = (HALF_CLKS > 1) ? $clog2(HALF_CLKS) : 1;

    logic [DIV_W-1:0] div_cnt;
    logic             phase_high;
    logic [7:0]       data_latched;
    logic [2:0]       bit_idx;

    wire tick = (div_cnt == HALF_CLKS - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            done_pulse   <= 1'b0;
            sclk         <= 1'b0;
            mosi         <= 1'b0;
            div_cnt      <= '0;
            phase_high   <= 1'b0;
            data_latched <= 8'h00;
            bit_idx      <= 3'd0;
        end else begin
            done_pulse <= 1'b0;

            if (!busy) begin
                // Idle bus state in mode-0 is SCLK low.
                sclk       <= 1'b0;
                phase_high <= 1'b0;
                div_cnt    <= '0;

                if (start) begin
                    // Latch input byte and present MSB first.
                    busy         <= 1'b1;
                    data_latched <= data;
                    bit_idx      <= 3'd7;
                    mosi         <= data[7];
                end
            end else begin
                if (tick) begin
                    div_cnt <= '0;

                    if (!phase_high) begin
                        // Rising edge: receiver samples current MOSI bit.
                        sclk       <= 1'b1;
                        phase_high <= 1'b1;
                    end else begin
                        // Falling edge: prepare next bit (or finish after bit0).
                        sclk       <= 1'b0;
                        phase_high <= 1'b0;

                        if (bit_idx == 3'd0) begin
                            busy       <= 1'b0;
                            done_pulse <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx - 1'b1;
                            mosi    <= data_latched[bit_idx - 1'b1];
                        end
                    end
                end else begin
                    div_cnt <= div_cnt + 1'b1;
                end
            end
        end
    end
endmodule
