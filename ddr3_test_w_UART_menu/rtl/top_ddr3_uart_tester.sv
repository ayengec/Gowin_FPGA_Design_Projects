/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : top_ddr3_uart_tester.sv
 * Summary   : Top-level integration for UART shell + real DDR3 test backend.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-23
 *
 * Integration strategy:
 * - Keep UART/control plane fully operational from day one.
 * - Keep DDR3 pin-compatible top module shape.
 * - Uses real Gowin DDR3 backend (PLL + DDR3 controller wrapper).
 */
module top_ddr3_uart_tester #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int BAUDRATE = 115200,
    parameter int ADDR_W   = 25,
    parameter int DATA_W   = 32
) (
    input  logic        clk_27m,
    input  logic        rst_n,

    input  logic        uart_rx,
    output logic        uart_tx,

    output logic [3:0]  led,

    // DDR3 physical interface pins.
    output logic [2:0]  ddr_bank,
    output logic [13:0] ddr_addr,
    output logic        ddr_odt,
    output logic        ddr_cke,
    output logic        ddr_we_n,
    output logic        ddr_cas_n,
    output logic        ddr_ras_n,
    output logic [1:0]  ddr_dm,
    output logic        ddr_ck,
    output logic        ddr_ck_n,
    output logic        ddr_reset_n,
    inout  wire  [1:0]  ddr_dqs,
    inout  wire  [1:0]  ddr_dqs_n,
    inout  wire  [15:0] ddr_dq,
    output logic        ddr_cs_n
);
    logic rst = 1'b1;
    logic [15:0] por_cnt = '0;

    // UART byte channel wires.
    logic [7:0] uart_rx_data;
    logic       uart_rx_valid;
    logic [7:0] uart_tx_data;
    logic       uart_tx_start;
    logic       uart_tx_busy;

    // Shell -> engine command wires.
    logic              eng_cmd_valid;
    logic              eng_cmd_ready;
    logic [3:0]        eng_cmd_code;
    logic [ADDR_W-1:0] eng_cmd_addr_word;
    logic [ADDR_W-1:0] eng_cmd_len_words;
    logic [DATA_W-1:0] eng_cmd_wdata;
    logic [7:0]        eng_cmd_pattern;
    logic [DATA_W-1:0] eng_cmd_seed;

    // Engine -> shell status wires.
    logic              eng_busy;
    logic              eng_done;
    logic              eng_cmd_ok;
    logic [DATA_W-1:0] eng_read_data;

    logic [31:0]       stat_total_reads;
    logic [31:0]       stat_total_writes;
    logic [31:0]       stat_error_count;
    logic [ADDR_W-1:0] stat_first_err_addr;
    logic [DATA_W-1:0] stat_first_err_exp;
    logic [DATA_W-1:0] stat_first_err_got;

    // Engine <-> backend memory transaction wires.
    logic              mem_req_valid;
    logic              mem_req_ready;
    logic              mem_req_write;
    logic [ADDR_W-1:0] mem_req_addr_word;
    logic [DATA_W-1:0] mem_req_wdata;

    logic              mem_rsp_valid;
    logic              mem_rsp_ok;
    logic [DATA_W-1:0] mem_rsp_rdata;

    logic              ddr_calib_done;

    // Heartbeat counter for simple life indicator.
    logic [24:0] heart_cnt;

    // Reset generator:
    // - external reset pin (rst_n, active-low) is now honored
    // - after reset release, keep an extra POR hold for ~2.4 ms
    always_ff @(posedge clk_27m) begin
        if (!rst_n) begin
            por_cnt <= '0;
            rst     <= 1'b1;
        end else if (!por_cnt[15]) begin
            por_cnt <= por_cnt + 1'b1;
            rst     <= 1'b1;
        end else begin
            rst     <= 1'b0;
        end
    end

    always_ff @(posedge clk_27m) begin
        if (rst) heart_cnt <= '0;
        else     heart_cnt <= heart_cnt + 1'b1;
    end

    // UART PHY wrapper.
    uart_core #(
        .CLK_HZ(CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_uart_core (
        .clk      (clk_27m),
        .rst      (rst),
        .rx       (uart_rx),
        .tx       (uart_tx),
        .rx_data  (uart_rx_data),
        .rx_valid (uart_rx_valid),
        .tx_data  (uart_tx_data),
        .tx_start (uart_tx_start),
        .tx_busy  (uart_tx_busy)
    );

    // UART command parser/formatter.
    cmd_shell_ddr3 #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W)
    ) u_cmd_shell_ddr3 (
        .clk               (clk_27m),
        .rst               (rst),
        .uart_rx_data      (uart_rx_data),
        .uart_rx_valid     (uart_rx_valid),
        .uart_tx_data      (uart_tx_data),
        .uart_tx_start     (uart_tx_start),
        .uart_tx_busy      (uart_tx_busy),
        .ddr_calib_done    (ddr_calib_done),
        .eng_cmd_valid     (eng_cmd_valid),
        .eng_cmd_ready     (eng_cmd_ready),
        .eng_cmd_code      (eng_cmd_code),
        .eng_cmd_addr_word (eng_cmd_addr_word),
        .eng_cmd_len_words (eng_cmd_len_words),
        .eng_cmd_wdata     (eng_cmd_wdata),
        .eng_cmd_pattern   (eng_cmd_pattern),
        .eng_cmd_seed      (eng_cmd_seed),
        .eng_busy          (eng_busy),
        .eng_done          (eng_done),
        .eng_cmd_ok        (eng_cmd_ok),
        .eng_read_data     (eng_read_data),
        .stat_total_reads  (stat_total_reads),
        .stat_total_writes (stat_total_writes),
        .stat_error_count  (stat_error_count),
        .stat_first_err_addr(stat_first_err_addr),
        .stat_first_err_exp(stat_first_err_exp),
        .stat_first_err_got(stat_first_err_got)
    );

    // Test engine.
    ddr_test_engine #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W)
    ) u_ddr_test_engine (
        .clk               (clk_27m),
        .rst               (rst),
        .cmd_valid         (eng_cmd_valid),
        .cmd_ready         (eng_cmd_ready),
        .cmd_code          (eng_cmd_code),
        .cmd_addr_word     (eng_cmd_addr_word),
        .cmd_len_words     (eng_cmd_len_words),
        .cmd_wdata         (eng_cmd_wdata),
        .cmd_pattern       (eng_cmd_pattern),
        .cmd_seed          (eng_cmd_seed),
        .busy              (eng_busy),
        .done              (eng_done),
        .cmd_ok            (eng_cmd_ok),
        .read_data         (eng_read_data),
        .mem_req_valid     (mem_req_valid),
        .mem_req_ready     (mem_req_ready),
        .mem_req_write     (mem_req_write),
        .mem_req_addr_word (mem_req_addr_word),
        .mem_req_wdata     (mem_req_wdata),
        .mem_rsp_valid     (mem_rsp_valid),
        .mem_rsp_ok        (mem_rsp_ok),
        .mem_rsp_rdata     (mem_rsp_rdata),
        .stat_total_reads  (stat_total_reads),
        .stat_total_writes (stat_total_writes),
        .stat_error_count  (stat_error_count),
        .stat_first_err_addr(stat_first_err_addr),
        .stat_first_err_exp(stat_first_err_exp),
        .stat_first_err_got(stat_first_err_got)
    );

    // Real DDR3 backend:
    // - includes official Gowin rPLL
    // - includes official DDR3_Memory_Interface_Top wrapper
    // - bridges 32-bit tester requests to 128-bit app interface
    ddr_backend_gowin #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W)
    ) u_ddr_backend_gowin (
        .clk            (clk_27m),
        .rst            (rst),
        .req_valid      (mem_req_valid),
        .req_ready      (mem_req_ready),
        .req_write      (mem_req_write),
        .req_addr_word  (mem_req_addr_word),
        .req_wdata      (mem_req_wdata),
        .rsp_valid      (mem_rsp_valid),
        .rsp_ok         (mem_rsp_ok),
        .rsp_rdata      (mem_rsp_rdata),
        .calib_done     (ddr_calib_done),
        .ddr_bank       (ddr_bank),
        .ddr_addr       (ddr_addr),
        .ddr_odt        (ddr_odt),
        .ddr_cke        (ddr_cke),
        .ddr_we_n       (ddr_we_n),
        .ddr_cas_n      (ddr_cas_n),
        .ddr_ras_n      (ddr_ras_n),
        .ddr_dm         (ddr_dm),
        .ddr_ck         (ddr_ck),
        .ddr_ck_n       (ddr_ck_n),
        .ddr_reset_n    (ddr_reset_n),
        .ddr_dqs        (ddr_dqs),
        .ddr_dqs_n      (ddr_dqs_n),
        .ddr_dq         (ddr_dq),
        .ddr_cs_n       (ddr_cs_n)
    );

    // LED diagnostics:
    // LED0 = calibration done
    // LED1 = engine busy
    // LED2 = sticky "error happened at least once"
    // LED3 = heartbeat
    logic error_sticky;

    always_ff @(posedge clk_27m) begin
        if (rst) begin
            error_sticky <= 1'b0;
        end else if (stat_error_count != 0) begin
            error_sticky <= 1'b1;
        end
    end

    assign led[0] = ddr_calib_done;
    assign led[1] = eng_busy;
    assign led[2] = error_sticky;
    assign led[3] = heart_cnt[24];

endmodule
