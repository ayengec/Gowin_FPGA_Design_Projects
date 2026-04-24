/*
 * Project   : Tang Primer 20K LED Chaser Smoke Test
 * File      : top_led_chaser.sv
 * Summary   : Knight-rider LEDs + UART heartbeat sentence with seconds counter.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated
 *
 * UART sentence format (once per second):
 *   Hello, ayengec UART test from macOS with knight rider project: XXXXXX seconds\r\n
 *
 * Notes:
 * - XXXXXX is a 6-digit BCD seconds counter (000001, 000002, ...).
 * - This file keeps the LED smoke-test behavior while adding UART visibility.
 */
module top_led_chaser #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int STEP_MS  = 100,
    parameter int BAUDRATE = 115200
) (
    input  logic       clk_27m,
    output logic [3:0] led,
    output logic       uart_tx
);
    // -------------------------------------------------------------------------
    // Power-on reset (short internal reset without external reset pin).
    // -------------------------------------------------------------------------
    logic        rst     = 1'b1;
    logic [15:0] por_cnt = '0;

    always_ff @(posedge clk_27m) begin
        if (!por_cnt[15]) begin
            por_cnt <= por_cnt + 1'b1;
            rst     <= 1'b1;
        end else begin
            rst     <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // 4-LED Knight Rider pattern.
    // -------------------------------------------------------------------------
    localparam int STEP_CYCLES = (CLK_HZ / 1000) * STEP_MS;
    localparam int STEP_CNT_W  = (STEP_CYCLES > 1) ? $clog2(STEP_CYCLES) : 1;

    logic [STEP_CNT_W-1:0] step_cnt = '0;
    logic [1:0]            pos      = 2'd0;
    logic                  dir      = 1'b0; // 0: move right, 1: move left

    always_ff @(posedge clk_27m) begin
        if (rst) begin
            step_cnt <= '0;
            pos      <= 2'd0;
            dir      <= 1'b0;
        end else begin
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
    end

    always_comb begin
        led = 4'b0000;
        led[pos] = 1'b1;
    end

    // -------------------------------------------------------------------------
    // 1-second tick generator.
    // -------------------------------------------------------------------------
    localparam int SEC_CYCLES = CLK_HZ;
    localparam int SEC_CNT_W  = (SEC_CYCLES > 1) ? $clog2(SEC_CYCLES) : 1;

    logic [SEC_CNT_W-1:0] sec_cnt;
    logic                 sec_tick;

    always_ff @(posedge clk_27m) begin
        if (rst) begin
            sec_cnt  <= '0;
            sec_tick <= 1'b0;
        end else begin
            if (sec_cnt == SEC_CYCLES - 1) begin
                sec_cnt  <= '0;
                sec_tick <= 1'b1;
            end else begin
                sec_cnt  <= sec_cnt + 1'b1;
                sec_tick <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Seconds counter in BCD (6 digits) so we can emit ASCII without division.
    // -------------------------------------------------------------------------
    function automatic logic [23:0] bcd_inc6(input logic [23:0] value);
        logic [23:0] next;
        begin
            next = value;

            if (value[3:0] != 4'd9) begin
                next[3:0] = value[3:0] + 1'b1;
            end else begin
                next[3:0] = 4'd0;
                if (value[7:4] != 4'd9) begin
                    next[7:4] = value[7:4] + 1'b1;
                end else begin
                    next[7:4] = 4'd0;
                    if (value[11:8] != 4'd9) begin
                        next[11:8] = value[11:8] + 1'b1;
                    end else begin
                        next[11:8] = 4'd0;
                        if (value[15:12] != 4'd9) begin
                            next[15:12] = value[15:12] + 1'b1;
                        end else begin
                            next[15:12] = 4'd0;
                            if (value[19:16] != 4'd9) begin
                                next[19:16] = value[19:16] + 1'b1;
                            end else begin
                                next[19:16] = 4'd0;
                                if (value[23:20] != 4'd9)
                                    next[23:20] = value[23:20] + 1'b1;
                                else
                                    next[23:20] = 4'd0;
                            end
                        end
                    end
                end
            end

            bcd_inc6 = next;
        end
    endfunction

    logic [23:0] sec_bcd;
    logic [23:0] sec_bcd_next;
    logic [23:0] tx_bcd_snapshot;

    always_comb begin
        sec_bcd_next = bcd_inc6(sec_bcd);
    end

    // -------------------------------------------------------------------------
    // UART sentence transmitter.
    // -------------------------------------------------------------------------
    localparam int MSG_LEN     = 79;
    localparam int MSG_IDX_W   = (MSG_LEN > 1) ? $clog2(MSG_LEN) : 1;

    // Explicit per-index byte ROM for maximum compatibility with synthesis tools.
    function automatic logic [7:0] msg_char(
        input logic [MSG_IDX_W-1:0] idx,
        input logic [23:0]          sec_bcd_snap
    );
        case (idx)
            0: msg_char = 8'h48; // H
            1: msg_char = 8'h65; // e
            2: msg_char = 8'h6C; // l
            3: msg_char = 8'h6C; // l
            4: msg_char = 8'h6F; // o
            5: msg_char = 8'h2C; // ,
            6: msg_char = 8'h20; // space
            7: msg_char = 8'h61; // a
            8: msg_char = 8'h79; // y
            9: msg_char = 8'h65; // e
            10: msg_char = 8'h6E; // n
            11: msg_char = 8'h67; // g
            12: msg_char = 8'h65; // e
            13: msg_char = 8'h63; // c
            14: msg_char = 8'h20; // space
            15: msg_char = 8'h55; // U
            16: msg_char = 8'h41; // A
            17: msg_char = 8'h52; // R
            18: msg_char = 8'h54; // T
            19: msg_char = 8'h20; // space
            20: msg_char = 8'h74; // t
            21: msg_char = 8'h65; // e
            22: msg_char = 8'h73; // s
            23: msg_char = 8'h74; // t
            24: msg_char = 8'h20; // space
            25: msg_char = 8'h66; // f
            26: msg_char = 8'h72; // r
            27: msg_char = 8'h6F; // o
            28: msg_char = 8'h6D; // m
            29: msg_char = 8'h20; // space
            30: msg_char = 8'h6D; // m
            31: msg_char = 8'h61; // a
            32: msg_char = 8'h63; // c
            33: msg_char = 8'h4F; // O
            34: msg_char = 8'h53; // S
            35: msg_char = 8'h20; // space
            36: msg_char = 8'h77; // w
            37: msg_char = 8'h69; // i
            38: msg_char = 8'h74; // t
            39: msg_char = 8'h68; // h
            40: msg_char = 8'h20; // space
            41: msg_char = 8'h6B; // k
            42: msg_char = 8'h6E; // n
            43: msg_char = 8'h69; // i
            44: msg_char = 8'h67; // g
            45: msg_char = 8'h68; // h
            46: msg_char = 8'h74; // t
            47: msg_char = 8'h20; // space
            48: msg_char = 8'h72; // r
            49: msg_char = 8'h69; // i
            50: msg_char = 8'h64; // d
            51: msg_char = 8'h65; // e
            52: msg_char = 8'h72; // r
            53: msg_char = 8'h20; // space
            54: msg_char = 8'h70; // p
            55: msg_char = 8'h72; // r
            56: msg_char = 8'h6F; // o
            57: msg_char = 8'h6A; // j
            58: msg_char = 8'h65; // e
            59: msg_char = 8'h63; // c
            60: msg_char = 8'h74; // t
            61: msg_char = 8'h3A; // :
            62: msg_char = 8'h20; // space
            63: msg_char = 8'h30 + sec_bcd_snap[23:20];
            64: msg_char = 8'h30 + sec_bcd_snap[19:16];
            65: msg_char = 8'h30 + sec_bcd_snap[15:12];
            66: msg_char = 8'h30 + sec_bcd_snap[11:8];
            67: msg_char = 8'h30 + sec_bcd_snap[7:4];
            68: msg_char = 8'h30 + sec_bcd_snap[3:0];
            69: msg_char = 8'h20; // space
            70: msg_char = 8'h73; // s
            71: msg_char = 8'h65; // e
            72: msg_char = 8'h63; // c
            73: msg_char = 8'h6F; // o
            74: msg_char = 8'h6E; // n
            75: msg_char = 8'h64; // d
            76: msg_char = 8'h73; // s
            77: msg_char = 8'h0D; // \r
            78: msg_char = 8'h0A; // \n
            default: msg_char = 8'h3F; // '?'
        endcase
    endfunction

    logic [7:0]             tx_data;
    logic                   tx_start;
    logic                   tx_busy;
    logic                   sending;
    logic [MSG_IDX_W-1:0]   msg_idx;

    always_ff @(posedge clk_27m) begin
        tx_start <= 1'b0; // default every cycle

        if (rst) begin
            sec_bcd          <= 24'h000000;
            tx_bcd_snapshot  <= 24'h000000;
            sending          <= 1'b0;
            msg_idx          <= '0;
            tx_data          <= 8'h00;
        end else begin
            // Keep the running seconds counter alive.
            if (sec_tick) begin
                sec_bcd <= sec_bcd_next;

                // Start one message per second if UART is free.
                if (!sending) begin
                    tx_bcd_snapshot <= sec_bcd_next;
                    sending         <= 1'b1;
                    msg_idx         <= '0;
                end
            end

            // Safe transmit handshake: wait until busy is low and the previous
            // start strobe is no longer asserted.
            if (sending && !tx_busy && !tx_start) begin
                tx_data <= msg_char(msg_idx, tx_bcd_snapshot);

                tx_start <= 1'b1;

                if (msg_idx == MSG_LEN - 1) begin
                    sending <= 1'b0;
                    msg_idx <= '0;
                end else begin
                    msg_idx <= msg_idx + 1'b1;
                end
            end
        end
    end

    uart_tx #(
        .CLK_HZ  (CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_uart_tx (
        .clk   (clk_27m),
        .rst   (rst),
        .start (tx_start),
        .data  (tx_data),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );
endmodule
