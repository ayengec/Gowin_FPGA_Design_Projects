/*
 * Project   : Tang Primer 20K HDMI Pattern Demo (Phase-1)
 * File      : hdmi_colorbar_top.sv
 * Summary   : Custom HDMI test scene generator (not stock colorbar).
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Notes     : Keeps Gowin TMDS TX + PLL IP, but video logic is custom.
 */

module hdmi_colorbar_top (
    input  logic       I_clk,          // 27 MHz board clock
    input  logic       I_rst_n,        // active-low reset

    output logic [3:0] O_led,          // status LEDs

    output logic       O_tmds_clk_p,
    output logic       O_tmds_clk_n,
    output logic [2:0] O_tmds_data_p,
    output logic [2:0] O_tmds_data_n
);

    // Clocking domain setup.
    logic serial_clk;
    logic pix_clk;
    logic pll_lock;
    logic video_rst_n;

    TMDS_rPLL u_tmds_rpll (
        .clkin  (I_clk),
        .clkout (serial_clk),
        .lock   (pll_lock)
    );

    assign video_rst_n = I_rst_n & pll_lock;

    CLKDIV u_clkdiv (
        .RESETN (video_rst_n),
        .HCLKIN (serial_clk),
        .CLKOUT (pix_clk),
        .CALIB  (1'b1)
    );
    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN    = "false";

    // 720p timing core.
    logic        vout_hs;
    logic        vout_vs;
    logic        vout_de;
    logic [11:0] pix_x;
    logic [11:0] pix_y;
    logic        frame_start;

    video_timing_720p u_video_timing_720p (
        .clk         (pix_clk),
        .rst_n       (video_rst_n),
        .hs          (vout_hs),
        .vs          (vout_vs),
        .de          (vout_de),
        .x           (pix_x),
        .y           (pix_y),
        .frame_start (frame_start)
    );

    // Custom pattern engine.
    logic [7:0] vout_r;
    logic [7:0] vout_g;
    logic [7:0] vout_b;

    pattern_canvas u_pattern_canvas (
        .clk         (pix_clk),
        .rst_n       (video_rst_n),
        .de          (vout_de),
        .x           (pix_x),
        .y           (pix_y),
        .frame_start (frame_start),
        .r           (vout_r),
        .g           (vout_g),
        .b           (vout_b)
    );

    // HDMI TMDS transmitter IP.
    DVI_TX_Top u_dvi_tx (
        .I_rst_n       (video_rst_n),
        .I_serial_clk  (serial_clk),
        .I_rgb_clk     (pix_clk),
        .I_rgb_vs      (vout_vs),
        .I_rgb_hs      (vout_hs),
        .I_rgb_de      (vout_de),
        .I_rgb_r       (vout_r),
        .I_rgb_g       (vout_g),
        .I_rgb_b       (vout_b),
        .O_tmds_clk_p  (O_tmds_clk_p),
        .O_tmds_clk_n  (O_tmds_clk_n),
        .O_tmds_data_p (O_tmds_data_p),
        .O_tmds_data_n (O_tmds_data_n)
    );

    // LED logic.
    logic [5:0] frame_div;
    logic       frame_blink;

    always_ff @(posedge pix_clk or negedge video_rst_n) begin
        if (!video_rst_n) begin
            frame_div   <= '0;
            frame_blink <= 1'b0;
        end else if (frame_start) begin
            frame_div <= frame_div + 1'b1;
            if (frame_div == 6'd31)
                frame_blink <= ~frame_blink;
        end
    end

    assign O_led[0] = pll_lock;
    assign O_led[1] = frame_blink;
    assign O_led[2] = ~I_rst_n;
    assign O_led[3] = vout_de;

endmodule
