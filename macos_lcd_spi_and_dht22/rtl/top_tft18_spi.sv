/*
 * Project   : macos_tft18_spi_dht22
 * File      : top_tft18_spi.sv
 * Summary   : Tang Primer 20K top module that initializes a 128x160 ST77xx TFT
 *             and continuously draws simple color/pattern frames.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Notes:
 * - This design targets the common 1.8" SPI TFT boards (usually ST7735/ST77xx family).
 * - Module pin names follow the common TFT silk labels:
 *     LED, SCK, SDA(MOSI), A0(DC), RESET, CS, GND, VCC
 * - Adds DHT22 single-wire sensor support with periodic sampling in DHT page.
 * - DHT page includes a small "AYENGEC" label and a 1-Hz corner timer.
 * - No UART is used. Control is with board buttons.
 */
module top_tft18_spi #(
    parameter int CLK_HZ       = 27_000_000,
    parameter int TFT_W        = 128,
    parameter int TFT_H        = 160,
    parameter int X_OFFSET     = 0,
    parameter int Y_OFFSET     = 0,
    parameter bit BL_ON_LEVEL  = 1'b1  
) (
    input  logic       clk_27m,
    input  logic       btn_mode_n,      // S1: next pattern (active-low)
    input  logic       btn_auto_n,      // S2: previous pattern/page (active-low)
    inout  tri         dht22_io,        // DHT22 one-wire DATA pin (open-drain style)

    output logic       lcd_bl,
    output logic       lcd_data,
    output logic       lcd_rs,
    output logic       lcd_cs,
    output logic       lcd_clk,
    output logic       lcd_resetn,

    output logic [3:0] led
);
    localparam int PIXELS = TFT_W * TFT_H;
    localparam int PATTERN_COUNT = 7;

    // Delay constants for initialization timing.
    localparam int MS_CYCLES = CLK_HZ / 1000;
    localparam int DLY_5MS   = MS_CYCLES * 5;
    localparam int DLY_20MS  = MS_CYCLES * 20;
    localparam int DLY_120MS = MS_CYCLES * 120;
    localparam int DLY_150MS = MS_CYCLES * 150;

    // Coordinate helper constants (16-bit window programming values).
    localparam int X_START_I = X_OFFSET;
    localparam int X_END_I   = X_OFFSET + TFT_W - 1;
    localparam int Y_START_I = Y_OFFSET;
    localparam int Y_END_I   = Y_OFFSET + TFT_H - 1;

    localparam logic [15:0] X_START = X_START_I[15:0];
    localparam logic [15:0] X_END   = X_END_I[15:0];
    localparam logic [15:0] Y_START = Y_START_I[15:0];
    localparam logic [15:0] Y_END   = Y_END_I[15:0];
    localparam logic [14:0] PIXELS_15 = PIXELS[14:0];

    typedef enum logic [5:0] {
        ST_BOOT_DELAY,
        ST_HW_RESET_ASSERT,
        ST_HW_RESET_RELEASE,

        ST_INIT_CMD_SWRESET,
        ST_INIT_DELAY_SWRESET,
        ST_INIT_CMD_SLPOUT,
        ST_INIT_DELAY_SLPOUT,
        ST_INIT_CMD_COLMOD,
        ST_INIT_DATA_COLMOD,
        ST_INIT_CMD_MADCTL,
        ST_INIT_DATA_MADCTL,
        ST_INIT_CMD_CASET,
        ST_INIT_DATA_CASET0,
        ST_INIT_DATA_CASET1,
        ST_INIT_DATA_CASET2,
        ST_INIT_DATA_CASET3,
        ST_INIT_CMD_RASET,
        ST_INIT_DATA_RASET0,
        ST_INIT_DATA_RASET1,
        ST_INIT_DATA_RASET2,
        ST_INIT_DATA_RASET3,
        ST_INIT_CMD_NORON,
        ST_INIT_CMD_DISPON,
        ST_INIT_DELAY_DISPON,

        ST_FRAME_PREP,
        ST_FRAME_CMD_RAMWR,
        ST_FRAME_PIX_HI,
        ST_FRAME_PIX_LO,
        ST_FRAME_PIXEL_COMMIT,

        ST_SEND_BYTE,
        ST_DELAY
    } state_t;

    // Main FSM bookkeeping.
    state_t state;
    state_t state_after_send;
    state_t state_after_delay;

    logic [23:0] delay_cnt;

    // "send one byte" request to SPI engine.
    logic       send_dc;
    logic [7:0] send_byte;
    logic       send_hold_cs;
    logic       send_issued;

    // SPI byte transmitter interface.
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;
    logic       tx_done;

    // Internal power-on reset so design starts from a known state.
    logic        rst_n   = 1'b0;
    logic [15:0] por_cnt = '0;

    // Button press events.
    logic btn_mode_evt;
    logic btn_auto_evt;

    // Pattern/page control and frame scan position.
    logic [2:0] pattern_idx;
    logic [3:0] ui_sec_tens;
    logic [3:0] ui_sec_ones;

    logic [6:0] pixel_x;
    logic [7:0] pixel_y;
    logic [14:0] pixels_left;

    logic init_done;

    // DHT22 interface and last-sample display data.
    logic        dht_start;
    logic        dht_ready;
    logic        dht_busy;
    logic        dht_done;
    logic        dht_valid;
    logic        dht_crc_ok;
    logic [15:0] dht_hum_x10;
    logic [15:0] dht_temp_x10;
    logic        dht_temp_neg_raw;

    logic        dht_has_data;
    logic        dht_error_latched;

    logic        temp_neg_disp;
    logic [3:0]  temp_tens;
    logic [3:0]  temp_ones;
    logic [3:0]  temp_dec;
    logic [3:0]  hum_tens;
    logic [3:0]  hum_ones;
    logic [3:0]  hum_dec;
    logic        frame_boundary;

    // -------------------------------------------------------------------------
    // Internal power-on reset generator
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_27m) begin
        if (!por_cnt[15]) begin
            por_cnt <= por_cnt + 1'b1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Button press event detectors (debounced one-pulse outputs)
    // -------------------------------------------------------------------------
    button_event #(
        .CLK_HZ(CLK_HZ),
        .DEBOUNCE_MS(20)
    ) u_btn_mode (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_mode_n),
        .press_pulse(btn_mode_evt)
    );

    button_event #(
        .CLK_HZ(CLK_HZ),
        .DEBOUNCE_MS(20)
    ) u_btn_auto (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .btn_n      (btn_auto_n),
        .press_pulse(btn_auto_evt)
    );

    assign frame_boundary = (state == ST_FRAME_PREP);

    // -------------------------------------------------------------------------
    // UI/page control and periodic DHT start generation.
    // -------------------------------------------------------------------------
    ui_page_control #(
        .CLK_HZ       (CLK_HZ),
        .PATTERN_COUNT(PATTERN_COUNT),
        .DHT_PAGE_IDX (3'd6)
    ) u_page_control (
        .clk           (clk_27m),
        .rst_n         (rst_n),
        .btn_next_evt  (btn_mode_evt),
        .btn_prev_evt  (btn_auto_evt),
        .frame_boundary(frame_boundary),
        .dht_ready     (dht_ready),
        .pattern_idx   (pattern_idx),
        .dht_start     (dht_start),
        .ui_sec_tens   (ui_sec_tens),
        .ui_sec_ones   (ui_sec_ones)
    );

    // -------------------------------------------------------------------------
    // Convert raw DHT values into display digits and sticky status flags.
    // -------------------------------------------------------------------------
    dht_display_formatter u_dht_display_formatter (
        .clk              (clk_27m),
        .rst_n            (rst_n),
        .dht_done         (dht_done),
        .dht_valid        (dht_valid),
        .dht_crc_ok       (dht_crc_ok),
        .dht_hum_x10      (dht_hum_x10),
        .dht_temp_x10     (dht_temp_x10),
        .dht_temp_neg_raw (dht_temp_neg_raw),
        .dht_has_data     (dht_has_data),
        .dht_error_latched(dht_error_latched),
        .temp_neg_disp    (temp_neg_disp),
        .temp_tens        (temp_tens),
        .temp_ones        (temp_ones),
        .temp_dec         (temp_dec),
        .hum_tens         (hum_tens),
        .hum_ones         (hum_ones),
        .hum_dec          (hum_dec)
    );

    // -------------------------------------------------------------------------
    // Centralized page renderer.
    // -------------------------------------------------------------------------
    logic [15:0] pixel_color;

    tft_page_renderer u_tft_page_renderer (
        .mode       (pattern_idx),
        .x          (pixel_x),
        .y          (pixel_y),
        .dht_busy_i (dht_busy),
        .dht_has_data_i(dht_has_data),
        .dht_error_i(dht_error_latched),
        .temp_neg_i (temp_neg_disp),
        .temp_tens_i(temp_tens),
        .temp_ones_i(temp_ones),
        .temp_dec_i (temp_dec),
        .hum_tens_i (hum_tens),
        .hum_ones_i (hum_ones),
        .hum_dec_i  (hum_dec),
        .tmr_tens_i (ui_sec_tens),
        .tmr_ones_i (ui_sec_ones),
        .pixel_color(pixel_color)
    );

    // -------------------------------------------------------------------------
    // SPI byte transmitter instance
    // -------------------------------------------------------------------------
    spi_tx_byte #(
        .HALF_PERIOD_CLKS(16) // 27 MHz / (2*16) => ~0.84 MHz SPI clock (safe debug speed)
    ) u_spi_tx (
        .clk       (clk_27m),
        .rst_n     (rst_n),
        .start     (tx_start),
        .data      (tx_data),
        .busy      (tx_busy),
        .done_pulse(tx_done),
        .sclk      (lcd_clk),
        .mosi      (lcd_data)
    );

    // -------------------------------------------------------------------------
    // DHT22 reader instance
    // -------------------------------------------------------------------------
    dht22_ctrl #(
        .CLK_HZ(CLK_HZ)
    ) u_dht22 (
        .clk        (clk_27m),
        .rst_n      (rst_n),
        .start      (dht_start),
        .dht22_io   (dht22_io),
        .ready      (dht_ready),
        .busy       (dht_busy),
        .done_pulse (dht_done),
        .valid      (dht_valid),
        .crc_ok     (dht_crc_ok),
        .timeout_err(),
        .hum_x10    (dht_hum_x10),
        .temp_x10   (dht_temp_x10),
        .temp_neg   (dht_temp_neg_raw)
    );

    // -------------------------------------------------------------------------
    // Main controller FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_27m) begin
        if (!rst_n) begin
            state              <= ST_BOOT_DELAY;
            state_after_send   <= ST_BOOT_DELAY;
            state_after_delay  <= ST_BOOT_DELAY;
            delay_cnt          <= '0;

            send_dc            <= 1'b0;
            send_byte          <= 8'h00;
            send_hold_cs       <= 1'b0;
            send_issued        <= 1'b0;

            tx_data            <= 8'h00;
            tx_start           <= 1'b0;

            lcd_bl             <= ~BL_ON_LEVEL;
            lcd_rs             <= 1'b1;
            lcd_cs             <= 1'b1;
            lcd_resetn         <= 1'b1;

            pixel_x            <= '0;
            pixel_y            <= '0;
            pixels_left        <= '0;

            init_done          <= 1'b0;
        end else begin
            // Default deassertion for one-cycle start pulse.
            tx_start <= 1'b0;

            // Backlight stays on while running.
            lcd_bl <= BL_ON_LEVEL;

            case (state)
                ST_BOOT_DELAY: begin
                    lcd_cs     <= 1'b1;
                    lcd_rs     <= 1'b1;
                    lcd_resetn <= 1'b1;
                    init_done  <= 1'b0;

                    delay_cnt         <= DLY_5MS - 1;
                    state_after_delay <= ST_HW_RESET_ASSERT;
                    state             <= ST_DELAY;
                end

                ST_HW_RESET_ASSERT: begin
                    lcd_resetn        <= 1'b0;
                    delay_cnt         <= DLY_20MS - 1;
                    state_after_delay <= ST_HW_RESET_RELEASE;
                    state             <= ST_DELAY;
                end

                ST_HW_RESET_RELEASE: begin
                    lcd_resetn        <= 1'b1;
                    delay_cnt         <= DLY_120MS - 1;
                    state_after_delay <= ST_INIT_CMD_SWRESET;
                    state             <= ST_DELAY;
                end

                // ------------------------- ST77xx initialization ------------
                ST_INIT_CMD_SWRESET: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h01; // SWRESET
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DELAY_SWRESET;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DELAY_SWRESET: begin
                    delay_cnt         <= DLY_150MS - 1;
                    state_after_delay <= ST_INIT_CMD_SLPOUT;
                    state             <= ST_DELAY;
                end

                ST_INIT_CMD_SLPOUT: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h11; // SLPOUT
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DELAY_SLPOUT;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DELAY_SLPOUT: begin
                    delay_cnt         <= DLY_120MS - 1;
                    state_after_delay <= ST_INIT_CMD_COLMOD;
                    state             <= ST_DELAY;
                end

                ST_INIT_CMD_COLMOD: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h3A; // COLMOD
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DATA_COLMOD;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DATA_COLMOD: begin
                    send_dc           <= 1'b1;
                    send_byte         <= 8'h05; // 16-bit RGB565
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_CMD_MADCTL;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_CMD_MADCTL: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h36; // MADCTL
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DATA_MADCTL;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DATA_MADCTL: begin
                    send_dc           <= 1'b1;
                    send_byte         <= 8'h00; // RGB order, default orientation
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_CMD_CASET;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_CMD_CASET: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h2A; // CASET
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DATA_CASET0;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DATA_CASET0: begin send_dc <= 1'b1; send_byte <= X_START[15:8]; send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_CASET1; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_CASET1: begin send_dc <= 1'b1; send_byte <= X_START[7:0];  send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_CASET2; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_CASET2: begin send_dc <= 1'b1; send_byte <= X_END[15:8];   send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_CASET3; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_CASET3: begin send_dc <= 1'b1; send_byte <= X_END[7:0];    send_hold_cs <= 1'b0; state_after_send <= ST_INIT_CMD_RASET;  send_issued <= 1'b0; state <= ST_SEND_BYTE; end

                ST_INIT_CMD_RASET: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h2B; // RASET
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DATA_RASET0;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DATA_RASET0: begin send_dc <= 1'b1; send_byte <= Y_START[15:8]; send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_RASET1; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_RASET1: begin send_dc <= 1'b1; send_byte <= Y_START[7:0];  send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_RASET2; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_RASET2: begin send_dc <= 1'b1; send_byte <= Y_END[15:8];   send_hold_cs <= 1'b0; state_after_send <= ST_INIT_DATA_RASET3; send_issued <= 1'b0; state <= ST_SEND_BYTE; end
                ST_INIT_DATA_RASET3: begin send_dc <= 1'b1; send_byte <= Y_END[7:0];    send_hold_cs <= 1'b0; state_after_send <= ST_INIT_CMD_NORON;  send_issued <= 1'b0; state <= ST_SEND_BYTE; end

                ST_INIT_CMD_NORON: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h13; // NORON
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_CMD_DISPON;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_CMD_DISPON: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h29; // DISPON
                    send_hold_cs      <= 1'b0;
                    state_after_send  <= ST_INIT_DELAY_DISPON;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_INIT_DELAY_DISPON: begin
                    init_done         <= 1'b1;
                    delay_cnt         <= DLY_20MS - 1;
                    state_after_delay <= ST_FRAME_PREP;
                    state             <= ST_DELAY;
                end

                // ------------------------- Frame stream loop -----------------
                ST_FRAME_PREP: begin
                    pixel_x     <= 7'd0;
                    pixel_y     <= 8'd0;
                    pixels_left <= PIXELS_15;

                    state <= ST_FRAME_CMD_RAMWR;
                end

                ST_FRAME_CMD_RAMWR: begin
                    send_dc           <= 1'b0;
                    send_byte         <= 8'h2C; // RAMWR
                    send_hold_cs      <= 1'b1; // keep CS low for whole frame stream
                    state_after_send  <= ST_FRAME_PIX_HI;
                    send_issued       <= 1'b0;
                    state             <= ST_SEND_BYTE;
                end

                ST_FRAME_PIX_HI: begin
                    if (pixels_left == 0) begin
                        lcd_cs <= 1'b1;
                        state  <= ST_FRAME_PREP;
                    end else begin
                        send_dc          <= 1'b1;
                        send_byte        <= pixel_color[15:8];
                        send_hold_cs     <= 1'b1;
                        state_after_send <= ST_FRAME_PIX_LO;
                        send_issued      <= 1'b0;
                        state            <= ST_SEND_BYTE;
                    end
                end

                ST_FRAME_PIX_LO: begin
                    send_dc          <= 1'b1;
                    send_byte        <= pixel_color[7:0];
                    send_hold_cs     <= 1'b1;
                    state_after_send <= ST_FRAME_PIXEL_COMMIT;
                    send_issued      <= 1'b0;
                    state            <= ST_SEND_BYTE;
                end

                ST_FRAME_PIXEL_COMMIT: begin
                    pixels_left <= pixels_left - 1'b1;

                    if (pixel_x == TFT_W - 1) begin
                        pixel_x <= 7'd0;
                        pixel_y <= pixel_y + 1'b1;
                    end else begin
                        pixel_x <= pixel_x + 1'b1;
                    end

                    state <= ST_FRAME_PIX_HI;
                end

                // ------------------------- Shared send state -----------------
                ST_SEND_BYTE: begin
                    // Start one SPI byte transfer once, then wait for done pulse.
                    if (!send_issued && !tx_busy) begin
                        lcd_rs      <= send_dc;
                        lcd_cs      <= 1'b0;
                        tx_data     <= send_byte;
                        tx_start    <= 1'b1;
                        send_issued <= 1'b1;
                    end

                    if (send_issued && tx_done) begin
                        if (!send_hold_cs)
                            lcd_cs <= 1'b1;
                        state <= state_after_send;
                    end
                end

                default: begin // ST_DELAY
                    if (delay_cnt == 0)
                        state <= state_after_delay;
                    else
                        delay_cnt <= delay_cnt - 1'b1;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Debug LEDs
    // -------------------------------------------------------------------------
    // led[2:0] = active pattern index
    // led[3]   = init done flag
    assign led[2:0] = pattern_idx;
    assign led[3]   = init_done;

endmodule
