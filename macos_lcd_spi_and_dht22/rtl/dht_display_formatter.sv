/*
 * Project   : macos_tft18_spi_dht22
 * File      : dht_display_formatter.sv
 * Summary   : Latches DHT22 results and formats them into display digits.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Notes:
 * - Keeps last valid sample visible on screen.
 * - Latches error flag when a completed transaction fails.
 * - Integer part is clamped to 99 for compact 2-digit rendering.
 */
module dht_display_formatter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        dht_done,
    input  logic        dht_valid,
    input  logic        dht_crc_ok,
    input  logic [15:0] dht_hum_x10,
    input  logic [15:0] dht_temp_x10,
    input  logic        dht_temp_neg_raw,

    output logic        dht_has_data,
    output logic        dht_error_latched,
    output logic        temp_neg_disp,
    output logic [3:0]  temp_tens,
    output logic [3:0]  temp_ones,
    output logic [3:0]  temp_dec,
    output logic [3:0]  hum_tens,
    output logic [3:0]  hum_ones,
    output logic [3:0]  hum_dec
);
    logic [15:0] hum_int_calc;
    logic [15:0] temp_int_calc;
    logic [7:0]  hum_int_clamped;
    logic [7:0]  temp_int_clamped;
    logic [3:0]  hum_tens_calc;
    logic [3:0]  hum_ones_calc;
    logic [3:0]  temp_tens_calc;
    logic [3:0]  temp_ones_calc;
    logic [3:0]  hum_dec_calc;
    logic [3:0]  temp_dec_calc;

    assign hum_int_calc     = dht_hum_x10 / 10;
    assign temp_int_calc    = dht_temp_x10 / 10;
    assign hum_int_clamped  = (hum_int_calc > 16'd99) ? 8'd99 : hum_int_calc[7:0];
    assign temp_int_clamped = (temp_int_calc > 16'd99) ? 8'd99 : temp_int_calc[7:0];
    assign hum_tens_calc    = hum_int_clamped / 10;
    assign hum_ones_calc    = hum_int_clamped % 10;
    assign temp_tens_calc   = temp_int_clamped / 10;
    assign temp_ones_calc   = temp_int_clamped % 10;
    assign hum_dec_calc     = dht_hum_x10 % 10;
    assign temp_dec_calc    = dht_temp_x10 % 10;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dht_has_data      <= 1'b0;
            dht_error_latched <= 1'b0;
            temp_neg_disp     <= 1'b0;
            temp_tens         <= 4'd0;
            temp_ones         <= 4'd0;
            temp_dec          <= 4'd0;
            hum_tens          <= 4'd0;
            hum_ones          <= 4'd0;
            hum_dec           <= 4'd0;
        end else if (dht_done) begin
            if (dht_valid && dht_crc_ok) begin
                dht_has_data      <= 1'b1;
                dht_error_latched <= 1'b0;
                temp_neg_disp     <= dht_temp_neg_raw;
                temp_tens         <= temp_tens_calc;
                temp_ones         <= temp_ones_calc;
                temp_dec          <= temp_dec_calc;
                hum_tens          <= hum_tens_calc;
                hum_ones          <= hum_ones_calc;
                hum_dec           <= hum_dec_calc;
            end else begin
                dht_error_latched <= 1'b1;
            end
        end
    end
endmodule
