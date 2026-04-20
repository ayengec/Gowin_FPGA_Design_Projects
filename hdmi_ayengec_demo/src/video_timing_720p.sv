/*
 * Project   : Tang Primer 20K HDMI Pattern Demo (Phase-1)
 * File      : video_timing_720p.sv
 * Summary   : 1280x720 timing generator with HS/VS/DE and pixel coordinates.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 */

module video_timing_720p (
    input  logic        clk,
    input  logic        rst_n,

    output logic        hs,
    output logic        vs,
    output logic        de,
    output logic [11:0] x,
    output logic [11:0] y,
    output logic        frame_start
);

    // 720p timing constants.
    localparam int H_ACTIVE = 1280;
    localparam int H_FP     = 110;
    localparam int H_SYNC   = 40;
    localparam int H_BP     = 220;
    localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;

    localparam int V_ACTIVE = 720;
    localparam int V_FP     = 5;
    localparam int V_SYNC   = 5;
    localparam int V_BP     = 20;
    localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;

    // Full-space counters including blanking.
    logic [11:0] h_ctr;
    logic [11:0] v_ctr;

    // Horizontal and vertical counters.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_ctr <= '0;
            v_ctr <= '0;
        end else begin
            if (h_ctr == H_TOTAL - 1) begin
                h_ctr <= '0;
                if (v_ctr == V_TOTAL - 1)
                    v_ctr <= '0;
                else
                    v_ctr <= v_ctr + 1'b1;
            end else begin
                h_ctr <= h_ctr + 1'b1;
            end
        end
    end

    // Timing outputs and visible-space coordinate export.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hs          <= 1'b0;
            vs          <= 1'b0;
            de          <= 1'b0;
            x           <= '0;
            y           <= '0;
            frame_start <= 1'b0;
        end else begin
            frame_start <= (h_ctr == 0) && (v_ctr == 0);

            hs <= (h_ctr >= (H_ACTIVE + H_FP)) &&
                  (h_ctr <  (H_ACTIVE + H_FP + H_SYNC));

            vs <= (v_ctr >= (V_ACTIVE + V_FP)) &&
                  (v_ctr <  (V_ACTIVE + V_FP + V_SYNC));

            de <= (h_ctr < H_ACTIVE) && (v_ctr < V_ACTIVE);

            if (h_ctr < H_ACTIVE)
                x <= h_ctr;
            else
                x <= '0;

            if (v_ctr < V_ACTIVE)
                y <= v_ctr;
            else
                y <= '0;
        end
    end

endmodule
