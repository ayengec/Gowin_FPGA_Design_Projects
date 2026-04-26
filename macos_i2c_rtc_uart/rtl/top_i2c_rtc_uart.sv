/*
 * Project   : macos_i2c_rtc_uart
 * File      : top_i2c_rtc_uart.sv
 * Summary   : DS3231 RTC over I2C with interactive UART menu on Tang Primer 20K.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-26
 *
 * UART Commands (type command, then press Enter):
 *   MENU or M      : show menu
 *   HELP or H      : show menu
 *   READ or R      : read RTC now and print formatted time/date
 *   RAW            : print raw RTC register bytes (hex)
 *   SET  or W      : calibration with YYMMDDHHMMSS
 *   FLOW or F      : start 1-second stream
 *   STOP or X      : stop stream
 *   STATUS or S    : print status
 */
module top_i2c_rtc_uart #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int BAUDRATE = 115200,
    parameter int I2C_HZ   = 100_000
) (
    input  logic       clk_27m,
    input  logic       rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    inout  tri         i2c_scl,
    inout  tri         i2c_sda,
    output logic [3:0] led
);
    // Internal active-high reset for submodules that use synchronous reset style.
    logic rst;
    assign rst = ~rst_n;

    // -------------------------------------------------------------------------
    // UART RX/TX instances.
    // -------------------------------------------------------------------------
    logic [7:0] rx_data;
    logic       rx_valid;

    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;

    uart_rx #(
        .CLK_HZ  (CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_uart_rx (
        .clk  (clk_27m),
        .rst  (rst),
        .rx   (uart_rx),
        .data (rx_data),
        .valid(rx_valid)
    );

    uart_tx #(
        .CLK_HZ  (CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_uart_tx (
        .clk  (clk_27m),
        .rst  (rst),
        .start(tx_start),
        .data (tx_data),
        .tx   (uart_tx),
        .busy (tx_busy)
    );

    // Protect against back-to-back start strobes while busy transitions.
    logic tx_can_send;
    assign tx_can_send = (!tx_busy) && (!tx_start);

    // -------------------------------------------------------------------------
    // I2C master instance (used only by RTC reader FSM).
    // -------------------------------------------------------------------------
    logic       i2c_cmd_valid;
    logic       i2c_cmd_ready;
    logic       i2c_cmd_start;
    logic       i2c_cmd_stop;
    logic       i2c_cmd_read;
    logic       i2c_cmd_read_nack;
    logic [7:0] i2c_cmd_wdata;

    logic       i2c_rsp_valid;
    logic       i2c_rsp_ready;
    logic [7:0] i2c_rsp_rdata;
    logic       i2c_rsp_ack_error;

    logic       i2c_busy;

    i2c_byte_master #(
        .CLK_HZ(CLK_HZ),
        .I2C_HZ(I2C_HZ)
    ) u_i2c_master (
        .clk          (clk_27m),
        .rst_n        (rst_n),
        .cmd_valid    (i2c_cmd_valid),
        .cmd_ready    (i2c_cmd_ready),
        .cmd_start    (i2c_cmd_start),
        .cmd_stop     (i2c_cmd_stop),
        .cmd_read     (i2c_cmd_read),
        .cmd_read_nack(i2c_cmd_read_nack),
        .cmd_wdata    (i2c_cmd_wdata),
        .rsp_valid    (i2c_rsp_valid),
        .rsp_ready    (i2c_rsp_ready),
        .rsp_rdata    (i2c_rsp_rdata),
        .rsp_ack_error(i2c_rsp_ack_error),
        .busy         (i2c_busy),
        .i2c_scl      (i2c_scl),
        .i2c_sda      (i2c_sda)
    );

    // -------------------------------------------------------------------------
    // RTC storage registers (DS3231 BCD values).
    // -------------------------------------------------------------------------
    logic       rtc_valid;
    logic [7:0] rtc_sec_bcd;
    logic [7:0] rtc_min_bcd;
    logic [7:0] rtc_hour_bcd;
    logic [7:0] rtc_date_bcd;
    logic [7:0] rtc_month_bcd;
    logic [7:0] rtc_year_bcd;

    // Mask helper wires to remove non-digit control bits.
    logic [7:0] sec_clean;
    logic [7:0] min_clean;
    logic [7:0] hour_clean;
    logic [7:0] date_clean;
    logic [7:0] month_clean;

    assign sec_clean   = rtc_sec_bcd   & 8'h7F;
    assign min_clean   = rtc_min_bcd   & 8'h7F;
    assign hour_clean  = rtc_hour_bcd  & 8'h3F;
    assign date_clean  = rtc_date_bcd  & 8'h3F;
    assign month_clean = rtc_month_bcd & 8'h1F;

    // -------------------------------------------------------------------------
    // Timebase: 1-second tick + short boot wait.
    // -------------------------------------------------------------------------
    logic [31:0] sec_cnt;
    logic        sec_tick;

    logic [24:0] boot_cnt;
    logic        boot_done;

    // -------------------------------------------------------------------------
    // UART command and print request flags.
    // -------------------------------------------------------------------------
    logic periodic_print_en;

    logic req_banner1;
    logic req_menu;
    logic req_status;
    logic req_time;
    logic req_raw;
    logic req_err;
    logic req_set_usage;
    logic req_set_ok;
    logic req_set_fail;

    // Command-wait flags: set by explicit commands, consumed when RTC read completes.
    logic wait_time_after_read;
    logic wait_raw_after_read;

    // UART command line buffer.
    localparam int CMD_MAX_CHARS = 32;
    logic [7:0] cmd_buf [0:CMD_MAX_CHARS-1];
    logic [5:0] cmd_len;

    // Parsed calibration BCD bytes.
    logic [7:0] set_year_bcd;
    logic [7:0] set_month_bcd;
    logic [7:0] set_date_bcd;
    logic [7:0] set_hour_bcd;
    logic [7:0] set_min_bcd;
    logic [7:0] set_sec_bcd;

    // -------------------------------------------------------------------------
    // RTC read engine state.
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        RTC_IDLE = 3'd0,
        RTC_PREP = 3'd1,
        RTC_SEND = 3'd2,
        RTC_WAIT = 3'd3,
        RTC_NEXT = 3'd4
    } rtc_state_t;

    rtc_state_t rtc_state;

    logic [3:0] rtc_step;
    logic       rtc_seq_error;
    logic       rtc_req_pending;
    logic       rtc_req_is_write;
    logic       rtc_mode_write;
    logic       rtc_done_pulse;
    logic       rtc_done_was_write;

    // I2C command staging for current RTC step.
    logic       rtc_tx_start;
    logic       rtc_tx_stop;
    logic       rtc_tx_read;
    logic       rtc_tx_read_nack;
    logic [7:0] rtc_tx_wdata;

    logic [7:0] rtc_last_rsp_data;
    logic       rtc_last_rsp_ack_error;

    // -------------------------------------------------------------------------
    // UART print FSM.
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        PR_IDLE    = 4'd0,
        PR_BANNER1 = 4'd1,
        PR_BANNER2 = 4'd2,
        PR_STATUS  = 4'd3,
        PR_TIME    = 4'd4,
        PR_RAW     = 4'd5,
        PR_ERR     = 4'd6,
        PR_SET_USAGE = 4'd7,
        PR_SET_OK    = 4'd8,
        PR_SET_FAIL  = 4'd9,
        PR_MENU1     = 4'd10,
        PR_MENU2     = 4'd11,
        PR_MENU3     = 4'd12,
        PR_MENU4     = 4'd13,
        PR_MENU5     = 4'd14,
        PR_MENU6     = 4'd15
    } print_state_t;

    print_state_t pr_state;
    logic [7:0]  pr_idx;

    logic [7:0] msg_len;
    logic [7:0] msg_char;

    // -------------------------------------------------------------------------
    // Text helper functions.
    // -------------------------------------------------------------------------
    function automatic logic [7:0] dec_ascii(input logic [3:0] nibble);
        if (nibble < 10)
            dec_ascii = 8'h30 + nibble;
        else
            dec_ascii = "?";
    endfunction

    function automatic logic [7:0] hex_ascii(input logic [3:0] nibble);
        if (nibble < 10)
            hex_ascii = 8'h30 + nibble;
        else
            hex_ascii = 8'h41 + (nibble - 10);
    endfunction

    function automatic logic [7:0] upper_ascii(input logic [7:0] ch);
        if ((ch >= "a") && (ch <= "z"))
            upper_ascii = ch - 8'd32;
        else
            upper_ascii = ch;
    endfunction

    function automatic logic ascii_is_digit(input logic [7:0] ch);
        ascii_is_digit = (ch >= "0") && (ch <= "9");
    endfunction

    function automatic logic [3:0] ascii_to_nibble(input logic [7:0] ch);
        ascii_to_nibble = ch - "0";
    endfunction

    function automatic logic bcd_byte_valid(input logic [7:0] bcd);
        bcd_byte_valid = (bcd[7:4] < 4'd10) && (bcd[3:0] < 4'd10);
    endfunction

    function automatic logic [7:0] bcd_to_bin(input logic [7:0] bcd);
        bcd_to_bin = ({4'b0000, bcd[7:4]} * 8'd10) + {4'b0000, bcd[3:0]};
    endfunction

    // -------------------------------------------------------------------------
    // Dynamic message byte selection for current print state/index.
    // -------------------------------------------------------------------------
    always_comb begin
        msg_len  = 8'd0;
        msg_char = 8'h20;

        unique case (pr_state)
            PR_BANNER1: begin
                // "AYENGEC RTC+UART READY\r\n"
                msg_len = 8'd24;
                case (pr_idx)
                    8'd0:  msg_char = "A";
                    8'd1:  msg_char = "Y";
                    8'd2:  msg_char = "E";
                    8'd3:  msg_char = "N";
                    8'd4:  msg_char = "G";
                    8'd5:  msg_char = "E";
                    8'd6:  msg_char = "C";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = "R";
                    8'd9:  msg_char = "T";
                    8'd10: msg_char = "C";
                    8'd11: msg_char = "+";
                    8'd12: msg_char = "U";
                    8'd13: msg_char = "A";
                    8'd14: msg_char = "R";
                    8'd15: msg_char = "T";
                    8'd16: msg_char = " ";
                    8'd17: msg_char = "R";
                    8'd18: msg_char = "E";
                    8'd19: msg_char = "A";
                    8'd20: msg_char = "D";
                    8'd21: msg_char = "Y";
                    8'd22: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_BANNER2: begin
                // "Type MENU + Enter\r\n"
                msg_len = 8'd19;
                case (pr_idx)
                    8'd0:  msg_char = "T";
                    8'd1:  msg_char = "y";
                    8'd2:  msg_char = "p";
                    8'd3:  msg_char = "e";
                    8'd4:  msg_char = " ";
                    8'd5:  msg_char = "M";
                    8'd6:  msg_char = "E";
                    8'd7:  msg_char = "N";
                    8'd8:  msg_char = "U";
                    8'd9:  msg_char = " ";
                    8'd10: msg_char = "+";
                    8'd11: msg_char = " ";
                    8'd12: msg_char = "E";
                    8'd13: msg_char = "n";
                    8'd14: msg_char = "t";
                    8'd15: msg_char = "e";
                    8'd16: msg_char = "r";
                    8'd17: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU1: begin
                // "MENU/M   : show menu\r\n"
                msg_len = 8'd22;
                case (pr_idx)
                    8'd0:  msg_char = "M";
                    8'd1:  msg_char = "E";
                    8'd2:  msg_char = "N";
                    8'd3:  msg_char = "U";
                    8'd4:  msg_char = "/";
                    8'd5:  msg_char = "M";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "s";
                    8'd12: msg_char = "h";
                    8'd13: msg_char = "o";
                    8'd14: msg_char = "w";
                    8'd15: msg_char = " ";
                    8'd16: msg_char = "m";
                    8'd17: msg_char = "e";
                    8'd18: msg_char = "n";
                    8'd19: msg_char = "u";
                    8'd20: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU2: begin
                // "READ/R   : read time once\r\n"
                msg_len = 8'd27;
                case (pr_idx)
                    8'd0:  msg_char = "R";
                    8'd1:  msg_char = "E";
                    8'd2:  msg_char = "A";
                    8'd3:  msg_char = "D";
                    8'd4:  msg_char = "/";
                    8'd5:  msg_char = "R";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "r";
                    8'd12: msg_char = "e";
                    8'd13: msg_char = "a";
                    8'd14: msg_char = "d";
                    8'd15: msg_char = " ";
                    8'd16: msg_char = "t";
                    8'd17: msg_char = "i";
                    8'd18: msg_char = "m";
                    8'd19: msg_char = "e";
                    8'd20: msg_char = " ";
                    8'd21: msg_char = "o";
                    8'd22: msg_char = "n";
                    8'd23: msg_char = "c";
                    8'd24: msg_char = "e";
                    8'd25: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU3: begin
                // "RAW      : read raw regs\r\n"
                msg_len = 8'd26;
                case (pr_idx)
                    8'd0:  msg_char = "R";
                    8'd1:  msg_char = "A";
                    8'd2:  msg_char = "W";
                    8'd3:  msg_char = " ";
                    8'd4:  msg_char = " ";
                    8'd5:  msg_char = " ";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "r";
                    8'd12: msg_char = "e";
                    8'd13: msg_char = "a";
                    8'd14: msg_char = "d";
                    8'd15: msg_char = " ";
                    8'd16: msg_char = "r";
                    8'd17: msg_char = "a";
                    8'd18: msg_char = "w";
                    8'd19: msg_char = " ";
                    8'd20: msg_char = "r";
                    8'd21: msg_char = "e";
                    8'd22: msg_char = "g";
                    8'd23: msg_char = "s";
                    8'd24: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU4: begin
                // "SET/W    : set YYMMDDHHMMSS\r\n"
                msg_len = 8'd29;
                case (pr_idx)
                    8'd0:  msg_char = "S";
                    8'd1:  msg_char = "E";
                    8'd2:  msg_char = "T";
                    8'd3:  msg_char = "/";
                    8'd4:  msg_char = "W";
                    8'd5:  msg_char = " ";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "s";
                    8'd12: msg_char = "e";
                    8'd13: msg_char = "t";
                    8'd14: msg_char = " ";
                    8'd15: msg_char = "Y";
                    8'd16: msg_char = "Y";
                    8'd17: msg_char = "M";
                    8'd18: msg_char = "M";
                    8'd19: msg_char = "D";
                    8'd20: msg_char = "D";
                    8'd21: msg_char = "H";
                    8'd22: msg_char = "H";
                    8'd23: msg_char = "M";
                    8'd24: msg_char = "M";
                    8'd25: msg_char = "S";
                    8'd26: msg_char = "S";
                    8'd27: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU5: begin
                // "FLOW/F   : start 1s stream\r\n"
                msg_len = 8'd28;
                case (pr_idx)
                    8'd0:  msg_char = "F";
                    8'd1:  msg_char = "L";
                    8'd2:  msg_char = "O";
                    8'd3:  msg_char = "W";
                    8'd4:  msg_char = "/";
                    8'd5:  msg_char = "F";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "s";
                    8'd12: msg_char = "t";
                    8'd13: msg_char = "a";
                    8'd14: msg_char = "r";
                    8'd15: msg_char = "t";
                    8'd16: msg_char = " ";
                    8'd17: msg_char = "1";
                    8'd18: msg_char = "s";
                    8'd19: msg_char = " ";
                    8'd20: msg_char = "s";
                    8'd21: msg_char = "t";
                    8'd22: msg_char = "r";
                    8'd23: msg_char = "e";
                    8'd24: msg_char = "a";
                    8'd25: msg_char = "m";
                    8'd26: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_MENU6: begin
                // "STOP/X   : stop stream  STATUS/S\r\n"
                msg_len = 8'd34;
                case (pr_idx)
                    8'd0:  msg_char = "S";
                    8'd1:  msg_char = "T";
                    8'd2:  msg_char = "O";
                    8'd3:  msg_char = "P";
                    8'd4:  msg_char = "/";
                    8'd5:  msg_char = "X";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = ":";
                    8'd10: msg_char = " ";
                    8'd11: msg_char = "s";
                    8'd12: msg_char = "t";
                    8'd13: msg_char = "o";
                    8'd14: msg_char = "p";
                    8'd15: msg_char = " ";
                    8'd16: msg_char = "s";
                    8'd17: msg_char = "t";
                    8'd18: msg_char = "r";
                    8'd19: msg_char = "e";
                    8'd20: msg_char = "a";
                    8'd21: msg_char = "m";
                    8'd22: msg_char = " ";
                    8'd23: msg_char = " ";
                    8'd24: msg_char = "S";
                    8'd25: msg_char = "T";
                    8'd26: msg_char = "A";
                    8'd27: msg_char = "T";
                    8'd28: msg_char = "U";
                    8'd29: msg_char = "S";
                    8'd30: msg_char = "/";
                    8'd31: msg_char = "S";
                    8'd32: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_STATUS: begin
                // "STATUS stream=XXX rtc=YYY\r\n"
                msg_len = 8'd27;
                case (pr_idx)
                    8'd0:  msg_char = "S";
                    8'd1:  msg_char = "T";
                    8'd2:  msg_char = "A";
                    8'd3:  msg_char = "T";
                    8'd4:  msg_char = "U";
                    8'd5:  msg_char = "S";
                    8'd6:  msg_char = " ";
                    8'd7:  msg_char = "s";
                    8'd8:  msg_char = "t";
                    8'd9:  msg_char = "r";
                    8'd10: msg_char = "e";
                    8'd11: msg_char = "a";
                    8'd12: msg_char = "m";
                    8'd13: msg_char = "=";
                    8'd14: msg_char = periodic_print_en ? "O" : "O";
                    8'd15: msg_char = periodic_print_en ? "N" : "F";
                    8'd16: msg_char = periodic_print_en ? " " : "F";
                    8'd17: msg_char = " ";
                    8'd18: msg_char = "r";
                    8'd19: msg_char = "t";
                    8'd20: msg_char = "c";
                    8'd21: msg_char = "=";
                    8'd22: msg_char = rtc_valid ? "O" : "E";
                    8'd23: msg_char = rtc_valid ? "K" : "R";
                    8'd24: msg_char = rtc_valid ? " " : "R";
                    8'd25: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_TIME: begin
                // "TIME 20YY-MM-DD HH:MM:SS\r\n"
                msg_len = 8'd26;
                case (pr_idx)
                    8'd0:  msg_char = "T";
                    8'd1:  msg_char = "I";
                    8'd2:  msg_char = "M";
                    8'd3:  msg_char = "E";
                    8'd4:  msg_char = " ";
                    8'd5:  msg_char = "2";
                    8'd6:  msg_char = "0";
                    8'd7:  msg_char = dec_ascii(rtc_year_bcd[7:4]);
                    8'd8:  msg_char = dec_ascii(rtc_year_bcd[3:0]);
                    8'd9:  msg_char = "-";
                    8'd10: msg_char = dec_ascii({3'b000, month_clean[4]});
                    8'd11: msg_char = dec_ascii(month_clean[3:0]);
                    8'd12: msg_char = "-";
                    8'd13: msg_char = dec_ascii(date_clean[5:4]);
                    8'd14: msg_char = dec_ascii(date_clean[3:0]);
                    8'd15: msg_char = " ";
                    8'd16: msg_char = dec_ascii(hour_clean[5:4]);
                    8'd17: msg_char = dec_ascii(hour_clean[3:0]);
                    8'd18: msg_char = ":";
                    8'd19: msg_char = dec_ascii(min_clean[6:4]);
                    8'd20: msg_char = dec_ascii(min_clean[3:0]);
                    8'd21: msg_char = ":";
                    8'd22: msg_char = dec_ascii(sec_clean[6:4]);
                    8'd23: msg_char = dec_ascii(sec_clean[3:0]);
                    8'd24: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_RAW: begin
                // "RAW S=xx M=xx H=xx D=xx MO=xx Y=xx\r\n"
                msg_len = 8'd36;
                case (pr_idx)
                    8'd0:  msg_char = "R";
                    8'd1:  msg_char = "A";
                    8'd2:  msg_char = "W";
                    8'd3:  msg_char = " ";
                    8'd4:  msg_char = "S";
                    8'd5:  msg_char = "=";
                    8'd6:  msg_char = hex_ascii(rtc_sec_bcd[7:4]);
                    8'd7:  msg_char = hex_ascii(rtc_sec_bcd[3:0]);
                    8'd8:  msg_char = " ";
                    8'd9:  msg_char = "M";
                    8'd10: msg_char = "=";
                    8'd11: msg_char = hex_ascii(rtc_min_bcd[7:4]);
                    8'd12: msg_char = hex_ascii(rtc_min_bcd[3:0]);
                    8'd13: msg_char = " ";
                    8'd14: msg_char = "H";
                    8'd15: msg_char = "=";
                    8'd16: msg_char = hex_ascii(rtc_hour_bcd[7:4]);
                    8'd17: msg_char = hex_ascii(rtc_hour_bcd[3:0]);
                    8'd18: msg_char = " ";
                    8'd19: msg_char = "D";
                    8'd20: msg_char = "=";
                    8'd21: msg_char = hex_ascii(rtc_date_bcd[7:4]);
                    8'd22: msg_char = hex_ascii(rtc_date_bcd[3:0]);
                    8'd23: msg_char = " ";
                    8'd24: msg_char = "M";
                    8'd25: msg_char = "O";
                    8'd26: msg_char = "=";
                    8'd27: msg_char = hex_ascii(rtc_month_bcd[7:4]);
                    8'd28: msg_char = hex_ascii(rtc_month_bcd[3:0]);
                    8'd29: msg_char = " ";
                    8'd30: msg_char = "Y";
                    8'd31: msg_char = "=";
                    8'd32: msg_char = hex_ascii(rtc_year_bcd[7:4]);
                    8'd33: msg_char = hex_ascii(rtc_year_bcd[3:0]);
                    8'd34: msg_char = 8'h0D;
                    8'd35: msg_char = 8'h0A;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_ERR: begin
                // "ERR CMD (MENU)\r\n"
                msg_len = 8'd16;
                case (pr_idx)
                    8'd0:  msg_char = "E";
                    8'd1:  msg_char = "R";
                    8'd2:  msg_char = "R";
                    8'd3:  msg_char = " ";
                    8'd4:  msg_char = "C";
                    8'd5:  msg_char = "M";
                    8'd6:  msg_char = "D";
                    8'd7:  msg_char = " ";
                    8'd8:  msg_char = "(";
                    8'd9:  msg_char = "M";
                    8'd10: msg_char = "E";
                    8'd11: msg_char = "N";
                    8'd12: msg_char = "U";
                    8'd13: msg_char = ")";
                    8'd14: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_SET_USAGE: begin
                // "SET/W YYMMDDHHMMSS + Enter\r\n"
                msg_len = 8'd28;
                case (pr_idx)
                    8'd0:  msg_char = "S";
                    8'd1:  msg_char = "E";
                    8'd2:  msg_char = "T";
                    8'd3:  msg_char = "/";
                    8'd4:  msg_char = "W";
                    8'd5:  msg_char = " ";
                    8'd6:  msg_char = "Y";
                    8'd7:  msg_char = "Y";
                    8'd8:  msg_char = "M";
                    8'd9:  msg_char = "M";
                    8'd10: msg_char = "D";
                    8'd11: msg_char = "D";
                    8'd12: msg_char = "H";
                    8'd13: msg_char = "H";
                    8'd14: msg_char = "M";
                    8'd15: msg_char = "M";
                    8'd16: msg_char = "S";
                    8'd17: msg_char = "S";
                    8'd18: msg_char = " ";
                    8'd19: msg_char = "+";
                    8'd20: msg_char = " ";
                    8'd21: msg_char = "E";
                    8'd22: msg_char = "n";
                    8'd23: msg_char = "t";
                    8'd24: msg_char = "e";
                    8'd25: msg_char = "r";
                    8'd26: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_SET_OK: begin
                // "RTC CALIB OK\r\n"
                msg_len = 8'd14;
                case (pr_idx)
                    8'd0:  msg_char = "R";
                    8'd1:  msg_char = "T";
                    8'd2:  msg_char = "C";
                    8'd3:  msg_char = " ";
                    8'd4:  msg_char = "C";
                    8'd5:  msg_char = "A";
                    8'd6:  msg_char = "L";
                    8'd7:  msg_char = "I";
                    8'd8:  msg_char = "B";
                    8'd9:  msg_char = " ";
                    8'd10: msg_char = "O";
                    8'd11: msg_char = "K";
                    8'd12: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            PR_SET_FAIL: begin
                // "RTC CALIB FAIL\r\n"
                msg_len = 8'd16;
                case (pr_idx)
                    8'd0:  msg_char = "R";
                    8'd1:  msg_char = "T";
                    8'd2:  msg_char = "C";
                    8'd3:  msg_char = " ";
                    8'd4:  msg_char = "C";
                    8'd5:  msg_char = "A";
                    8'd6:  msg_char = "L";
                    8'd7:  msg_char = "I";
                    8'd8:  msg_char = "B";
                    8'd9:  msg_char = " ";
                    8'd10: msg_char = "F";
                    8'd11: msg_char = "A";
                    8'd12: msg_char = "I";
                    8'd13: msg_char = "L";
                    8'd14: msg_char = 8'h0D;
                    default: msg_char = 8'h0A;
                endcase
            end

            default: begin
                msg_len  = 8'd0;
                msg_char = 8'h20;
            end
        endcase
    end

    // Device addresses: 7-bit DS3231(0x68) converted to 8-bit address phase.
    localparam logic [7:0] RTC_ADDR_W = 8'hD0;
    localparam logic [7:0] RTC_ADDR_R = 8'hD1;

    logic rx_is_printable;
    assign rx_is_printable = (rx_data >= 8'h20) && (rx_data <= 8'h7E);

    // -------------------------------------------------------------------------
    // Main sequential logic.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            // UART TX defaults.
            tx_data  <= 8'h00;
            tx_start <= 1'b0;

            // I2C handshake defaults.
            i2c_cmd_valid     <= 1'b0;
            i2c_rsp_ready     <= 1'b0;
            i2c_cmd_start     <= 1'b0;
            i2c_cmd_stop      <= 1'b0;
            i2c_cmd_read      <= 1'b0;
            i2c_cmd_read_nack <= 1'b0;
            i2c_cmd_wdata     <= 8'h00;

            // Timebase and boot.
            sec_cnt   <= '0;
            sec_tick  <= 1'b0;
            boot_cnt  <= '0;
            boot_done <= 1'b0;

            // Runtime mode flags.
            periodic_print_en <= 1'b0;

            // Message request defaults.
            req_banner1 <= 1'b1;
            req_menu    <= 1'b1;
            req_status  <= 1'b0;
            req_time    <= 1'b0;
            req_raw     <= 1'b0;
            req_err     <= 1'b0;
            req_set_usage <= 1'b0;
            req_set_ok    <= 1'b0;
            req_set_fail  <= 1'b0;

            wait_time_after_read <= 1'b0;
            wait_raw_after_read  <= 1'b0;

            cmd_len           <= 6'd0;
            set_year_bcd      <= 8'h26;
            set_month_bcd     <= 8'h01;
            set_date_bcd      <= 8'h01;
            set_hour_bcd      <= 8'h00;
            set_min_bcd       <= 8'h00;
            set_sec_bcd       <= 8'h00;

            // RTC registers.
            rtc_valid     <= 1'b0;
            rtc_sec_bcd   <= 8'h00;
            rtc_min_bcd   <= 8'h00;
            rtc_hour_bcd  <= 8'h00;
            rtc_date_bcd  <= 8'h01;
            rtc_month_bcd <= 8'h01;
            rtc_year_bcd  <= 8'h26;

            // RTC FSM defaults.
            rtc_state                <= RTC_IDLE;
            rtc_step                 <= 4'd0;
            rtc_seq_error            <= 1'b0;
            rtc_req_pending          <= 1'b0;
            rtc_req_is_write         <= 1'b0;
            rtc_mode_write           <= 1'b0;
            rtc_done_pulse           <= 1'b0;
            rtc_done_was_write       <= 1'b0;
            rtc_tx_start             <= 1'b0;
            rtc_tx_stop              <= 1'b0;
            rtc_tx_read              <= 1'b0;
            rtc_tx_read_nack         <= 1'b0;
            rtc_tx_wdata             <= 8'h00;
            rtc_last_rsp_data        <= 8'h00;
            rtc_last_rsp_ack_error   <= 1'b0;

            // Print FSM defaults.
            pr_state <= PR_IDLE;
            pr_idx   <= 8'd0;
        end else begin
            // Default one-cycle strobes.
            tx_start      <= 1'b0;
            i2c_cmd_valid <= 1'b0;
            i2c_rsp_ready <= 1'b0;
            sec_tick      <= 1'b0;
            rtc_done_pulse <= 1'b0;

            // -----------------------------------------------------------------
            // 1-second tick.
            // -----------------------------------------------------------------
            if (sec_cnt == CLK_HZ - 1) begin
                sec_cnt  <= '0;
                sec_tick <= 1'b1;
            end else begin
                sec_cnt <= sec_cnt + 1'b1;
            end

            // Short boot delay before first auto read.
            if (!boot_done) begin
                if (boot_cnt == (CLK_HZ / 5) - 1) begin
                    boot_done       <= 1'b1;
                    rtc_req_pending <= 1'b1;
                    rtc_req_is_write <= 1'b0;
                end else begin
                    boot_cnt <= boot_cnt + 1'b1;
                end
            end

            // Periodic refresh request (only when stream mode is enabled).
            if (boot_done && sec_tick && (cmd_len == 0) && periodic_print_en) begin
                rtc_req_pending <= 1'b1;
                rtc_req_is_write <= 1'b0;
            end

            // -----------------------------------------------------------------
            // UART command parsing (line-based):
            // User types a command line then presses Enter.
            // -----------------------------------------------------------------
            if (rx_valid) begin
                if ((rx_data == 8'h0D) || (rx_data == 8'h0A)) begin
                    // Enter: parse complete command line.
                    if (cmd_len != 0) begin
                        // MENU/M/HELP/H/?
                        if (
                            ((cmd_len == 6'd1) && ((cmd_buf[0] == "H") || (cmd_buf[0] == "?") || (cmd_buf[0] == "M"))) ||
                            ((cmd_len == 6'd4) && (cmd_buf[0] == "M") && (cmd_buf[1] == "E") &&
                             (cmd_buf[2] == "N") && (cmd_buf[3] == "U")) ||
                            ((cmd_len == 6'd4) && (cmd_buf[0] == "H") && (cmd_buf[1] == "E") &&
                             (cmd_buf[2] == "L") && (cmd_buf[3] == "P"))
                        ) begin
                            req_menu <= 1'b1;
                        end
                        // READ/R
                        else if (
                            ((cmd_len == 6'd1) && (cmd_buf[0] == "R")) ||
                            ((cmd_len == 6'd4) && (cmd_buf[0] == "R") && (cmd_buf[1] == "E") &&
                             (cmd_buf[2] == "A") && (cmd_buf[3] == "D"))
                        ) begin
                            wait_time_after_read <= 1'b1;
                            rtc_req_pending      <= 1'b1;
                            rtc_req_is_write     <= 1'b0;
                        end
                        // RAW
                        else if (
                            ((cmd_len == 6'd3) && (cmd_buf[0] == "R") && (cmd_buf[1] == "A") &&
                             (cmd_buf[2] == "W"))
                        ) begin
                            wait_raw_after_read <= 1'b1;
                            rtc_req_pending     <= 1'b1;
                            rtc_req_is_write    <= 1'b0;
                        end
                        // STATUS/S
                        else if (
                            ((cmd_len == 6'd1) && (cmd_buf[0] == "S")) ||
                            ((cmd_len == 6'd6) && (cmd_buf[0] == "S") && (cmd_buf[1] == "T") &&
                             (cmd_buf[2] == "A") && (cmd_buf[3] == "T") && (cmd_buf[4] == "U") &&
                             (cmd_buf[5] == "S"))
                        ) begin
                            req_status <= 1'b1;
                        end
                        // FLOW/F: start periodic stream and print immediately.
                        else if (
                            ((cmd_len == 6'd1) && (cmd_buf[0] == "F")) ||
                            ((cmd_len == 6'd4) && (cmd_buf[0] == "F") && (cmd_buf[1] == "L") &&
                             (cmd_buf[2] == "O") && (cmd_buf[3] == "W"))
                        ) begin
                            periodic_print_en <= 1'b1;
                            wait_time_after_read <= 1'b1;
                            rtc_req_pending      <= 1'b1;
                            rtc_req_is_write     <= 1'b0;
                            req_status        <= 1'b1;
                        end
                        // STOP/X: disable periodic stream.
                        else if (
                            ((cmd_len == 6'd1) && (cmd_buf[0] == "X")) ||
                            ((cmd_len == 6'd4) && (cmd_buf[0] == "S") && (cmd_buf[1] == "T") &&
                             (cmd_buf[2] == "O") && (cmd_buf[3] == "P"))
                        ) begin
                            periodic_print_en <= 1'b0;
                            wait_time_after_read <= 1'b0;
                            wait_raw_after_read  <= 1'b0;
                            req_time <= 1'b0;
                            req_raw  <= 1'b0;
                            req_menu <= 1'b1;
                        end
                        // SET/W without payload prints usage.
                        else if (
                            ((cmd_len == 6'd1) && (cmd_buf[0] == "W")) ||
                            ((cmd_len == 6'd3) && (cmd_buf[0] == "S") && (cmd_buf[1] == "E") &&
                             (cmd_buf[2] == "T"))
                        ) begin
                            req_set_usage <= 1'b1;
                        end
                        // SET/W calibration commands:
                        // W YYMMDDHHMMSS
                        // WYYMMDDHHMMSS
                        // SET YYMMDDHHMMSS
                        else if (
                            ((cmd_len == 6'd14) && (cmd_buf[0] == "W") && (cmd_buf[1] == " ") &&
                             ascii_is_digit(cmd_buf[2])  && ascii_is_digit(cmd_buf[3])  &&
                             ascii_is_digit(cmd_buf[4])  && ascii_is_digit(cmd_buf[5])  &&
                             ascii_is_digit(cmd_buf[6])  && ascii_is_digit(cmd_buf[7])  &&
                             ascii_is_digit(cmd_buf[8])  && ascii_is_digit(cmd_buf[9])  &&
                             ascii_is_digit(cmd_buf[10]) && ascii_is_digit(cmd_buf[11]) &&
                             ascii_is_digit(cmd_buf[12]) && ascii_is_digit(cmd_buf[13]))
                        ) begin
                            if (
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[4]),  ascii_to_nibble(cmd_buf[5])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])}) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[4]),  ascii_to_nibble(cmd_buf[5])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[4]),  ascii_to_nibble(cmd_buf[5])})  <= 8'd12) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])})  <= 8'd31) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])})  <= 8'd23) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])}) <= 8'd59) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])}) <= 8'd59)
                            ) begin
                                set_year_bcd  <= {ascii_to_nibble(cmd_buf[2]),  ascii_to_nibble(cmd_buf[3])};
                                set_month_bcd <= {ascii_to_nibble(cmd_buf[4]),  ascii_to_nibble(cmd_buf[5])};
                                set_date_bcd  <= {ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])};
                                set_hour_bcd  <= {ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])};
                                set_min_bcd   <= {ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])};
                                set_sec_bcd   <= {ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])};
                                rtc_req_pending      <= 1'b1;
                                rtc_req_is_write     <= 1'b1;
                                wait_time_after_read <= 1'b0;
                                wait_raw_after_read  <= 1'b0;
                            end else begin
                                req_set_usage <= 1'b1;
                            end
                        end else if (
                            ((cmd_len == 6'd13) && (cmd_buf[0] == "W") &&
                             ascii_is_digit(cmd_buf[1])  && ascii_is_digit(cmd_buf[2])  &&
                             ascii_is_digit(cmd_buf[3])  && ascii_is_digit(cmd_buf[4])  &&
                             ascii_is_digit(cmd_buf[5])  && ascii_is_digit(cmd_buf[6])  &&
                             ascii_is_digit(cmd_buf[7])  && ascii_is_digit(cmd_buf[8])  &&
                             ascii_is_digit(cmd_buf[9])  && ascii_is_digit(cmd_buf[10]) &&
                             ascii_is_digit(cmd_buf[11]) && ascii_is_digit(cmd_buf[12]))
                        ) begin
                            if (
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[3]),  ascii_to_nibble(cmd_buf[4])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[5]),  ascii_to_nibble(cmd_buf[6])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[7]),  ascii_to_nibble(cmd_buf[8])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[9]),  ascii_to_nibble(cmd_buf[10])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[11]), ascii_to_nibble(cmd_buf[12])}) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[3]),  ascii_to_nibble(cmd_buf[4])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[3]),  ascii_to_nibble(cmd_buf[4])})  <= 8'd12) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[5]),  ascii_to_nibble(cmd_buf[6])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[5]),  ascii_to_nibble(cmd_buf[6])})  <= 8'd31) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[7]),  ascii_to_nibble(cmd_buf[8])})  <= 8'd23) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[9]),  ascii_to_nibble(cmd_buf[10])}) <= 8'd59) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[11]), ascii_to_nibble(cmd_buf[12])}) <= 8'd59)
                            ) begin
                                set_year_bcd  <= {ascii_to_nibble(cmd_buf[1]),  ascii_to_nibble(cmd_buf[2])};
                                set_month_bcd <= {ascii_to_nibble(cmd_buf[3]),  ascii_to_nibble(cmd_buf[4])};
                                set_date_bcd  <= {ascii_to_nibble(cmd_buf[5]),  ascii_to_nibble(cmd_buf[6])};
                                set_hour_bcd  <= {ascii_to_nibble(cmd_buf[7]),  ascii_to_nibble(cmd_buf[8])};
                                set_min_bcd   <= {ascii_to_nibble(cmd_buf[9]),  ascii_to_nibble(cmd_buf[10])};
                                set_sec_bcd   <= {ascii_to_nibble(cmd_buf[11]), ascii_to_nibble(cmd_buf[12])};
                                rtc_req_pending      <= 1'b1;
                                rtc_req_is_write     <= 1'b1;
                                wait_time_after_read <= 1'b0;
                                wait_raw_after_read  <= 1'b0;
                            end else begin
                                req_set_usage <= 1'b1;
                            end
                        end else if (
                            ((cmd_len == 6'd16) && (cmd_buf[0] == "S") && (cmd_buf[1] == "E") &&
                             (cmd_buf[2] == "T") && (cmd_buf[3] == " ") &&
                             ascii_is_digit(cmd_buf[4])  && ascii_is_digit(cmd_buf[5])  &&
                             ascii_is_digit(cmd_buf[6])  && ascii_is_digit(cmd_buf[7])  &&
                             ascii_is_digit(cmd_buf[8])  && ascii_is_digit(cmd_buf[9])  &&
                             ascii_is_digit(cmd_buf[10]) && ascii_is_digit(cmd_buf[11]) &&
                             ascii_is_digit(cmd_buf[12]) && ascii_is_digit(cmd_buf[13]) &&
                             ascii_is_digit(cmd_buf[14]) && ascii_is_digit(cmd_buf[15]))
                        ) begin
                            if (
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])}) &&
                                bcd_byte_valid({ascii_to_nibble(cmd_buf[14]), ascii_to_nibble(cmd_buf[15])}) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])})  <= 8'd12) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])})  >= 8'd1) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])})  <= 8'd31) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])}) <= 8'd23) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])}) <= 8'd59) &&
                                (bcd_to_bin({ascii_to_nibble(cmd_buf[14]), ascii_to_nibble(cmd_buf[15])}) <= 8'd59)
                            ) begin
                                set_year_bcd  <= {ascii_to_nibble(cmd_buf[4]),  ascii_to_nibble(cmd_buf[5])};
                                set_month_bcd <= {ascii_to_nibble(cmd_buf[6]),  ascii_to_nibble(cmd_buf[7])};
                                set_date_bcd  <= {ascii_to_nibble(cmd_buf[8]),  ascii_to_nibble(cmd_buf[9])};
                                set_hour_bcd  <= {ascii_to_nibble(cmd_buf[10]), ascii_to_nibble(cmd_buf[11])};
                                set_min_bcd   <= {ascii_to_nibble(cmd_buf[12]), ascii_to_nibble(cmd_buf[13])};
                                set_sec_bcd   <= {ascii_to_nibble(cmd_buf[14]), ascii_to_nibble(cmd_buf[15])};
                                rtc_req_pending      <= 1'b1;
                                rtc_req_is_write     <= 1'b1;
                                wait_time_after_read <= 1'b0;
                                wait_raw_after_read  <= 1'b0;
                            end else begin
                                req_set_usage <= 1'b1;
                            end
                        end
                        // Unknown command line
                        else begin
                            req_err <= 1'b1;
                        end
                    end
                    cmd_len <= 6'd0;
                end else if ((rx_data == 8'h08) || (rx_data == 8'h7F)) begin
                    // Backspace support.
                    if (cmd_len != 0)
                        cmd_len <= cmd_len - 1'b1;
                end else if (rx_is_printable) begin
                    // Ignore leading spaces for friendlier CLI behavior.
                    if ((cmd_len == 0) && (rx_data == 8'h20)) begin
                    end else if (cmd_len < CMD_MAX_CHARS) begin
                        cmd_buf[cmd_len] <= upper_ascii(rx_data);
                        cmd_len <= cmd_len + 1'b1;
                    end else begin
                        req_err <= 1'b1;
                    end
                end else begin
                    // Ignore non-printable control characters.
                end
            end

            // -----------------------------------------------------------------
            // RTC FSM + I2C command flow.
            // Read sequence:
            // 0: START + WADDR
            // 1: write pointer 0x00
            // 2: START + RADDR (repeated start)
            // 3..9: read sec,min,hour,dow,date,month,year (step 9 with NACK+STOP)
            //
            // Write (calibration) sequence:
            // 0: START + WADDR
            // 1: write pointer 0x00
            // 2..8: write sec,min,hour,dow,date,month,year (step 8 with STOP)
            // -----------------------------------------------------------------
            case (rtc_state)
                RTC_IDLE: begin
                    if (rtc_req_pending) begin
                        rtc_req_pending <= 1'b0;
                        rtc_step        <= 4'd0;
                        rtc_seq_error   <= 1'b0;
                        rtc_mode_write  <= rtc_req_is_write;
                        rtc_state       <= RTC_PREP;
                    end
                end

                RTC_PREP: begin
                    if (rtc_mode_write) begin
                        case (rtc_step)
                            4'd0: begin
                                rtc_tx_start     <= 1'b1;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= RTC_ADDR_W;
                            end

                            4'd1: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= 8'h00; // seconds register pointer
                            end

                            4'd2: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= (set_sec_bcd & 8'h7F); // CH bit forced low
                            end

                            4'd3: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= (set_min_bcd & 8'h7F);
                            end

                            4'd4: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= (set_hour_bcd & 8'h3F); // 24h format
                            end

                            4'd5: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= 8'h01; // day-of-week fixed to 1
                            end

                            4'd6: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= (set_date_bcd & 8'h3F);
                            end

                            4'd7: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= (set_month_bcd & 8'h1F); // century bit low
                            end

                            default: begin // step 8
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b1;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= set_year_bcd;
                            end
                        endcase
                    end else begin
                        case (rtc_step)
                            4'd0: begin
                                rtc_tx_start     <= 1'b1;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= RTC_ADDR_W;
                            end

                            4'd1: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= 8'h00;
                            end

                            4'd2: begin
                                rtc_tx_start     <= 1'b1;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b0;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= RTC_ADDR_R;
                            end

                            4'd9: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b1;
                                rtc_tx_read      <= 1'b1;
                                rtc_tx_read_nack <= 1'b1;
                                rtc_tx_wdata     <= 8'h00;
                            end

                            default: begin
                                rtc_tx_start     <= 1'b0;
                                rtc_tx_stop      <= 1'b0;
                                rtc_tx_read      <= 1'b1;
                                rtc_tx_read_nack <= 1'b0;
                                rtc_tx_wdata     <= 8'h00;
                            end
                        endcase
                    end

                    rtc_state <= RTC_SEND;
                end

                RTC_SEND: begin
                    if (i2c_cmd_ready) begin
                        i2c_cmd_start     <= rtc_tx_start;
                        i2c_cmd_stop      <= rtc_tx_stop;
                        i2c_cmd_read      <= rtc_tx_read;
                        i2c_cmd_read_nack <= rtc_tx_read_nack;
                        i2c_cmd_wdata     <= rtc_tx_wdata;
                        i2c_cmd_valid     <= 1'b1;
                        rtc_state         <= RTC_WAIT;
                    end
                end

                RTC_WAIT: begin
                    if (i2c_rsp_valid) begin
                        i2c_rsp_ready          <= 1'b1;
                        rtc_last_rsp_data      <= i2c_rsp_rdata;
                        rtc_last_rsp_ack_error <= i2c_rsp_ack_error;
                        rtc_state              <= RTC_NEXT;
                    end
                end

                RTC_NEXT: begin
                    if (rtc_mode_write) begin
                        if (rtc_last_rsp_ack_error)
                            rtc_seq_error <= 1'b1;

                        if (rtc_step == 4'd8) begin
                            rtc_valid          <= ~(rtc_seq_error || rtc_last_rsp_ack_error);
                            rtc_done_pulse     <= 1'b1;
                            rtc_done_was_write <= 1'b1;
                            rtc_state          <= RTC_IDLE;
                        end else begin
                            rtc_step  <= rtc_step + 1'b1;
                            rtc_state <= RTC_PREP;
                        end
                    end else begin
                        // Write-side ACK checks for address/pointer phase.
                        if ((rtc_step <= 4'd2) && rtc_last_rsp_ack_error)
                            rtc_seq_error <= 1'b1;

                        // Capture selected read bytes.
                        case (rtc_step)
                            4'd3: rtc_sec_bcd   <= rtc_last_rsp_data;
                            4'd4: rtc_min_bcd   <= rtc_last_rsp_data;
                            4'd5: rtc_hour_bcd  <= rtc_last_rsp_data;
                            4'd7: rtc_date_bcd  <= rtc_last_rsp_data;
                            4'd8: rtc_month_bcd <= rtc_last_rsp_data;
                            4'd9: rtc_year_bcd  <= rtc_last_rsp_data;
                            default: begin
                            end
                        endcase

                        if (rtc_step == 4'd9) begin
                            rtc_valid          <= ~rtc_seq_error;
                            rtc_done_pulse     <= 1'b1;
                            rtc_done_was_write <= 1'b0;
                            rtc_state          <= RTC_IDLE;
                        end else begin
                            rtc_step  <= rtc_step + 1'b1;
                            rtc_state <= RTC_PREP;
                        end
                    end
                end

                default: rtc_state <= RTC_IDLE;
            endcase

            // -----------------------------------------------------------------
            // Post-operation action mapping.
            // -----------------------------------------------------------------
            if (rtc_done_pulse) begin
                if (rtc_done_was_write) begin
                    if (rtc_valid) begin
                        req_set_ok <= 1'b1;
                        // Auto-read after calibration so terminal shows new time.
                        wait_time_after_read <= 1'b1;
                        rtc_req_pending      <= 1'b1;
                        rtc_req_is_write     <= 1'b0;
                    end else begin
                        req_set_fail <= 1'b1;
                    end
                end else begin
                    if (wait_raw_after_read) begin
                        req_raw <= 1'b1;
                        wait_raw_after_read <= 1'b0;
                    end

                    if (wait_time_after_read) begin
                        req_time <= 1'b1;
                        wait_time_after_read <= 1'b0;
                    end

                    if (!wait_raw_after_read && !wait_time_after_read && periodic_print_en)
                        req_time <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // UART print FSM. Sends one byte whenever TX is ready.
            // -----------------------------------------------------------------
            if (pr_state == PR_IDLE) begin
                pr_idx <= 8'd0;

                if (req_banner1) begin
                    req_banner1 <= 1'b0;
                    pr_state    <= PR_BANNER1;
                end else if (req_menu) begin
                    req_menu <= 1'b0;
                    pr_state <= PR_MENU1;
                end else if (req_status) begin
                    req_status <= 1'b0;
                    pr_state   <= PR_STATUS;
                end else if (req_raw) begin
                    req_raw  <= 1'b0;
                    pr_state <= PR_RAW;
                end else if (req_time) begin
                    req_time <= 1'b0;
                    pr_state <= PR_TIME;
                end else if (req_set_usage) begin
                    req_set_usage <= 1'b0;
                    pr_state      <= PR_SET_USAGE;
                end else if (req_set_ok) begin
                    req_set_ok <= 1'b0;
                    pr_state   <= PR_SET_OK;
                end else if (req_set_fail) begin
                    req_set_fail <= 1'b0;
                    pr_state     <= PR_SET_FAIL;
                end else if (req_err) begin
                    req_err  <= 1'b0;
                    pr_state <= PR_ERR;
                end
            end else begin
                if (tx_can_send) begin
                    tx_data  <= msg_char;
                    tx_start <= 1'b1;

                    if (pr_idx == msg_len - 1) begin
                        pr_idx <= 8'd0;

                        if (pr_state == PR_BANNER1)
                            pr_state <= PR_BANNER2;
                        else if (pr_state == PR_MENU1)
                            pr_state <= PR_MENU2;
                        else if (pr_state == PR_MENU2)
                            pr_state <= PR_MENU3;
                        else if (pr_state == PR_MENU3)
                            pr_state <= PR_MENU4;
                        else if (pr_state == PR_MENU4)
                            pr_state <= PR_MENU5;
                        else if (pr_state == PR_MENU5)
                            pr_state <= PR_MENU6;
                        else
                            pr_state <= PR_IDLE;
                    end else begin
                        pr_idx <= pr_idx + 1'b1;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // LEDs for quick hardware diagnostics.
    // -------------------------------------------------------------------------
    assign led[0] = sec_cnt[24];             // heartbeat
    assign led[1] = rtc_valid;               // RTC comm looks good
    assign led[2] = periodic_print_en;       // stream mode
    assign led[3] = (rtc_state != RTC_IDLE); // RTC engine busy

endmodule
