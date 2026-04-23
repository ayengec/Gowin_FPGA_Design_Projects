/*
 * Project   : Tang Primer 20K LED Chaser Smoke Test
 * File      : top_led_chaser.sv
 * Summary   : Minimal build/program sanity design. Runs a 4-LED Knight Rider pattern.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-24
 *
 * Notes:
 * - Uses only board 27 MHz clock + 4 user LEDs.
 * - No external reset pin is required for this quick smoke test.
 */
module top_led_chaser #(
    parameter int CLK_HZ  = 27_000_000,
    parameter int STEP_MS = 100
) (
    input  logic       clk_27m,
    output logic [3:0] led
);
    localparam int STEP_CYCLES = (CLK_HZ / 1000) * STEP_MS;
    localparam int CNT_W       = (STEP_CYCLES > 1) ? $clog2(STEP_CYCLES) : 1;

    logic [CNT_W-1:0] step_cnt = '0;
    logic [1:0]       pos      = 2'd0;
    logic             dir      = 1'b0; // 0: move right, 1: move left

    // Visible speed divider and position update.
    always_ff @(posedge clk_27m) begin
        if (step_cnt == STEP_CYCLES - 1) begin
            step_cnt <= '0;

            if (!dir) begin
                if (pos == 2'd3) begin
                    pos <= 2'd2;
                    dir <= 1'b1;
                end else begin
                    pos <= pos + 1'b1;
                end
            end else begin
                if (pos == 2'd0) begin
                    pos <= 2'd1;
                    dir <= 1'b0;
                end else begin
                    pos <= pos - 1'b1;
                end
            end
        end else begin
            step_cnt <= step_cnt + 1'b1;
        end
    end

    // One-hot LED output.
    always_comb begin
        led = 4'b0000;
        led[pos] = 1'b1;
    end
endmodule
