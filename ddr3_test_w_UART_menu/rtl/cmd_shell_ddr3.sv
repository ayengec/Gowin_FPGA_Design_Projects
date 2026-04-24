/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : cmd_shell_ddr3.sv
 * Summary   : UART command shell that parses user commands and prints reports.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated
 *
 * Notes:
 * - Input is case-insensitive for command keywords.
 * - Addresses are byte addresses and must be 4-byte aligned.
 * - Command execution is serialized; one command runs at a time.
 */
module cmd_shell_ddr3 #(
    parameter int ADDR_W = 25,
    parameter int DATA_W = 32,
    parameter int BOOT_BANNER_DELAY_CYCLES = 540_000
) (
    input  logic                 clk,
    input  logic                 rst,

    // UART byte RX/TX interface.
    input  logic [7:0]           uart_rx_data,
    input  logic                 uart_rx_valid,
    output logic [7:0]           uart_tx_data,
    output logic                 uart_tx_start,
    input  logic                 uart_tx_busy,

    // DDR status from backend.
    input  logic                 ddr_calib_done,

    // Command channel to test engine.
    output logic                 eng_cmd_valid,
    input  logic                 eng_cmd_ready,
    output logic [3:0]           eng_cmd_code,
    output logic [ADDR_W-1:0]    eng_cmd_addr_word,
    output logic [ADDR_W-1:0]    eng_cmd_len_words,
    output logic [DATA_W-1:0]    eng_cmd_wdata,
    output logic [7:0]           eng_cmd_pattern,
    output logic [DATA_W-1:0]    eng_cmd_seed,

    // Completion/status from test engine.
    input  logic                 eng_busy,
    input  logic                 eng_done,
    input  logic                 eng_cmd_ok,
    input  logic [DATA_W-1:0]    eng_read_data,

    input  logic [31:0]          stat_total_reads,
    input  logic [31:0]          stat_total_writes,
    input  logic [31:0]          stat_error_count,
    input  logic [ADDR_W-1:0]    stat_first_err_addr,
    input  logic [DATA_W-1:0]    stat_first_err_exp,
    input  logic [DATA_W-1:0]    stat_first_err_got
);
    // Command code mirror (must match ddr_test_engine).
    localparam logic [3:0] CMD_NOP = 4'h0;
    localparam logic [3:0] CMD_MR  = 4'h1;
    localparam logic [3:0] CMD_MW  = 4'h2;
    localparam logic [3:0] CMD_MB  = 4'h3;
    localparam logic [3:0] CMD_BB  = 4'h4;
    localparam logic [3:0] CMD_CLR = 4'h5;

    localparam int LINE_MAX = 96;
    localparam int TX_MAX   = 1024;

    logic [7:0] line_buf [0:LINE_MAX-1];
    logic [6:0] line_len;
    logic       line_ready;

    logic [7:0] tx_buf [0:TX_MAX-1];
    logic [9:0] tx_len;
    logic [9:0] tx_idx;
    logic       tx_active;
    logic       boot_banner_pending;
    logic [$clog2(BOOT_BANNER_DELAY_CYCLES+1)-1:0] boot_delay_cnt;

    logic       wait_engine;
    logic [3:0] wait_cmd;
    logic       dump_active;
    logic       dump_pending_issue;
    logic [ADDR_W-1:0] dump_addr_word;
    logic [ADDR_W-1:0] dump_left_words;
    logic [ADDR_W-1:0] dump_last_addr_word;
    logic       fulltest_active;
    logic [31:0] fulltest_reads_base;
    logic [31:0] fulltest_writes_base;
    logic [31:0] fulltest_errors_base;

    // Lowercase helper for case-insensitive command words.
    function automatic logic [7:0] to_lower(input logic [7:0] c);
        if ((c >= "A") && (c <= "Z")) to_lower = c + 8'd32;
        else to_lower = c;
    endfunction

    // Hex decoder with valid bit in bit[4].
    function automatic logic [4:0] hex5(input logic [7:0] c);
        if ((c >= "0") && (c <= "9")) begin
            hex5[4]   = 1'b1;
            hex5[3:0] = c - "0";
        end else if ((c >= "a") && (c <= "f")) begin
            hex5[4]   = 1'b1;
            hex5[3:0] = c - "a" + 4'd10;
        end else if ((c >= "A") && (c <= "F")) begin
            hex5[4]   = 1'b1;
            hex5[3:0] = c - "A" + 4'd10;
        end else begin
            hex5 = 5'b0;
        end
    endfunction

    function automatic logic [7:0] nibble_ascii(input logic [3:0] n);
        if (n < 4'd10) nibble_ascii = "0" + n;
        else           nibble_ascii = "A" + (n - 4'd10);
    endfunction

    always_ff @(posedge clk) begin
        integer i;
        integer k;
        integer cmd_len;

        logic        parse_ok;
        logic [4:0]  h;
        logic [31:0] addr32;
        logic [31:0] data32;
        logic [31:0] len32;
        logic [31:0] err_addr32;
        logic [31:0] byte_addr32;
        logic [31:0] delta_reads32;
        logic [31:0] delta_writes32;
        logic [31:0] delta_errors32;
        logic [7:0]  pat8;

        if (rst) begin
            // Initialize text buffers to known values so synthesis does not
            // report undriven bits for entries that are not explicitly written
            // by a specific command path.
            for (i = 0; i < LINE_MAX; i = i + 1)
                line_buf[i] <= 8'h00;
            for (i = 0; i < TX_MAX; i = i + 1)
                tx_buf[i] <= 8'h20;

            line_len     <= '0;
            line_ready   <= 1'b0;
            tx_len       <= '0;
            tx_idx       <= '0;
            tx_active    <= 1'b0;
            // Show startup banner after a short delay.
            boot_banner_pending <= 1'b1;
            boot_delay_cnt <= '0;
            wait_engine  <= 1'b0;
            wait_cmd     <= CMD_NOP;
            dump_active  <= 1'b0;
            dump_pending_issue <= 1'b0;
            dump_addr_word <= '0;
            dump_left_words <= '0;
            dump_last_addr_word <= '0;
            fulltest_active <= 1'b0;
            fulltest_reads_base <= '0;
            fulltest_writes_base <= '0;
            fulltest_errors_base <= '0;

            eng_cmd_valid    <= 1'b0;
            eng_cmd_code     <= CMD_NOP;
            eng_cmd_addr_word <= '0;
            eng_cmd_len_words <= '0;
            eng_cmd_wdata    <= '0;
            eng_cmd_pattern  <= 8'h00;
            eng_cmd_seed     <= 32'h1ACE_B00C;

            uart_tx_start <= 1'b0;
            uart_tx_data  <= 8'h00;

            // Startup banner (sent once after reset delay).
            tx_buf[0]  <= "*";
            tx_buf[1]  <= "*";
            tx_buf[2]  <= "*";
            tx_buf[3]  <= " ";
            tx_buf[4]  <= "A";
            tx_buf[5]  <= "Y";
            tx_buf[6]  <= "E";
            tx_buf[7]  <= "N";
            tx_buf[8]  <= "G";
            tx_buf[9]  <= "E";
            tx_buf[10] <= "C";
            tx_buf[11] <= " ";
            tx_buf[12] <= "D";
            tx_buf[13] <= "D";
            tx_buf[14] <= "R";
            tx_buf[15] <= "3";
            tx_buf[16] <= " ";
            tx_buf[17] <= "G";
            tx_buf[18] <= "2";
            tx_buf[19] <= "W";
            tx_buf[20] <= "A";
            tx_buf[21] <= " ";
            tx_buf[22] <= "T";
            tx_buf[23] <= "E";
            tx_buf[24] <= "S";
            tx_buf[25] <= "T";
            tx_buf[26] <= " ";
            tx_buf[27] <= "P";
            tx_buf[28] <= "R";
            tx_buf[29] <= "O";
            tx_buf[30] <= "J";
            tx_buf[31] <= "E";
            tx_buf[32] <= "C";
            tx_buf[33] <= "T";
            tx_buf[34] <= " ";
            tx_buf[35] <= "*";
            tx_buf[36] <= "*";
            tx_buf[37] <= "*";
            tx_buf[38] <= 8'h0D;
            tx_buf[39] <= 8'h0A;
            tx_buf[40] <= "T";
            tx_buf[41] <= "y";
            tx_buf[42] <= "p";
            tx_buf[43] <= "e";
            tx_buf[44] <= " ";
            tx_buf[45] <= "H";
            tx_buf[46] <= "E";
            tx_buf[47] <= "L";
            tx_buf[48] <= "P";
            tx_buf[49] <= " ";
            tx_buf[50] <= "f";
            tx_buf[51] <= "o";
            tx_buf[52] <= "r";
            tx_buf[53] <= " ";
            tx_buf[54] <= "m";
            tx_buf[55] <= "e";
            tx_buf[56] <= "n";
            tx_buf[57] <= "u";
            tx_buf[58] <= 8'h0D;
            tx_buf[59] <= 8'h0A;
            tx_buf[60] <= ">";
            tx_buf[61] <= " ";
            tx_len      <= 10'd62;
            tx_idx      <= '0;
            tx_active   <= 1'b0;
        end else begin
            // One-cycle strobe defaults.
            eng_cmd_valid <= 1'b0;
            uart_tx_start <= 1'b0;

            // Delay first banner transmit so USB-UART side can settle.
            if (boot_banner_pending && !tx_active && !wait_engine) begin
                if (boot_delay_cnt == BOOT_BANNER_DELAY_CYCLES - 1) begin
                    tx_active <= 1'b1;
                    tx_idx    <= '0;
                    boot_banner_pending <= 1'b0;
                end else begin
                    boot_delay_cnt <= boot_delay_cnt + 1'b1;
                end
            end

            // TX serializer: one byte whenever UART transmitter is idle.
            // Guard with !uart_tx_start as well to avoid the "every other byte"
            // drop race when tx_busy becomes visible one cycle later.
            if (tx_active && !uart_tx_busy && !uart_tx_start) begin
                if (tx_idx < tx_len) begin
                    uart_tx_data  <= tx_buf[tx_idx];
                    uart_tx_start <= 1'b1;
                    tx_idx        <= tx_idx + 1'b1;
                end else begin
                    tx_active <= 1'b0;
                    tx_idx    <= '0;
                    tx_len    <= '0;
                end
            end

            // For multi-read dump, issue the next read command after current line
            // is fully transmitted to keep output and command flow deterministic.
            if (dump_pending_issue && !tx_active && !wait_engine && eng_cmd_ready) begin
                eng_cmd_code      <= CMD_MR;
                eng_cmd_addr_word <= dump_addr_word;
                eng_cmd_len_words <= 25'd1;
                eng_cmd_wdata     <= '0;
                eng_cmd_pattern   <= 8'h00;
                eng_cmd_seed      <= 32'h1ACE_B00C;
                eng_cmd_valid     <= 1'b1;
                wait_engine       <= 1'b1;
                wait_cmd          <= CMD_MR;

                dump_last_addr_word <= dump_addr_word;
                dump_addr_word      <= dump_addr_word + 1'b1;
                dump_left_words     <= dump_left_words - 1'b1;
                dump_pending_issue  <= 1'b0;
            end

            // Collect a command line while we are not in engine wait and not in
            // active dump mode.
            if (uart_rx_valid && !line_ready && !wait_engine && !dump_active) begin
                if ((uart_rx_data == 8'h0D) || (uart_rx_data == 8'h0A)) begin
                    line_ready <= 1'b1;
                end else if (line_len < LINE_MAX-1) begin
                    // Ignore leading spaces to make command entry more tolerant.
                    if (!((line_len == 0) && (uart_rx_data == " "))) begin
                        line_buf[line_len] <= uart_rx_data;
                        line_len           <= line_len + 1'b1;
                    end
                end
            end

            // Engine completion path.
            if (wait_engine && eng_done && !tx_active) begin
                wait_engine <= 1'b0;
                k = 0;

                if (dump_active) begin
                    if (eng_cmd_ok) begin
                        // Print one line: AAAAAAAA=DDDDDDDD
                        byte_addr32 = 32'h0000_0000;
                        byte_addr32[ADDR_W+1:2] = dump_last_addr_word;
                        for (i = 0; i < 8; i = i + 1) begin
                            tx_buf[k] <= nibble_ascii(byte_addr32[31 - i*4 -: 4]);
                            k = k + 1;
                        end
                        tx_buf[k] <= "="; k = k + 1;
                        for (i = 0; i < 8; i = i + 1) begin
                            tx_buf[k] <= nibble_ascii(eng_read_data[31 - i*4 -: 4]);
                            k = k + 1;
                        end
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                    end

                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;

                    if (!eng_cmd_ok) begin
                        // Abort dump on first read error.
                        dump_active <= 1'b0;
                        dump_pending_issue <= 1'b0;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                    end else if (dump_left_words != 0) begin
                        // More words to read.
                        dump_pending_issue <= 1'b1;
                    end else begin
                        // Dump complete, return prompt.
                        dump_active <= 1'b0;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                    end
                end else if (fulltest_active && (wait_cmd == CMD_BB)) begin
                    delta_reads32  = stat_total_reads  - fulltest_reads_base;
                    delta_writes32 = stat_total_writes - fulltest_writes_base;
                    delta_errors32 = stat_error_count  - fulltest_errors_base;

                    tx_buf[k] <= "F"; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "T"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "T"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "O"; k = k + 1;
                    tx_buf[k] <= "N"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;

                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(delta_reads32[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "W"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(delta_writes32[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(delta_errors32[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;

                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "T"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    if (eng_cmd_ok && (delta_errors32 == 0)) begin
                        tx_buf[k] <= "P"; k = k + 1;
                        tx_buf[k] <= "A"; k = k + 1;
                        tx_buf[k] <= "S"; k = k + 1;
                        tx_buf[k] <= "S"; k = k + 1;
                    end else begin
                        tx_buf[k] <= "F"; k = k + 1;
                        tx_buf[k] <= "A"; k = k + 1;
                        tx_buf[k] <= "I"; k = k + 1;
                        tx_buf[k] <= "L"; k = k + 1;
                    end
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;

                    fulltest_active <= 1'b0;
                end else begin
                    if (wait_cmd == CMD_MR) begin
                        if (eng_cmd_ok) begin
                            tx_buf[k] <= "M"; k = k + 1;
                            tx_buf[k] <= "R"; k = k + 1;
                            tx_buf[k] <= "="; k = k + 1;
                            for (i = 0; i < 8; i = i + 1) begin
                                tx_buf[k] <= nibble_ascii(eng_read_data[31 - i*4 -: 4]);
                                k = k + 1;
                            end
                        end else begin
                            tx_buf[k] <= "E"; k = k + 1;
                            tx_buf[k] <= "R"; k = k + 1;
                            tx_buf[k] <= "R"; k = k + 1;
                        end
                    end else begin
                        if (eng_cmd_ok) begin
                            tx_buf[k] <= "O"; k = k + 1;
                            tx_buf[k] <= "K"; k = k + 1;
                        end else begin
                            tx_buf[k] <= "E"; k = k + 1;
                            tx_buf[k] <= "R"; k = k + 1;
                            tx_buf[k] <= "R"; k = k + 1;
                        end
                    end

                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;
                end

                tx_len    <= k[9:0];
                tx_idx    <= '0;
                tx_active <= 1'b1;
            end

            // Parse and execute line when transport path is free.
            if (line_ready && !tx_active && !wait_engine && !dump_active) begin
                parse_ok = 1'b1;
                addr32   = 32'h0;
                data32   = 32'h0;
                len32    = 32'h0;
                err_addr32 = {{(32-ADDR_W){1'b0}}, stat_first_err_addr};
                pat8     = 8'h00;
                k        = 0;
                cmd_len  = 0;

                // Synthesis-safe trailing trim (fixed bounded loop).
                // cmd_len becomes index of last non-space char + 1.
                for (i = 0; i < LINE_MAX; i = i + 1) begin
                    if ((i < line_len) && (line_buf[i] != " "))
                        cmd_len = i + 1;
                end

                if (cmd_len == 0) begin
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;

                    tx_len    <= k[9:0];
                    tx_idx    <= '0;
                    tx_active <= 1'b1;
                end
                else if ((cmd_len == 4) &&
                         (to_lower(line_buf[0]) == "h") &&
                         (to_lower(line_buf[1]) == "e") &&
                         (to_lower(line_buf[2]) == "l") &&
                         (to_lower(line_buf[3]) == "p")) begin
                    // Multi-line help menu with short, practical descriptions.
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "3"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "T"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "N"; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "h"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "p"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "h"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "h"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "C"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "Y"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "3"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "-"; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "p"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "W"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "3"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "-"; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "k"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "+"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "v"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "y"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "p"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "4"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "g"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "("; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "/"; k = k + 1;
                    tx_buf[k] <= "3"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "/"; k = k + 1;
                    tx_buf[k] <= "6"; k = k + 1;
                    tx_buf[k] <= "4"; k = k + 1;
                    tx_buf[k] <= "/"; k = k + 1;
                    tx_buf[k] <= "9"; k = k + 1;
                    tx_buf[k] <= "6"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= ")"; k = k + 1;
                    tx_buf[k] <= ","; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "+"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "v"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "y"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "F"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "1"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "8"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "h"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "p"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "4"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "F"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "1"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "8"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "w"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "h"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "p"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "/"; k = k + 1;
                    tx_buf[k] <= "W"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "/"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "f"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "C"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "m"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "v"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "u"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "g"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "c"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "Z"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "O"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "1"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "O"; k = k + 1;
                    tx_buf[k] <= "N"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "2"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "3"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "5"; k = k + 1;
                    tx_buf[k] <= "5"; k = k + 1;
                    tx_buf[k] <= "5"; k = k + 1;
                    tx_buf[k] <= "5"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "4"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "0"; k = k + 1;
                    tx_buf[k] <= "5"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "F"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "N"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= ":"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "y"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= "r"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= ","; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "a"; k = k + 1;
                    tx_buf[k] <= "l"; k = k + 1;
                    tx_buf[k] <= "i"; k = k + 1;
                    tx_buf[k] <= "g"; k = k + 1;
                    tx_buf[k] <= "n"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "d"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "o"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "4"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "b"; k = k + 1;
                    tx_buf[k] <= "y"; k = k + 1;
                    tx_buf[k] <= "t"; k = k + 1;
                    tx_buf[k] <= "e"; k = k + 1;
                    tx_buf[k] <= "s"; k = k + 1;
                    tx_buf[k] <= "."; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;

                    tx_len    <= k[9:0];
                    tx_idx    <= '0;
                    tx_active <= 1'b1;
                end
                else if ((cmd_len == 2) &&
                         (to_lower(line_buf[0]) == "m") &&
                         (to_lower(line_buf[1]) == "i")) begin
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "I"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "C"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "L"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= ddr_calib_done ? "1" : "0"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "B"; k = k + 1;
                    tx_buf[k] <= "U"; k = k + 1;
                    tx_buf[k] <= "S"; k = k + 1;
                    tx_buf[k] <= "Y"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    tx_buf[k] <= eng_busy ? "1" : "0"; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;

                    tx_len    <= k[9:0];
                    tx_idx    <= '0;
                    tx_active <= 1'b1;
                end
                else if ((cmd_len == 2) &&
                         (to_lower(line_buf[0]) == "s") &&
                         (to_lower(line_buf[1]) == "t")) begin
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(stat_total_reads[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "W"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(stat_total_writes[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(stat_error_count[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;

                    tx_buf[k] <= "F"; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "A"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(err_addr32[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "X"; k = k + 1;
                    tx_buf[k] <= "P"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(stat_first_err_exp[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "G"; k = k + 1;
                    tx_buf[k] <= "O"; k = k + 1;
                    tx_buf[k] <= "T"; k = k + 1;
                    tx_buf[k] <= "="; k = k + 1;
                    for (i = 0; i < 8; i = i + 1) begin
                        tx_buf[k] <= nibble_ascii(stat_first_err_got[31 - i*4 -: 4]);
                        k = k + 1;
                    end
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;

                    tx_len    <= k[9:0];
                    tx_idx    <= '0;
                    tx_active <= 1'b1;
                end
                else if ((cmd_len == 3) &&
                         (to_lower(line_buf[0]) == "c") &&
                         (to_lower(line_buf[1]) == "l") &&
                         (to_lower(line_buf[2]) == "r")) begin
                    if (eng_cmd_ready) begin
                        eng_cmd_code      <= CMD_CLR;
                        eng_cmd_addr_word <= '0;
                        eng_cmd_len_words <= '0;
                        eng_cmd_wdata     <= '0;
                        eng_cmd_pattern   <= 8'h00;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_CLR;
                    end
                end
                else if ((cmd_len == 11) &&
                         (to_lower(line_buf[0]) == "m") &&
                         (to_lower(line_buf[1]) == "r") &&
                         (line_buf[2] == " ")) begin
                    // mr AAAAAAAA
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[3+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        addr32 = {addr32[27:0], h[3:0]};
                    end

                    if (parse_ok && (addr32[1:0] == 2'b00) && eng_cmd_ready) begin
                        eng_cmd_code      <= CMD_MR;
                        eng_cmd_addr_word <= addr32[31:2];
                        eng_cmd_len_words <= 25'd1;
                        eng_cmd_wdata     <= '0;
                        eng_cmd_pattern   <= 8'h00;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_MR;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= " "; k = k + 1;
                        tx_buf[k] <= parse_ok ? "A" : "H"; k = k + 1;
                        tx_buf[k] <= parse_ok ? "L" : "E"; k = k + 1;
                        tx_buf[k] <= parse_ok ? "I" : "X"; k = k + 1;
                        tx_buf[k] <= parse_ok ? "G" : " "; k = k + 1;
                        tx_buf[k] <= parse_ok ? "N" : " "; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 20) &&
                         (to_lower(line_buf[0]) == "m") &&
                         (to_lower(line_buf[1]) == "d") &&
                         (line_buf[2] == " ") &&
                         (line_buf[11] == " ")) begin
                    // md AAAAAAAA LLLLLLLL
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[3+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        addr32 = {addr32[27:0], h[3:0]};
                    end
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[12+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        len32 = {len32[27:0], h[3:0]};
                    end

                    if (parse_ok && (addr32[1:0] == 2'b00)) begin
                        dump_active      <= 1'b1;
                        dump_pending_issue <= 1'b1;
                        dump_addr_word   <= addr32[31:2];
                        dump_left_words  <= (len32[ADDR_W-1:0] == 0) ? {{(ADDR_W-1){1'b0}},1'b1} : len32[ADDR_W-1:0];
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 20) &&
                         (to_lower(line_buf[0]) == "m") &&
                         (to_lower(line_buf[1]) == "w") &&
                         (line_buf[2] == " ") &&
                         (line_buf[11] == " ")) begin
                    // mw AAAAAAAA DDDDDDDD
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[3+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        addr32 = {addr32[27:0], h[3:0]};
                    end
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[12+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        data32 = {data32[27:0], h[3:0]};
                    end

                    if (parse_ok && (addr32[1:0] == 2'b00) && eng_cmd_ready) begin
                        eng_cmd_code      <= CMD_MW;
                        eng_cmd_addr_word <= addr32[31:2];
                        eng_cmd_len_words <= 25'd1;
                        eng_cmd_wdata     <= data32;
                        eng_cmd_pattern   <= 8'h00;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_MW;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 23) &&
                         (to_lower(line_buf[0]) == "m") &&
                         (to_lower(line_buf[1]) == "b") &&
                         (line_buf[2] == " ") &&
                         (line_buf[11] == " ") &&
                         (line_buf[20] == " ")) begin
                    // mb AAAAAAAA LLLLLLLL PP
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[3+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        addr32 = {addr32[27:0], h[3:0]};
                    end
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[12+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        len32 = {len32[27:0], h[3:0]};
                    end
                    h = hex5(line_buf[21]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[7:4] = h[3:0];
                    h = hex5(line_buf[22]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[3:0] = h[3:0];

                    if (parse_ok && (addr32[1:0] == 2'b00) && (pat8 <= 8'h05) && eng_cmd_ready) begin
                        eng_cmd_code      <= CMD_MB;
                        eng_cmd_addr_word <= addr32[31:2];
                        eng_cmd_len_words <= (len32[ADDR_W-1:0] == 0) ? 25'd1 : len32[ADDR_W-1:0];
                        eng_cmd_wdata     <= 32'h0000_0000;
                        eng_cmd_pattern   <= pat8;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_MB;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 2) &&
                         (to_lower(line_buf[0]) == "f") &&
                         (to_lower(line_buf[1]) == "a")) begin
                    // fa  -> full DDR test, default pattern 04 (address data)
                    if (eng_cmd_ready) begin
                        fulltest_active   <= 1'b1;
                        fulltest_reads_base  <= stat_total_reads;
                        fulltest_writes_base <= stat_total_writes;
                        fulltest_errors_base <= stat_error_count;

                        eng_cmd_code      <= CMD_BB;
                        eng_cmd_addr_word <= '0;
                        eng_cmd_len_words <= 25'h0800000; // 8M words = 32MB per region
                        eng_cmd_wdata     <= 32'h0000_0000;
                        eng_cmd_pattern   <= 8'h04;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_BB;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= " "; k = k + 1;
                        tx_buf[k] <= "B"; k = k + 1;
                        tx_buf[k] <= "U"; k = k + 1;
                        tx_buf[k] <= "S"; k = k + 1;
                        tx_buf[k] <= "Y"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 5) &&
                         (to_lower(line_buf[0]) == "f") &&
                         (to_lower(line_buf[1]) == "a") &&
                         (line_buf[2] == " ")) begin
                    // fa PP -> full DDR test with selected pattern
                    h = hex5(line_buf[3]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[7:4] = h[3:0];
                    h = hex5(line_buf[4]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[3:0] = h[3:0];

                    if (parse_ok && (pat8 <= 8'h05) && eng_cmd_ready) begin
                        fulltest_active   <= 1'b1;
                        fulltest_reads_base  <= stat_total_reads;
                        fulltest_writes_base <= stat_total_writes;
                        fulltest_errors_base <= stat_error_count;

                        eng_cmd_code      <= CMD_BB;
                        eng_cmd_addr_word <= '0;
                        eng_cmd_len_words <= 25'h0800000; // 8M words = 32MB per region
                        eng_cmd_wdata     <= 32'h0000_0000;
                        eng_cmd_pattern   <= pat8;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_BB;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else if ((cmd_len == 14) &&
                         (to_lower(line_buf[0]) == "b") &&
                         (to_lower(line_buf[1]) == "b") &&
                         (line_buf[2] == " ") &&
                         (line_buf[11] == " ")) begin
                    // bb LLLLLLLL PP
                    for (i = 0; i < 8; i = i + 1) begin
                        h = hex5(line_buf[3+i]);
                        if (!h[4]) parse_ok = 1'b0;
                        len32 = {len32[27:0], h[3:0]};
                    end
                    h = hex5(line_buf[12]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[7:4] = h[3:0];
                    h = hex5(line_buf[13]);
                    if (!h[4]) parse_ok = 1'b0;
                    pat8[3:0] = h[3:0];

                    if (parse_ok && (pat8 <= 8'h05) && eng_cmd_ready) begin
                        eng_cmd_code      <= CMD_BB;
                        eng_cmd_addr_word <= '0;
                        eng_cmd_len_words <= (len32[ADDR_W-1:0] == 0) ? 25'd1 : len32[ADDR_W-1:0];
                        eng_cmd_wdata     <= 32'h0000_0000;
                        eng_cmd_pattern   <= pat8;
                        eng_cmd_seed      <= 32'h1ACE_B00C;
                        eng_cmd_valid     <= 1'b1;
                        wait_engine       <= 1'b1;
                        wait_cmd          <= CMD_BB;
                    end else begin
                        tx_buf[k] <= "E"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= "R"; k = k + 1;
                        tx_buf[k] <= 8'h0D; k = k + 1;
                        tx_buf[k] <= 8'h0A; k = k + 1;
                        tx_buf[k] <= ">";  k = k + 1;
                        tx_buf[k] <= " ";  k = k + 1;
                        tx_len    <= k[9:0];
                        tx_idx    <= '0;
                        tx_active <= 1'b1;
                    end
                end
                else begin
                    tx_buf[k] <= "E"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= "R"; k = k + 1;
                    tx_buf[k] <= " "; k = k + 1;
                    tx_buf[k] <= "C"; k = k + 1;
                    tx_buf[k] <= "M"; k = k + 1;
                    tx_buf[k] <= "D"; k = k + 1;
                    tx_buf[k] <= 8'h0D; k = k + 1;
                    tx_buf[k] <= 8'h0A; k = k + 1;
                    tx_buf[k] <= ">";  k = k + 1;
                    tx_buf[k] <= " ";  k = k + 1;

                    tx_len    <= k[9:0];
                    tx_idx    <= '0;
                    tx_active <= 1'b1;
                end

                line_len   <= '0;
                line_ready <= 1'b0;
            end
        end
    end
endmodule
