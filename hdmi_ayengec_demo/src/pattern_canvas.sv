/*
 * Project   : Tang Primer 20K HDMI Pattern Demo
 * File      : pattern_canvas.sv
 * Summary   : Animated background + moving AYENGEC logo
 * Designer  : Alican Yengec / ChatGPT
 * Language  : SystemVerilog
 */

module pattern_canvas (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        de,
    input  logic [11:0] x,
    input  logic [11:0] y,
    input  logic        frame_start,

    output logic [7:0]  r,
    output logic [7:0]  g,
    output logic [7:0]  b
);

    // ============================================================
    // Frame animation state
    // ============================================================

    logic [7:0] phase;

    logic [11:0] text_x;
    logic [11:0] text_y;
    logic        dir_x;
    logic        dir_y;

    localparam integer SCREEN_W   = 1280;
    localparam integer SCREEN_H   = 720;

    localparam integer LETTER_W   = 52;
    localparam integer LETTER_H   = 88;
    localparam integer LETTER_GAP = 12;
    localparam integer TEXT_W     = (7 * LETTER_W) + (6 * LETTER_GAP); // 436
    localparam integer TEXT_H     = LETTER_H;

    localparam integer X_STEP     = 4;
    localparam integer Y_STEP     = 2;

    localparam integer SHADOW_DX  = 6;
    localparam integer SHADOW_DY  = 6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase  <= 8'd0;
            text_x <= 12'd120;
            text_y <= 12'd180;
            dir_x  <= 1'b1;
            dir_y  <= 1'b1;
        end else if (frame_start) begin
            phase <= phase + 8'd1;

            if (dir_x) begin
                if (text_x + TEXT_W + X_STEP >= SCREEN_W - 1) begin
                    text_x <= SCREEN_W - TEXT_W - 1;
                    dir_x  <= 1'b0;
                end else begin
                    text_x <= text_x + X_STEP;
                end
            end else begin
                if (text_x <= X_STEP) begin
                    text_x <= 12'd0;
                    dir_x  <= 1'b1;
                end else begin
                    text_x <= text_x - X_STEP;
                end
            end

            if (dir_y) begin
                if (text_y + TEXT_H + Y_STEP >= SCREEN_H - 1) begin
                    text_y <= SCREEN_H - TEXT_H - 1;
                    dir_y  <= 1'b0;
                end else begin
                    text_y <= text_y + Y_STEP;
                end
            end else begin
                if (text_y <= Y_STEP) begin
                    text_y <= 12'd0;
                    dir_y  <= 1'b1;
                end else begin
                    text_y <= text_y - Y_STEP;
                end
            end
        end
    end

    // ============================================================
    // Background pattern
    // ============================================================

    logic [7:0] grad_r;
    logic [7:0] grad_g;
    logic [7:0] grad_b;

    logic checker_on;
    logic [12:0] x_shift;
    logic [12:0] dxy;
    logic reticle_on;

    always @(*) begin
        grad_r = x[7:0];
        grad_g = y[7:0];
        grad_b = x[7:0] ^ y[7:0];

        checker_on = x[6] ^ y[6];

        x_shift = {1'b0, x};
        if (x_shift >= {1'b0, y})
            dxy = x_shift - {1'b0, y};
        else
            dxy = {1'b0, y} - x_shift;


        reticle_on = ((x > 12'd636) && (x < 12'd644)) ||
                    ((y > 12'd356) && (y < 12'd364));
    end

    // ============================================================
    // Text / shadow coordinate space
    // ============================================================

    logic [11:0] tx;
    logic [11:0] ty;
    logic [11:0] sx;
    logic [11:0] sy;

    logic text_region;
    logic shadow_region;

    always @(*) begin
        text_region   = (x >= text_x) && (x < text_x + TEXT_W) &&
                        (y >= text_y) && (y < text_y + TEXT_H);

        shadow_region = (x >= text_x + SHADOW_DX) && (x < text_x + SHADOW_DX + TEXT_W) &&
                        (y >= text_y + SHADOW_DY) && (y < text_y + SHADOW_DY + TEXT_H);

        tx = x - text_x;
        ty = y - text_y;

        sx = x - (text_x + SHADOW_DX);
        sy = y - (text_y + SHADOW_DY);
    end

    // ============================================================
    // Letter rendering helpers
    // ============================================================

    logic [5:0] lx;
    logic [6:0] ly;

    logic [5:0] slx;
    logic [6:0] sly;

    logic text_fill;
    logic text_outline;
    logic shadow_fill;

    logic a_fill, y_fill, e1_fill, n_fill, g_fill, e2_fill, c_fill;
    logic a_out,  y_out,  e1_out,  n_out,  g_out,  e2_out,  c_out;

    logic sa_fill, sy_fill, se1_fill, sn_fill, sg_fill, se2_fill, sc_fill;

    // Letter x ranges:
    // A :   0.. 51
    // Y :  64..115
    // E : 128..179
    // N : 192..243
    // G : 256..307
    // E : 320..371
    // C : 384..435

    always @(*) begin
        // defaults
        text_fill    = 1'b0;
        text_outline = 1'b0;
        shadow_fill  = 1'b0;

        a_fill  = 1'b0; y_fill  = 1'b0; e1_fill = 1'b0; n_fill  = 1'b0;
        g_fill  = 1'b0; e2_fill = 1'b0; c_fill  = 1'b0;

        a_out   = 1'b0; y_out   = 1'b0; e1_out  = 1'b0; n_out   = 1'b0;
        g_out   = 1'b0; e2_out  = 1'b0; c_out   = 1'b0;

        sa_fill = 1'b0; sy_fill = 1'b0; se1_fill = 1'b0; sn_fill = 1'b0;
        sg_fill = 1'b0; se2_fill = 1'b0; sc_fill  = 1'b0;

        lx  = 6'd0;
        ly  = 7'd0;
        slx = 6'd0;
        sly = 7'd0;

        // ----------------------------
        // Main text shapes
        // ----------------------------
        if (text_region) begin
            // ===== A =====
            if (tx < 12'd52) begin
                lx = tx[5:0];
                ly = ty[6:0];

                // outer
                a_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd10) && (ly <= 7'd87)) ||
                    ((lx >= 6'd42) && (lx <= 6'd51) && (ly >= 7'd10) && (ly <= 7'd87)) ||
                    ((ly >= 7'd0)  && (ly <= 7'd9)  && (lx >= 6'd8)  && (lx <= 6'd43)) ||
                    ((ly >= 7'd38) && (ly <= 7'd47) && (lx >= 6'd8)  && (lx <= 6'd43));

                // inner
                a_fill =
                    ((lx >= 6'd4)  && (lx <= 6'd11) && (ly >= 7'd14) && (ly <= 7'd83)) ||
                    ((lx >= 6'd40) && (lx <= 6'd47) && (ly >= 7'd14) && (ly <= 7'd83)) ||
                    ((ly >= 7'd4)  && (ly <= 7'd11) && (lx >= 6'd10) && (lx <= 6'd41)) ||
                    ((ly >= 7'd40) && (ly <= 7'd45) && (lx >= 6'd10) && (lx <= 6'd41));
            end

            // ===== Y =====
            else if ((tx >= 12'd64) && (tx < 12'd116)) begin
                lx = (tx - 12'd64);
                ly = ty[6:0];

                y_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd35)) ||
                    ((lx >= 6'd42) && (lx <= 6'd51) && (ly >= 7'd0)  && (ly <= 7'd35)) ||
                    ((lx >= 6'd20) && (lx <= 6'd31) && (ly >= 7'd30) && (ly <= 7'd87)) ||
                    ((ly >= 7'd30) && (ly <= 7'd39) && (lx >= 6'd8)  && (lx <= 6'd43));

                y_fill =
                    ((lx >= 6'd3)  && (lx <= 6'd10) && (ly >= 7'd3)  && (ly <= 7'd32)) ||
                    ((lx >= 6'd41) && (lx <= 6'd48) && (ly >= 7'd3)  && (ly <= 7'd32)) ||
                    ((lx >= 6'd22) && (lx <= 6'd29) && (ly >= 7'd34) && (ly <= 7'd83)) ||
                    ((ly >= 7'd32) && (ly <= 7'd37) && (lx >= 6'd10) && (lx <= 6'd41));
            end

            // ===== E1 =====
            else if ((tx >= 12'd128) && (tx < 12'd180)) begin
                lx = (tx - 12'd128);
                ly = ty[6:0];

                e1_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    ((ly >= 7'd0)  && (ly <= 7'd9)  && (lx >= 6'd0)  && (lx <= 6'd51)) ||
                    ((ly >= 7'd39) && (ly <= 7'd48) && (lx >= 6'd0)  && (lx <= 6'd43)) ||
                    ((ly >= 7'd78) && (ly <= 7'd87) && (lx >= 6'd0)  && (lx <= 6'd51));

                e1_fill =
                    ((lx >= 6'd4)  && (lx <= 6'd11) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    ((ly >= 7'd4)  && (ly <= 7'd11) && (lx >= 6'd4)  && (lx <= 6'd47)) ||
                    ((ly >= 7'd41) && (ly <= 7'd46) && (lx >= 6'd4)  && (lx <= 6'd39)) ||
                    ((ly >= 7'd76) && (ly <= 7'd83) && (lx >= 6'd4)  && (lx <= 6'd47));
            end

            // ===== N =====
            else if ((tx >= 12'd192) && (tx < 12'd244)) begin
                lx = (tx - 12'd192);
                ly = ty[6:0];

                n_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    ((lx >= 6'd42) && (lx <= 6'd51) && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    (((lx + 6'd6) >= (ly >> 1)) && ((lx) <= (ly >> 1) + 6'd6));

                n_fill =
                    ((lx >= 6'd3)  && (lx <= 6'd10) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    ((lx >= 6'd41) && (lx <= 6'd48) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    (((lx + 6'd4) >= (ly >> 1)) && ((lx) <= (ly >> 1) + 6'd4));
            end

            // ===== G =====
            else if ((tx >= 12'd256) && (tx < 12'd308)) begin
                lx = (tx - 12'd256);
                ly = ty[6:0];

                g_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    ((ly >= 7'd0)  && (ly <= 7'd9)  && (lx >= 6'd0)  && (lx <= 6'd51)) ||
                    ((ly >= 7'd78) && (ly <= 7'd87) && (lx >= 6'd0)  && (lx <= 6'd51)) ||
                    ((lx >= 6'd42) && (lx <= 6'd51) && (ly >= 7'd44) && (ly <= 7'd87)) ||
                    ((ly >= 7'd39) && (ly <= 7'd48) && (lx >= 6'd24) && (lx <= 6'd51));

                g_fill =
                    ((lx >= 6'd4)  && (lx <= 6'd11) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    ((ly >= 7'd4)  && (ly <= 7'd11) && (lx >= 6'd4)  && (lx <= 6'd47)) ||
                    ((ly >= 7'd76) && (ly <= 7'd83) && (lx >= 6'd4)  && (lx <= 6'd47)) ||
                    ((lx >= 6'd40) && (lx <= 6'd47) && (ly >= 7'd46) && (ly <= 7'd83)) ||
                    ((ly >= 7'd41) && (ly <= 7'd46) && (lx >= 6'd24) && (lx <= 6'd47));
            end

            // ===== E2 =====
            else if ((tx >= 12'd320) && (tx < 12'd372)) begin
                lx = (tx - 12'd320);
                ly = ty[6:0];

                e2_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    ((ly >= 7'd0)  && (ly <= 7'd9)  && (lx >= 6'd0)  && (lx <= 6'd51)) ||
                    ((ly >= 7'd39) && (ly <= 7'd48) && (lx >= 6'd0)  && (lx <= 6'd43)) ||
                    ((ly >= 7'd78) && (ly <= 7'd87) && (lx >= 6'd0)  && (lx <= 6'd51));

                e2_fill =
                    ((lx >= 6'd4)  && (lx <= 6'd11) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    ((ly >= 7'd4)  && (ly <= 7'd11) && (lx >= 6'd4)  && (lx <= 6'd47)) ||
                    ((ly >= 7'd41) && (ly <= 7'd46) && (lx >= 6'd4)  && (lx <= 6'd39)) ||
                    ((ly >= 7'd76) && (ly <= 7'd83) && (lx >= 6'd4)  && (lx <= 6'd47));
            end

            // ===== C =====
            else if ((tx >= 12'd384) && (tx < 12'd436)) begin
                lx = (tx - 12'd384);
                ly = ty[6:0];

                c_out =
                    ((lx >= 6'd0)  && (lx <= 6'd9)  && (ly >= 7'd0)  && (ly <= 7'd87)) ||
                    ((ly >= 7'd0)  && (ly <= 7'd9)  && (lx >= 6'd0)  && (lx <= 6'd51)) ||
                    ((ly >= 7'd78) && (ly <= 7'd87) && (lx >= 6'd0)  && (lx <= 6'd51));

                c_fill =
                    ((lx >= 6'd4)  && (lx <= 6'd11) && (ly >= 7'd4)  && (ly <= 7'd83)) ||
                    ((ly >= 7'd4)  && (ly <= 7'd11) && (lx >= 6'd4)  && (lx <= 6'd47)) ||
                    ((ly >= 7'd76) && (ly <= 7'd83) && (lx >= 6'd4)  && (lx <= 6'd47));
            end

            text_fill    = a_fill | y_fill | e1_fill | n_fill | g_fill | e2_fill | c_fill;
            text_outline = (a_out | y_out | e1_out | n_out | g_out | e2_out | c_out) & ~text_fill;
        end

        // ----------------------------
        // Shadow shapes
        // ----------------------------
        if (shadow_region) begin
            // A
            if (sx < 12'd52) begin
                slx = sx[5:0];
                sly = sy[6:0];
                sa_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd10) && (sly <= 7'd87)) ||
                    ((slx >= 6'd42) && (slx <= 6'd51) && (sly >= 7'd10) && (sly <= 7'd87)) ||
                    ((sly >= 7'd0)  && (sly <= 7'd9)  && (slx >= 6'd8)  && (slx <= 6'd43)) ||
                    ((sly >= 7'd38) && (sly <= 7'd47) && (slx >= 6'd8)  && (slx <= 6'd43));
            end
            // Y
            else if ((sx >= 12'd64) && (sx < 12'd116)) begin
                slx = (sx - 12'd64);
                sly = sy[6:0];
                sy_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd35)) ||
                    ((slx >= 6'd42) && (slx <= 6'd51) && (sly >= 7'd0)  && (sly <= 7'd35)) ||
                    ((slx >= 6'd20) && (slx <= 6'd31) && (sly >= 7'd30) && (sly <= 7'd87)) ||
                    ((sly >= 7'd30) && (sly <= 7'd39) && (slx >= 6'd8)  && (slx <= 6'd43));
            end
            // E1
            else if ((sx >= 12'd128) && (sx < 12'd180)) begin
                slx = (sx - 12'd128);
                sly = sy[6:0];
                se1_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    ((sly >= 7'd0)  && (sly <= 7'd9)  && (slx >= 6'd0)  && (slx <= 6'd51)) ||
                    ((sly >= 7'd39) && (sly <= 7'd48) && (slx >= 6'd0)  && (slx <= 6'd43)) ||
                    ((sly >= 7'd78) && (sly <= 7'd87) && (slx >= 6'd0)  && (slx <= 6'd51));
            end
            // N
            else if ((sx >= 12'd192) && (sx < 12'd244)) begin
                slx = (sx - 12'd192);
                sly = sy[6:0];
                sn_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    ((slx >= 6'd42) && (slx <= 6'd51) && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    (((slx + 6'd6) >= (sly >> 1)) && ((slx) <= (sly >> 1) + 6'd6));
            end
            // G
            else if ((sx >= 12'd256) && (sx < 12'd308)) begin
                slx = (sx - 12'd256);
                sly = sy[6:0];
                sg_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    ((sly >= 7'd0)  && (sly <= 7'd9)  && (slx >= 6'd0)  && (slx <= 6'd51)) ||
                    ((sly >= 7'd78) && (sly <= 7'd87) && (slx >= 6'd0)  && (slx <= 6'd51)) ||
                    ((slx >= 6'd42) && (slx <= 6'd51) && (sly >= 7'd44) && (sly <= 7'd87)) ||
                    ((sly >= 7'd39) && (sly <= 7'd48) && (slx >= 6'd24) && (slx <= 6'd51));
            end
            // E2
            else if ((sx >= 12'd320) && (sx < 12'd372)) begin
                slx = (sx - 12'd320);
                sly = sy[6:0];
                se2_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    ((sly >= 7'd0)  && (sly <= 7'd9)  && (slx >= 6'd0)  && (slx <= 6'd51)) ||
                    ((sly >= 7'd39) && (sly <= 7'd48) && (slx >= 6'd0)  && (slx <= 6'd43)) ||
                    ((sly >= 7'd78) && (sly <= 7'd87) && (slx >= 6'd0)  && (slx <= 6'd51));
            end
            // C
            else if ((sx >= 12'd384) && (sx < 12'd436)) begin
                slx = (sx - 12'd384);
                sly = sy[6:0];
                sc_fill =
                    ((slx >= 6'd0)  && (slx <= 6'd9)  && (sly >= 7'd0)  && (sly <= 7'd87)) ||
                    ((sly >= 7'd0)  && (sly <= 7'd9)  && (slx >= 6'd0)  && (slx <= 6'd51)) ||
                    ((sly >= 7'd78) && (sly <= 7'd87) && (slx >= 6'd0)  && (slx <= 6'd51));
            end

            shadow_fill = sa_fill | sy_fill | se1_fill | sn_fill | sg_fill | se2_fill | sc_fill;
        end
    end

    // ============================================================
    // Final compositor
    // ============================================================

    logic [7:0] bg_r;
    logic [7:0] bg_g;
    logic [7:0] bg_b;

    logic [7:0] text_r;
    logic [7:0] text_g;
    logic [7:0] text_b;

    always @(*) begin
        // Background
        if (!de) begin
            bg_r = 8'd0;
            bg_g = 8'd0;
            bg_b = 8'd0;
        end else if (reticle_on) begin
            bg_r = 8'hFF;
            bg_g = 8'hFF;
            bg_b = 8'hFF;

        end else if (checker_on) begin
            bg_r = grad_r;
            bg_g = grad_g >> 1;
            bg_b = grad_b + 8'h20;
        end else begin
            bg_r = grad_r;
            bg_g = grad_g;
            bg_b = grad_b;
        end

        // Text fill color: animated orange/red/yellow style
        text_r = 8'hD0 + {2'b00, phase[5:0]};
        text_g = 8'h30 + {3'b000, ty[4:0]};
        text_b = 8'h10 + {2'b00, phase[5:0]};

        if (!de) begin
            r = 8'd0;
            g = 8'd0;
            b = 8'd0;
        end else if (text_fill) begin
            r = text_r;
            g = text_g;
            b = text_b;
        end else if (text_outline) begin
            r = 8'hFF;
            g = 8'hFF;
            b = 8'hFF;
        end else if (shadow_fill) begin
            r = bg_r >> 2;
            g = bg_g >> 2;
            b = bg_b >> 2;
        end else begin
            r = bg_r;
            g = bg_g;
            b = bg_b;
        end
    end

endmodule