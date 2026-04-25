/*
 * Project   : macos_tft18_spi_dht22
 * File      : tft_page_renderer.sv
 * Summary   : Pixel renderer for color patterns and DHT monitor page.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Notes:
 * - Renders all pages from (mode, x, y) inputs.
 * - Keeps rendering logic isolated from transport/control FSMs.
 */
module tft_page_renderer (
    input  logic [2:0] mode,
    input  logic [6:0] x,
    input  logic [7:0] y,
    input  logic       dht_busy_i,
    input  logic       dht_has_data_i,
    input  logic       dht_error_i,
    input  logic       temp_neg_i,
    input  logic [3:0] temp_tens_i,
    input  logic [3:0] temp_ones_i,
    input  logic [3:0] temp_dec_i,
    input  logic [3:0] hum_tens_i,
    input  logic [3:0] hum_ones_i,
    input  logic [3:0] hum_dec_i,
    input  logic [3:0] tmr_tens_i,
    input  logic [3:0] tmr_ones_i,
    output logic [15:0] pixel_color
);
    function automatic logic glyph_pixel_5x7(
        input logic [2:0] glyph_id,
        input logic [2:0] row,
        input logic [2:0] col
    );
        logic [4:0] row_bits;
        begin
            row_bits = 5'b00000;

            // Glyph set used by "AYENGEC" banner and corner label.
            case (glyph_id)
                3'd0: begin // A
                    case (row)
                        3'd0: row_bits = 5'b01110;
                        3'd1: row_bits = 5'b10001;
                        3'd2: row_bits = 5'b10001;
                        3'd3: row_bits = 5'b11111;
                        3'd4: row_bits = 5'b10001;
                        3'd5: row_bits = 5'b10001;
                        default: row_bits = 5'b10001;
                    endcase
                end
                3'd1: begin // Y
                    case (row)
                        3'd0: row_bits = 5'b10001;
                        3'd1: row_bits = 5'b10001;
                        3'd2: row_bits = 5'b01010;
                        default: row_bits = 5'b00100;
                    endcase
                end
                3'd2: begin // E
                    case (row)
                        3'd0: row_bits = 5'b11111;
                        3'd1: row_bits = 5'b10000;
                        3'd2: row_bits = 5'b10000;
                        3'd3: row_bits = 5'b11110;
                        3'd4: row_bits = 5'b10000;
                        3'd5: row_bits = 5'b10000;
                        default: row_bits = 5'b11111;
                    endcase
                end
                3'd3: begin // N
                    case (row)
                        3'd0: row_bits = 5'b10001;
                        3'd1: row_bits = 5'b11001;
                        3'd2: row_bits = 5'b10101;
                        3'd3: row_bits = 5'b10011;
                        3'd4: row_bits = 5'b10001;
                        3'd5: row_bits = 5'b10001;
                        default: row_bits = 5'b10001;
                    endcase
                end
                3'd4: begin // G
                    case (row)
                        3'd0: row_bits = 5'b01110;
                        3'd1: row_bits = 5'b10001;
                        3'd2: row_bits = 5'b10000;
                        3'd3: row_bits = 5'b10111;
                        3'd4: row_bits = 5'b10001;
                        3'd5: row_bits = 5'b10001;
                        default: row_bits = 5'b01110;
                    endcase
                end
                default: begin // C
                    case (row)
                        3'd0: row_bits = 5'b01110;
                        3'd1: row_bits = 5'b10001;
                        3'd2: row_bits = 5'b10000;
                        3'd3: row_bits = 5'b10000;
                        3'd4: row_bits = 5'b10000;
                        3'd5: row_bits = 5'b10001;
                        default: row_bits = 5'b01110;
                    endcase
                end
            endcase

            if (row > 3'd6 || col > 3'd4)
                glyph_pixel_5x7 = 1'b0;
            else
                glyph_pixel_5x7 = row_bits[4-col];
        end
    endfunction

    function automatic logic digit_pixel_5x7(
        input logic [3:0] digit_id,
        input logic [2:0] row,
        input logic [2:0] col
    );
        logic [4:0] row_bits;
        begin
            row_bits = 5'b00000;
            case (digit_id)
                4'd0: case (row)
                    3'd0: row_bits = 5'b01110; 3'd1: row_bits = 5'b10001; 3'd2: row_bits = 5'b10011; 3'd3: row_bits = 5'b10101;
                    3'd4: row_bits = 5'b11001; 3'd5: row_bits = 5'b10001; default: row_bits = 5'b01110;
                endcase
                4'd1: case (row)
                    3'd0: row_bits = 5'b00100; 3'd1: row_bits = 5'b01100; 3'd2: row_bits = 5'b00100; 3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b00100; 3'd5: row_bits = 5'b00100; default: row_bits = 5'b01110;
                endcase
                4'd2: case (row)
                    3'd0: row_bits = 5'b01110; 3'd1: row_bits = 5'b10001; 3'd2: row_bits = 5'b00001; 3'd3: row_bits = 5'b00010;
                    3'd4: row_bits = 5'b00100; 3'd5: row_bits = 5'b01000; default: row_bits = 5'b11111;
                endcase
                4'd3: case (row)
                    3'd0: row_bits = 5'b11110; 3'd1: row_bits = 5'b00001; 3'd2: row_bits = 5'b00001; 3'd3: row_bits = 5'b01110;
                    3'd4: row_bits = 5'b00001; 3'd5: row_bits = 5'b00001; default: row_bits = 5'b11110;
                endcase
                4'd4: case (row)
                    3'd0: row_bits = 5'b00010; 3'd1: row_bits = 5'b00110; 3'd2: row_bits = 5'b01010; 3'd3: row_bits = 5'b10010;
                    3'd4: row_bits = 5'b11111; 3'd5: row_bits = 5'b00010; default: row_bits = 5'b00010;
                endcase
                4'd5: case (row)
                    3'd0: row_bits = 5'b11111; 3'd1: row_bits = 5'b10000; 3'd2: row_bits = 5'b10000; 3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b00001; 3'd5: row_bits = 5'b00001; default: row_bits = 5'b11110;
                endcase
                4'd6: case (row)
                    3'd0: row_bits = 5'b01110; 3'd1: row_bits = 5'b10000; 3'd2: row_bits = 5'b10000; 3'd3: row_bits = 5'b11110;
                    3'd4: row_bits = 5'b10001; 3'd5: row_bits = 5'b10001; default: row_bits = 5'b01110;
                endcase
                4'd7: case (row)
                    3'd0: row_bits = 5'b11111; 3'd1: row_bits = 5'b00001; 3'd2: row_bits = 5'b00010; 3'd3: row_bits = 5'b00100;
                    3'd4: row_bits = 5'b01000; 3'd5: row_bits = 5'b01000; default: row_bits = 5'b01000;
                endcase
                4'd8: case (row)
                    3'd0: row_bits = 5'b01110; 3'd1: row_bits = 5'b10001; 3'd2: row_bits = 5'b10001; 3'd3: row_bits = 5'b01110;
                    3'd4: row_bits = 5'b10001; 3'd5: row_bits = 5'b10001; default: row_bits = 5'b01110;
                endcase
                4'd9: case (row)
                    3'd0: row_bits = 5'b01110; 3'd1: row_bits = 5'b10001; 3'd2: row_bits = 5'b10001; 3'd3: row_bits = 5'b01111;
                    3'd4: row_bits = 5'b00001; 3'd5: row_bits = 5'b00001; default: row_bits = 5'b01110;
                endcase
                default: case (row) // dash "-"
                    3'd3: row_bits = 5'b01110;
                    default: row_bits = 5'b00000;
                endcase
            endcase

            if (row > 3'd6 || col > 3'd4)
                digit_pixel_5x7 = 1'b0;
            else
                digit_pixel_5x7 = row_bits[4-col];
        end
    endfunction

    function automatic logic [15:0] pattern_color565(
        input logic [2:0] mode_i,
        input logic [6:0] x_i,
        input logic [7:0] y_i,
        input logic       dht_busy_i_f,
        input logic       dht_has_data_i_f,
        input logic       dht_error_i_f,
        input logic       temp_neg_i_f,
        input logic [3:0] temp_tens_i_f,
        input logic [3:0] temp_ones_i_f,
        input logic [3:0] temp_dec_i_f,
        input logic [3:0] hum_tens_i_f,
        input logic [3:0] hum_ones_i_f,
        input logic [3:0] hum_dec_i_f,
        input logic [3:0] tmr_tens_i_f,
        input logic [3:0] tmr_ones_i_f
    );
        logic [4:0] r;
        logic [5:0] g;
        logic [4:0] b;
        logic [6:0] local_x;
        logic [4:0] local_y;
        logic [2:0] row5x7;
        logic [2:0] col5x7;
        logic [2:0] glyph_id;
        logic [3:0] digit_id;
        logic [3:0] t_tens_disp;
        logic [3:0] t_ones_disp;
        logic [3:0] t_dec_disp;
        logic [3:0] h_tens_disp;
        logic [3:0] h_ones_disp;
        logic [3:0] h_dec_disp;
        logic       text_px;
        logic       pixel_on;
        begin
            case (mode_i)
                3'd0: pattern_color565 = 16'hF800; // solid RED
                3'd1: pattern_color565 = 16'h07E0; // solid GREEN
                3'd2: pattern_color565 = 16'h001F; // solid BLUE
                3'd3: begin
                    // 8 vertical color bars
                    case (x_i[6:4])
                        3'd0: pattern_color565 = 16'hF800;
                        3'd1: pattern_color565 = 16'hFD20;
                        3'd2: pattern_color565 = 16'hFFE0;
                        3'd3: pattern_color565 = 16'h07E0;
                        3'd4: pattern_color565 = 16'h07FF;
                        3'd5: pattern_color565 = 16'h001F;
                        3'd6: pattern_color565 = 16'hF81F;
                        default: pattern_color565 = 16'hFFFF;
                    endcase
                end
                3'd4: begin
                    // Simple 2D gradient using x/y bits
                    r = y_i[7:3];
                    g = x_i[6:1];
                    b = x_i[5:1];
                    pattern_color565 = {r, g, b};
                end
                3'd5: begin
                    // "AYENGEC" text mode.
                    text_px = 1'b0;
                    local_x = '0;
                    local_y = '0;
                    row5x7  = '0;
                    col5x7  = '0;
                    glyph_id = 3'd0;

                    if (y_i >= 8'd73 && y_i < 8'd87) begin
                        local_y = y_i - 8'd73;
                        row5x7  = local_y[4:1];

                        if (x_i >= 7'd23 && x_i < 7'd33) begin
                            local_x = x_i - 7'd23;  col5x7 = local_x[3:1]; glyph_id = 3'd0; text_px = 1'b1;
                        end else if (x_i >= 7'd35 && x_i < 7'd45) begin
                            local_x = x_i - 7'd35;  col5x7 = local_x[3:1]; glyph_id = 3'd1; text_px = 1'b1;
                        end else if (x_i >= 7'd47 && x_i < 7'd57) begin
                            local_x = x_i - 7'd47;  col5x7 = local_x[3:1]; glyph_id = 3'd2; text_px = 1'b1;
                        end else if (x_i >= 7'd59 && x_i < 7'd69) begin
                            local_x = x_i - 7'd59;  col5x7 = local_x[3:1]; glyph_id = 3'd3; text_px = 1'b1;
                        end else if (x_i >= 7'd71 && x_i < 7'd81) begin
                            local_x = x_i - 7'd71;  col5x7 = local_x[3:1]; glyph_id = 3'd4; text_px = 1'b1;
                        end else if (x_i >= 7'd83 && x_i < 7'd93) begin
                            local_x = x_i - 7'd83;  col5x7 = local_x[3:1]; glyph_id = 3'd2; text_px = 1'b1;
                        end else if (x_i >= 7'd95 && x_i < 7'd105) begin
                            local_x = x_i - 7'd95;  col5x7 = local_x[3:1]; glyph_id = 3'd5; text_px = 1'b1;
                        end
                    end

                    if (text_px && glyph_pixel_5x7(glyph_id, row5x7, col5x7))
                        pattern_color565 = 16'hFFE0;
                    else
                        pattern_color565 = 16'h0010;
                end
                3'd6: begin
                    // DHT22 monitor page:
                    // Top stripe = status, center = temperature xx.x, bottom = humidity xx.x
                    pattern_color565 = 16'h0004;
                    pixel_on         = 1'b0;
                    text_px          = 1'b0;
                    local_x          = '0;
                    local_y          = '0;
                    row5x7           = '0;
                    col5x7           = '0;
                    digit_id         = 4'd0;

                    t_tens_disp = dht_has_data_i_f ? temp_tens_i_f : 4'd10;
                    t_ones_disp = dht_has_data_i_f ? temp_ones_i_f : 4'd10;
                    t_dec_disp  = dht_has_data_i_f ? temp_dec_i_f  : 4'd10;
                    h_tens_disp = dht_has_data_i_f ? hum_tens_i_f  : 4'd10;
                    h_ones_disp = dht_has_data_i_f ? hum_ones_i_f  : 4'd10;
                    h_dec_disp  = dht_has_data_i_f ? hum_dec_i_f   : 4'd10;

                    if (y_i < 8) begin
                        if (dht_busy_i_f)
                            pattern_color565 = 16'hFD20; // capture in progress
                        else if (!dht_has_data_i_f)
                            pattern_color565 = 16'h0016; // no sample yet
                        else if (dht_error_i_f)
                            pattern_color565 = 16'hF800; // latest capture failed
                        else
                            pattern_color565 = 16'h07E0; // latest sample valid
                    end else begin
                        if (temp_neg_i_f && x_i >= 7'd20 && x_i < 7'd30 && y_i >= 8'd46 && y_i < 8'd48)
                            pattern_color565 = 16'hF800;

                        if ((x_i >= 7'd58 && x_i < 7'd60 && y_i >= 8'd47 && y_i < 8'd49) ||
                            (x_i >= 7'd58 && x_i < 7'd60 && y_i >= 8'd103 && y_i < 8'd105))
                            pattern_color565 = 16'hFFFF;

                        // Temperature line (yellow): xx.x
                        if (y_i >= 8'd38 && y_i < 8'd52) begin
                            local_y = y_i - 8'd38;
                            row5x7  = local_y[4:1];
                            if (x_i >= 7'd34 && x_i < 7'd44) begin
                                local_x = x_i - 7'd34; col5x7 = local_x[3:1]; digit_id = t_tens_disp; text_px = 1'b1;
                            end else if (x_i >= 7'd46 && x_i < 7'd56) begin
                                local_x = x_i - 7'd46; col5x7 = local_x[3:1]; digit_id = t_ones_disp; text_px = 1'b1;
                            end else if (x_i >= 7'd62 && x_i < 7'd72) begin
                                local_x = x_i - 7'd62; col5x7 = local_x[3:1]; digit_id = t_dec_disp;  text_px = 1'b1;
                            end

                            if (text_px && digit_pixel_5x7(digit_id, row5x7, col5x7))
                                pixel_on = 1'b1;
                        end

                        if (pixel_on)
                            pattern_color565 = 16'hFFE0;

                        // Humidity line (cyan): xx.x
                        pixel_on = 1'b0;
                        text_px  = 1'b0;
                        if (y_i >= 8'd94 && y_i < 8'd108) begin
                            local_y = y_i - 8'd94;
                            row5x7  = local_y[4:1];
                            if (x_i >= 7'd34 && x_i < 7'd44) begin
                                local_x = x_i - 7'd34; col5x7 = local_x[3:1]; digit_id = h_tens_disp; text_px = 1'b1;
                            end else if (x_i >= 7'd46 && x_i < 7'd56) begin
                                local_x = x_i - 7'd46; col5x7 = local_x[3:1]; digit_id = h_ones_disp; text_px = 1'b1;
                            end else if (x_i >= 7'd62 && x_i < 7'd72) begin
                                local_x = x_i - 7'd62; col5x7 = local_x[3:1]; digit_id = h_dec_disp;  text_px = 1'b1;
                            end

                            if (text_px && digit_pixel_5x7(digit_id, row5x7, col5x7))
                                pixel_on = 1'b1;
                        end

                        if (pixel_on)
                            pattern_color565 = 16'h07FF;

                        // Small corner label: AYENGEC (x1 font, green)
                        text_px = 1'b0;
                        if (y_i >= 8'd12 && y_i < 8'd19) begin
                            local_y = y_i - 8'd12;
                            row5x7  = local_y[2:0];
                            if (x_i >= 7'd4 && x_i < 7'd9) begin
                                local_x = x_i - 7'd4;  col5x7 = local_x[2:0]; glyph_id = 3'd0; text_px = 1'b1; // A
                            end else if (x_i >= 7'd10 && x_i < 7'd15) begin
                                local_x = x_i - 7'd10; col5x7 = local_x[2:0]; glyph_id = 3'd1; text_px = 1'b1; // Y
                            end else if (x_i >= 7'd16 && x_i < 7'd21) begin
                                local_x = x_i - 7'd16; col5x7 = local_x[2:0]; glyph_id = 3'd2; text_px = 1'b1; // E
                            end else if (x_i >= 7'd22 && x_i < 7'd27) begin
                                local_x = x_i - 7'd22; col5x7 = local_x[2:0]; glyph_id = 3'd3; text_px = 1'b1; // N
                            end else if (x_i >= 7'd28 && x_i < 7'd33) begin
                                local_x = x_i - 7'd28; col5x7 = local_x[2:0]; glyph_id = 3'd4; text_px = 1'b1; // G
                            end else if (x_i >= 7'd34 && x_i < 7'd39) begin
                                local_x = x_i - 7'd34; col5x7 = local_x[2:0]; glyph_id = 3'd2; text_px = 1'b1; // E
                            end else if (x_i >= 7'd40 && x_i < 7'd45) begin
                                local_x = x_i - 7'd40; col5x7 = local_x[2:0]; glyph_id = 3'd5; text_px = 1'b1; // C
                            end
                            if (text_px && glyph_pixel_5x7(glyph_id, row5x7, col5x7))
                                pattern_color565 = 16'h07E0;
                        end

                        // Small corner timer: SS (00..99) on top-right.
                        text_px = 1'b0;
                        if (y_i >= 8'd12 && y_i < 8'd19) begin
                            local_y = y_i - 8'd12;
                            row5x7  = local_y[2:0];
                            if (x_i >= 7'd112 && x_i < 7'd117) begin
                                local_x = x_i - 7'd112; col5x7 = local_x[2:0]; digit_id = tmr_tens_i_f; text_px = 1'b1;
                            end else if (x_i >= 7'd118 && x_i < 7'd123) begin
                                local_x = x_i - 7'd118; col5x7 = local_x[2:0]; digit_id = tmr_ones_i_f; text_px = 1'b1;
                            end
                            if (text_px && digit_pixel_5x7(digit_id, row5x7, col5x7))
                                pattern_color565 = 16'hFFFF;
                        end
                    end
                end
                default: begin
                    // Checkerboard pattern
                    if (x_i[4] ^ y_i[4])
                        pattern_color565 = 16'hFFFF;
                    else
                        pattern_color565 = 16'h0000;
                end
            endcase
        end
    endfunction

    assign pixel_color = pattern_color565(
        mode,
        x,
        y,
        dht_busy_i,
        dht_has_data_i,
        dht_error_i,
        temp_neg_i,
        temp_tens_i,
        temp_ones_i,
        temp_dec_i,
        hum_tens_i,
        hum_ones_i,
        hum_dec_i,
        tmr_tens_i,
        tmr_ones_i
    );
endmodule
