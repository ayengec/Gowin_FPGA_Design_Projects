/*
 * Project   : macos_tft18_spi_dht22
 * File      : ui_page_control.sv
 * Summary   : Handles button-based page navigation, DHT start pulses, and UI timer.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Notes:
 * - S1 is mapped to next page, S2 to previous page.
 * - Page changes are applied on frame boundary to avoid mid-frame tearing.
 * - DHT start pulse is generated on rising edge of dht_ready while DHT page is active.
 */
module ui_page_control #(
    parameter int         CLK_HZ        = 27_000_000,
    parameter int         PATTERN_COUNT = 7,
    parameter logic [2:0] DHT_PAGE_IDX  = 3'd6
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       btn_next_evt,
    input  logic       btn_prev_evt,
    input  logic       frame_boundary,
    input  logic       dht_ready,

    output logic [2:0] pattern_idx,
    output logic       dht_start,
    output logic [3:0] ui_sec_tens,
    output logic [3:0] ui_sec_ones
);
    localparam int SEC_DIV_W = (CLK_HZ > 1) ? $clog2(CLK_HZ) : 1;
    localparam logic [2:0] LAST_PATTERN = PATTERN_COUNT[2:0] - 3'd1;

    logic       step_pending;
    logic       step_prev;
    logic       dht_ready_d;
    logic [SEC_DIV_W-1:0] ui_sec_div;
    logic [6:0]           ui_sec_count;

    assign ui_sec_tens = ui_sec_count / 10;
    assign ui_sec_ones = ui_sec_count % 10;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pattern_idx   <= 3'd0;
            dht_start     <= 1'b0;
            step_pending  <= 1'b0;
            step_prev     <= 1'b0;
            dht_ready_d   <= 1'b0;
            ui_sec_div    <= '0;
            ui_sec_count  <= '0;
        end else begin
            dht_start <= 1'b0;

            if (btn_next_evt) begin
                step_pending <= 1'b1;
                step_prev    <= 1'b0;
            end else if (btn_prev_evt) begin
                step_pending <= 1'b1;
                step_prev    <= 1'b1;
            end

            if (frame_boundary && step_pending) begin
                if (step_prev) begin
                    if (pattern_idx == 3'd0)
                        pattern_idx <= LAST_PATTERN;
                    else
                        pattern_idx <= pattern_idx - 1'b1;
                end else begin
                    if (pattern_idx == LAST_PATTERN)
                        pattern_idx <= 3'd0;
                    else
                        pattern_idx <= pattern_idx + 1'b1;
                end
                step_pending <= 1'b0;
            end

            if (pattern_idx != DHT_PAGE_IDX) begin
                dht_ready_d  <= 1'b0;
                ui_sec_div   <= '0;
                ui_sec_count <= '0;
            end else begin
                if (dht_ready && !dht_ready_d)
                    dht_start <= 1'b1;
                dht_ready_d <= dht_ready;

                if (ui_sec_div == CLK_HZ - 1) begin
                    ui_sec_div <= '0;
                    if (ui_sec_count == 7'd99)
                        ui_sec_count <= 7'd0;
                    else
                        ui_sec_count <= ui_sec_count + 1'b1;
                end else begin
                    ui_sec_div <= ui_sec_div + 1'b1;
                end
            end
        end
    end
endmodule
