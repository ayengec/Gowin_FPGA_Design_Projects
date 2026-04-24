/*
 * Project   : macOS RGB LED With Button WS2812
 * File      : top_ws2812_button_color.sv
 * Summary   : 4-button control of onboard WS2812 RGB LED (color + brightness + auto mode).
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-24
 *
 * Button map (active-low):
 * - BTN1 (T3): next color
 * - BTN2 (T2): previous color
 * - BTN3 (D7): brightness step (12.5% -> 25% -> 50% -> 100%)
 * - BTN4 (C7): auto color walk on/off
 *
 * Reset policy:
 * - Internal power-on reset is generated in this module.
 */
module top_ws2812_button_color #(
    parameter int CLK_HZ = 27_000_000
) (
    input  logic       clk_27m,

    input  logic       btn_next_n,
    input  logic       btn_prev_n,
    input  logic       btn_bright_n,
    input  logic       btn_auto_n,

    output logic       ws2812_dout,
    output logic [3:0] led
);
    // Internal power-on reset to avoid using dedicated external pins.
    logic        rst_n   = 1'b0;
    logic [15:0] por_cnt = '0;

    always_ff @(posedge clk_27m) begin
        if (!por_cnt[15]) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    logic ev_next;
    logic ev_prev;
    logic ev_bright;
    logic ev_auto;

    button_event #(.CLK_HZ(CLK_HZ)) u_btn_next (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_next_n),
        .press_pulse(ev_next)
    );

    button_event #(.CLK_HZ(CLK_HZ)) u_btn_prev (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_prev_n),
        .press_pulse(ev_prev)
    );

    button_event #(.CLK_HZ(CLK_HZ)) u_btn_bright (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_bright_n),
        .press_pulse(ev_bright)
    );

    button_event #(.CLK_HZ(CLK_HZ)) u_btn_auto (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_auto_n),
        .press_pulse(ev_auto)
    );

    logic [23:0] color_grb;
    logic [3:0]  palette_idx;
    logic [1:0]  brightness_lvl;
    logic        auto_mode;

    color_controller #(.CLK_HZ(CLK_HZ)) u_color (
        .clk           (clk_27m),
        .rst_n         (rst_n),
        .ev_next_color (ev_next),
        .ev_prev_color (ev_prev),
        .ev_brightness (ev_bright),
        .ev_auto_toggle(ev_auto),
        .color_grb     (color_grb),
        .palette_idx   (palette_idx),
        .brightness_lvl(brightness_lvl),
        .auto_mode     (auto_mode)
    );

    // Refresh the LED continuously so color changes are applied quickly.
    localparam int REFRESH_CYCLES = CLK_HZ / 400; // ~2.5 ms
    localparam int REF_CNT_W      = (REFRESH_CYCLES > 1) ? $clog2(REFRESH_CYCLES) : 1;

    logic [REF_CNT_W-1:0] refresh_cnt;
    logic                 refresh_tick;

    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt  <= '0;
            refresh_tick <= 1'b0;
        end else begin
            refresh_tick <= 1'b0;
            if (refresh_cnt == REFRESH_CYCLES - 1) begin
                refresh_cnt  <= '0;
                refresh_tick <= 1'b1;
            end else begin
                refresh_cnt <= refresh_cnt + 1'b1;
            end
        end
    end

    logic ws_start;
    logic ws_busy;
    logic ws_done;

    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            ws_start <= 1'b0;
        end else begin
            ws_start <= 1'b0;
            if (refresh_tick && !ws_busy)
                ws_start <= 1'b1;
        end
    end

    ws2812_tx u_ws2812 (
        .clk      (clk_27m),
        .rst_n    (rst_n),
        .start    (ws_start),
        .color_grb(color_grb),
        .ws2812   (ws2812_dout),
        .busy     (ws_busy),
        .done_pulse(ws_done)
    );

    // Status LEDs for quick visual debugging:
    // led0: blink on each completed WS2812 frame
    // led1: auto mode
    // led2..3: brightness level
    logic led0_tog;

    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n)
            led0_tog <= 1'b0;
        else if (ws_done)
            led0_tog <= ~led0_tog;
    end

    assign led[0] = led0_tog;
    assign led[1] = auto_mode;
    assign led[2] = brightness_lvl[0];
    assign led[3] = brightness_lvl[1];
endmodule
