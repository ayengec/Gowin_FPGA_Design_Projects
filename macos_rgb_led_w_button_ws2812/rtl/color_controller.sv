/*
 * Project   : macOS RGB LED With Button WS2812
 * File      : color_controller.sv
 * Summary   : Button-driven color/brightness controller for one WS2812 LED.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-24
 */
module color_controller #(
    parameter int CLK_HZ = 27_000_000
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       ev_next_color,
    input  logic       ev_prev_color,
    input  logic       ev_brightness,
    input  logic       ev_auto_toggle,

    output logic [23:0] color_grb,
    output logic [3:0]  palette_idx,
    output logic [1:0]  brightness_lvl,
    output logic        auto_mode
);
    localparam int PALETTE_SIZE = 12;

    // Auto mode interval: 500 ms
    localparam int AUTO_STEP_CYCLES = CLK_HZ / 2;
    localparam int AUTO_CNT_W       = (AUTO_STEP_CYCLES > 1) ? $clog2(AUTO_STEP_CYCLES) : 1;

    logic [AUTO_CNT_W-1:0] auto_cnt;
    logic                  auto_tick;

    // Palette in RGB888 (human-readable order). We later output GRB for WS2812.
    function automatic logic [23:0] palette_rgb(input logic [3:0] idx);
        case (idx)
            4'd0:  palette_rgb = 24'hFF0000; // red
            4'd1:  palette_rgb = 24'h00FF00; // green
            4'd2:  palette_rgb = 24'h0000FF; // blue
            4'd3:  palette_rgb = 24'hFFFF00; // yellow
            4'd4:  palette_rgb = 24'hFF00FF; // magenta
            4'd5:  palette_rgb = 24'h00FFFF; // cyan
            4'd6:  palette_rgb = 24'hFFFFFF; // white
            4'd7:  palette_rgb = 24'hFF7F00; // orange
            4'd8:  palette_rgb = 24'h7F00FF; // violet
            4'd9:  palette_rgb = 24'h00FF7F; // spring green
            4'd10: palette_rgb = 24'hFF1493; // deep pink
            default: palette_rgb = 24'h202020; // soft gray
        endcase
    endfunction

    // Brightness level encoding:
    // 0 => 12.5%, 1 => 25%, 2 => 50%, 3 => 100%
    function automatic logic [7:0] apply_brightness(
        input logic [7:0] chan,
        input logic [1:0] lvl
    );
        case (lvl)
            2'd0: apply_brightness = chan >> 3;
            2'd1: apply_brightness = chan >> 2;
            2'd2: apply_brightness = chan >> 1;
            default: apply_brightness = chan;
        endcase
    endfunction

    logic [23:0] rgb_now;
    logic [7:0]  r_scaled;
    logic [7:0]  g_scaled;
    logic [7:0]  b_scaled;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            palette_idx     <= 4'd0;
            brightness_lvl  <= 2'd2; // start at 50%
            auto_mode       <= 1'b0;
            auto_cnt        <= '0;
            auto_tick       <= 1'b0;
        end else begin
            auto_tick <= 1'b0;

            if (auto_mode) begin
                if (auto_cnt == AUTO_STEP_CYCLES - 1) begin
                    auto_cnt  <= '0;
                    auto_tick <= 1'b1;
                end else begin
                    auto_cnt <= auto_cnt + 1'b1;
                end
            end else begin
                auto_cnt <= '0;
            end

            // BTN4: toggle auto color walk mode.
            if (ev_auto_toggle)
                auto_mode <= ~auto_mode;

            // BTN3: cycle brightness levels.
            if (ev_brightness)
                brightness_lvl <= brightness_lvl + 1'b1;

            // Manual color selection.
            if (ev_next_color || auto_tick) begin
                if (palette_idx == PALETTE_SIZE - 1)
                    palette_idx <= 4'd0;
                else
                    palette_idx <= palette_idx + 1'b1;
            end

            if (ev_prev_color) begin
                if (palette_idx == 4'd0)
                    palette_idx <= PALETTE_SIZE - 1;
                else
                    palette_idx <= palette_idx - 1'b1;
            end
        end
    end

    always_comb begin
        rgb_now   = palette_rgb(palette_idx);
        r_scaled  = apply_brightness(rgb_now[23:16], brightness_lvl);
        g_scaled  = apply_brightness(rgb_now[15:8],  brightness_lvl);
        b_scaled  = apply_brightness(rgb_now[7:0],   brightness_lvl);

        // WS2812 expects GRB byte order.
        color_grb = {g_scaled, r_scaled, b_scaled};
    end
endmodule
