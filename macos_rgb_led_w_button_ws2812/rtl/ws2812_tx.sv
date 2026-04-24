/*
 * Project   : macOS RGB LED With Button WS2812
 * File      : ws2812_tx.sv
 * Summary   : Single-pixel WS2812 transmitter (GRB, MSB-first, one-wire timing).
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-24
 *
 * Timing (for 27 MHz clock):
 * - Bit cell  : 34 cycles  (~1.26 us)
 * - '0' high  : 11 cycles  (~0.41 us)
 * - '1' high  : 22 cycles  (~0.81 us)
 * - Reset low : 2200 cycles (~81 us) > 50 us latch requirement
 */
module ws2812_tx #(
    parameter int T0H_CYCLES   = 11,
    parameter int T1H_CYCLES   = 22,
    parameter int BIT_CYCLES   = 34,
    parameter int RESET_CYCLES = 2200
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,
    input  logic [23:0] color_grb,
    output logic       ws2812,
    output logic       busy,
    output logic       done_pulse
);
    typedef enum logic [1:0] {
        ST_IDLE  = 2'd0,
        ST_SEND  = 2'd1,
        ST_RESET = 2'd2
    } state_t;

    state_t state;

    logic [23:0] shreg;
    logic [4:0]  bit_idx;
    logic [11:0] cycle_cnt;
    logic [11:0] reset_cnt;

    localparam logic [11:0] T0H_VAL = T0H_CYCLES;
    localparam logic [11:0] T1H_VAL = T1H_CYCLES;

    wire current_bit = shreg[23];
    wire [11:0] high_cycles = current_bit ? T1H_VAL : T0H_VAL;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            shreg       <= 24'h000000;
            bit_idx     <= '0;
            cycle_cnt   <= '0;
            reset_cnt   <= '0;
            ws2812      <= 1'b0;
            busy        <= 1'b0;
            done_pulse  <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            case (state)
                ST_IDLE: begin
                    ws2812    <= 1'b0;
                    busy      <= 1'b0;
                    cycle_cnt <= '0;
                    reset_cnt <= '0;

                    if (start) begin
                        busy      <= 1'b1;
                        shreg     <= color_grb;
                        bit_idx   <= 5'd0;
                        cycle_cnt <= '0;
                        state     <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    // Pulse width encoding inside one bit cell.
                    ws2812 <= (cycle_cnt < high_cycles);

                    if (cycle_cnt == BIT_CYCLES - 1) begin
                        cycle_cnt <= '0;
                        shreg     <= {shreg[22:0], 1'b0};

                        if (bit_idx == 5'd23) begin
                            bit_idx   <= '0;
                            reset_cnt <= '0;
                            state     <= ST_RESET;
                            ws2812    <= 1'b0;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt + 1'b1;
                    end
                end

                default: begin // ST_RESET
                    ws2812 <= 1'b0;
                    if (reset_cnt == RESET_CYCLES - 1) begin
                        reset_cnt  <= '0;
                        busy       <= 1'b0;
                        done_pulse <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        reset_cnt <= reset_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
