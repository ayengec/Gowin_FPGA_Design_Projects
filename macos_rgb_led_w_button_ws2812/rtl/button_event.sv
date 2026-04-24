/*
 * Project   : macOS RGB LED With Button WS2812
 * File      : button_event.sv
 * Summary   : Debounce + one-shot event generator for active-low push buttons.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-24
 */
module button_event #(
    parameter int CLK_HZ          = 27_000_000,
    parameter int DEBOUNCE_TIME_MS = 20
) (
    input  logic clk,
    input  logic rst_n,
    input  logic btn_n,
    output logic press_pulse
);
    localparam int DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_TIME_MS;
    localparam int CNTR_W          = (DEBOUNCE_CYCLES > 1) ? $clog2(DEBOUNCE_CYCLES + 1) : 1;

    logic sync0;
    logic sync1;
    logic stable_btn;
    logic prev_btn;
    logic [CNTR_W-1:0] debounce_cnt;

    // 2-FF synchronizer for metastability protection.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0 <= 1'b1;
            sync1 <= 1'b1;
        end else begin
            sync0 <= btn_n;
            sync1 <= sync0;
        end
    end

    // Debounce filter: update stable button only after input keeps same value
    // for DEBOUNCE_CYCLES clock cycles.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable_btn    <= 1'b1;
            prev_btn      <= 1'b1;
            debounce_cnt  <= '0;
            press_pulse   <= 1'b0;
        end else begin
            press_pulse <= 1'b0;

            if (sync1 == stable_btn) begin
                debounce_cnt <= '0;
            end else begin
                if (debounce_cnt == DEBOUNCE_CYCLES - 1) begin
                    stable_btn   <= sync1;
                    debounce_cnt <= '0;
                end else begin
                    debounce_cnt <= debounce_cnt + 1'b1;
                end
            end

            // Active-low button press edge: 1 -> 0
            prev_btn <= stable_btn;
            if (prev_btn && !stable_btn)
                press_pulse <= 1'b1;
        end
    end
endmodule
