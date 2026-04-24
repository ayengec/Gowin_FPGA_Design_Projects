/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : ddr_backend_gowin.sv
 * Summary   : Real DDR3 backend using Gowin DDR3 IP with safe clock crossing.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-23
 *
 * Why this version:
 * - UART/test engine runs on 27 MHz clock.
 * - Gowin DDR3 app interface is driven in DDR user clock domain (clk_out).
 * - We bridge these two domains with a one-request mailbox handshake.
 */
module ddr_backend_gowin #(
    parameter int ADDR_W = 25,
    parameter int DATA_W = 32
) (
    input  logic                 clk,
    input  logic                 rst,

    // Simple request/response bus from test engine (clk domain).
    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic                 req_write,
    input  logic [ADDR_W-1:0]    req_addr_word,
    input  logic [DATA_W-1:0]    req_wdata,

    output logic                 rsp_valid,
    output logic                 rsp_ok,
    output logic [DATA_W-1:0]    rsp_rdata,

    output logic                 calib_done,

    // DDR3 physical pins.
    output logic [2:0]           ddr_bank,
    output logic [13:0]          ddr_addr,
    output logic                 ddr_odt,
    output logic                 ddr_cke,
    output logic                 ddr_we_n,
    output logic                 ddr_cas_n,
    output logic                 ddr_ras_n,
    output logic [1:0]           ddr_dm,
    output logic                 ddr_ck,
    output logic                 ddr_ck_n,
    output logic                 ddr_reset_n,
    inout  wire  [1:0]           ddr_dqs,
    inout  wire  [1:0]           ddr_dqs_n,
    inout  wire  [15:0]          ddr_dq,
    output logic                 ddr_cs_n
);
    localparam logic [2:0] DDR_CMD_WR = 3'b000;
    localparam logic [2:0] DDR_CMD_RD = 3'b001;
    localparam logic [5:0] DDR_BURST_SINGLE = 6'd0;

    typedef enum logic [2:0] {
        A_IDLE,
        A_WR_WAIT_READY,
        A_WR_RESPOND,
        A_RD_WAIT_READY,
        A_RD_WAIT_DATA
    } app_state_t;

    app_state_t app_state;

    // -------------------------------------------------------------------------
    // DDR controller clocks and interface signals.
    // -------------------------------------------------------------------------
    logic memory_clk;
    logic pll_lock;
    logic app_clk_out;

    logic [5:0]   app_burst_number;
    logic [2:0]   app_cmd;
    logic         app_cmd_en;
    logic [27:0]  app_addr;
    logic [127:0] app_wr_data;
    logic         app_wr_data_en;
    logic         app_wr_data_end;
    logic [15:0]  app_wr_data_mask;

    logic         app_cmd_ready;
    logic         app_wr_data_rdy;
    logic [127:0] app_rd_data;
    logic         app_rd_data_valid;
    logic         app_rd_data_end;
    logic         app_sr_ack;
    logic         app_ref_ack;
    logic         app_init_calib_complete;
    logic         app_ddr_rst;

    // -------------------------------------------------------------------------
    // 27 MHz domain mailbox (request from test engine).
    // -------------------------------------------------------------------------
    logic              req_busy_27;
    logic              req_toggle_27;
    logic              req_write_hold_27;
    logic [ADDR_W-1:0] req_addr_hold_27;
    logic [DATA_W-1:0] req_wdata_hold_27;

    // Calibration sync to 27 MHz domain.
    logic calib_meta_27;
    logic calib_sync_27;

    // -------------------------------------------------------------------------
    // App clock domain mailbox view (synced request payload + toggle).
    // -------------------------------------------------------------------------
    logic req_toggle_meta_app;
    logic req_toggle_sync_app;
    logic req_toggle_seen_app;

    logic              req_write_meta_app;
    logic              req_write_sync_app;
    logic [ADDR_W-1:0] req_addr_meta_app;
    logic [ADDR_W-1:0] req_addr_sync_app;
    logic [DATA_W-1:0] req_wdata_meta_app;
    logic [DATA_W-1:0] req_wdata_sync_app;

    logic              cur_write_app;
    logic [ADDR_W-1:0] cur_addr_word_app;
    logic [DATA_W-1:0] cur_wdata_app;
    logic [1:0]        cur_lane_app;

    // -------------------------------------------------------------------------
    // App -> 27 MHz response mailbox.
    // -------------------------------------------------------------------------
    logic              rsp_toggle_app;
    logic              rsp_ok_hold_app;
    logic [DATA_W-1:0] rsp_data_hold_app;

    logic              rsp_toggle_meta_27;
    logic              rsp_toggle_sync_27;
    logic              rsp_toggle_seen_27;

    logic              rsp_ok_meta_27;
    logic              rsp_ok_sync_27;
    logic [DATA_W-1:0] rsp_data_meta_27;
    logic [DATA_W-1:0] rsp_data_sync_27;
    logic              rsp_pending_27;
    logic              req_pending_app;

    // -------------------------------------------------------------------------
    // Helpers for 32-bit lane within 128-bit app data word.
    // -------------------------------------------------------------------------
    function automatic logic [127:0] pack_lane_data(
        input logic [1:0] lane,
        input logic [31:0] data32
    );
        logic [127:0] tmp;
        begin
            tmp = 128'h0;
            case (lane)
                2'd0: tmp[31:0]     = data32;
                2'd1: tmp[63:32]    = data32;
                2'd2: tmp[95:64]    = data32;
                default: tmp[127:96] = data32;
            endcase
            pack_lane_data = tmp;
        end
    endfunction

    function automatic logic [15:0] lane_write_mask(input logic [1:0] lane);
        begin
            // wr_data_mask: 0=write byte, 1=mask byte.
            case (lane)
                2'd0: lane_write_mask = 16'hFFF0;
                2'd1: lane_write_mask = 16'hFF0F;
                2'd2: lane_write_mask = 16'hF0FF;
                default: lane_write_mask = 16'h0FFF;
            endcase
        end
    endfunction

    function automatic logic [31:0] unpack_lane_data(
        input logic [1:0] lane,
        input logic [127:0] data128
    );
        begin
            case (lane)
                2'd0: unpack_lane_data = data128[31:0];
                2'd1: unpack_lane_data = data128[63:32];
                2'd2: unpack_lane_data = data128[95:64];
                default: unpack_lane_data = data128[127:96];
            endcase
        end
    endfunction

    function automatic logic [26:0] map_addr_halfword(input logic [26:0] a);
        begin
            // Official Tang Primer 20K DDR address reorder.
            map_addr_halfword = {a[12:10], a[26:13], a[9:0]};
        end
    endfunction

    function automatic logic [27:0] map_addr_word_to_app(input logic [ADDR_W-1:0] word_addr);
        logic [26:0] halfword_aligned;
        logic [26:0] reordered;
        begin
            // 32-bit word address -> 2-byte address domain, 128-bit line aligned.
            halfword_aligned = {1'b0, word_addr[ADDR_W-1:2], 3'b000};
            reordered = map_addr_halfword(halfword_aligned);
            map_addr_word_to_app = {1'b0, reordered};
        end
    endfunction

    // -------------------------------------------------------------------------
    // PLL for DDR memory clock (official sample settings).
    // -------------------------------------------------------------------------
    Gowin_rPLL u_gowin_rpll (
        .clkout (memory_clk),
        .lock   (pll_lock),
        .reset  (rst),
        .clkin  (clk)
    );

    // -------------------------------------------------------------------------
    // Gowin DDR3 controller wrapper.
    // -------------------------------------------------------------------------
    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk          (memory_clk),
        .clk                 (clk),
        .pll_lock            (pll_lock),
        .rst_n               (~rst),
        .app_burst_number    (app_burst_number),
        .cmd                 (app_cmd),
        .cmd_en              (app_cmd_en),
        .addr                (app_addr),
        .wr_data             (app_wr_data),
        .wr_data_en          (app_wr_data_en),
        .wr_data_end         (app_wr_data_end),
        .wr_data_mask        (app_wr_data_mask),
        .sr_req              (1'b0),
        .ref_req             (1'b0),
        .burst               (1'b1),
        .cmd_ready           (app_cmd_ready),
        .wr_data_rdy         (app_wr_data_rdy),
        .rd_data             (app_rd_data),
        .rd_data_valid       (app_rd_data_valid),
        .rd_data_end         (app_rd_data_end),
        .sr_ack              (app_sr_ack),
        .ref_ack             (app_ref_ack),
        .init_calib_complete (app_init_calib_complete),
        .clk_out             (app_clk_out),
        .ddr_rst             (app_ddr_rst),
        .O_ddr_addr          (ddr_addr),
        .O_ddr_ba            (ddr_bank),
        .O_ddr_cs_n          (ddr_cs_n),
        .O_ddr_ras_n         (ddr_ras_n),
        .O_ddr_cas_n         (ddr_cas_n),
        .O_ddr_we_n          (ddr_we_n),
        .O_ddr_clk           (ddr_ck),
        .O_ddr_clk_n         (ddr_ck_n),
        .O_ddr_cke           (ddr_cke),
        .O_ddr_odt           (ddr_odt),
        .O_ddr_reset_n       (ddr_reset_n),
        .O_ddr_dqm           (ddr_dm),
        .IO_ddr_dq           (ddr_dq),
        .IO_ddr_dqs          (ddr_dqs),
        .IO_ddr_dqs_n        (ddr_dqs_n)
    );

    // -------------------------------------------------------------------------
    // 27 MHz domain: request accept + response pulse generation.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        // Sync calibration done.
        calib_meta_27 <= app_init_calib_complete;
        calib_sync_27 <= calib_meta_27;
        calib_done    <= calib_sync_27;

        // Sync response mailbox into 27 MHz domain.
        rsp_toggle_meta_27 <= rsp_toggle_app;
        rsp_toggle_sync_27 <= rsp_toggle_meta_27;

        rsp_ok_meta_27   <= rsp_ok_hold_app;
        rsp_ok_sync_27   <= rsp_ok_meta_27;
        rsp_data_meta_27 <= rsp_data_hold_app;
        rsp_data_sync_27 <= rsp_data_meta_27;

        // One-cycle default.
        rsp_valid <= 1'b0;

        if (rst) begin
            req_busy_27      <= 1'b0;
            req_toggle_27    <= 1'b0;
            req_write_hold_27 <= 1'b0;
            req_addr_hold_27 <= '0;
            req_wdata_hold_27 <= '0;

            rsp_ok           <= 1'b0;
            rsp_rdata        <= '0;
            rsp_toggle_seen_27 <= 1'b0;
            rsp_pending_27   <= 1'b0;
        end else begin
            // New response from app clock domain.
            if (rsp_toggle_sync_27 != rsp_toggle_seen_27) begin
                rsp_toggle_seen_27 <= rsp_toggle_sync_27;
                // Wait one extra cycle before sampling payload to make
                // multi-bit CDC data settle relative to toggle sync.
                rsp_pending_27     <= 1'b1;
            end

            if (rsp_pending_27) begin
                rsp_pending_27 <= 1'b0;
                rsp_valid      <= 1'b1;
                rsp_ok         <= rsp_ok_sync_27;
                rsp_rdata      <= rsp_data_sync_27;
                req_busy_27    <= 1'b0;
            end

            // Accept one new request only when mailbox is free.
            if (req_valid && req_ready) begin
                req_write_hold_27 <= req_write;
                req_addr_hold_27  <= req_addr_word;
                req_wdata_hold_27 <= req_wdata;
                req_toggle_27     <= ~req_toggle_27;
                req_busy_27       <= 1'b1;
            end
        end
    end

    assign req_ready = calib_sync_27 && !req_busy_27;

    // -------------------------------------------------------------------------
    // App clock domain: consume request and execute DDR transaction.
    // -------------------------------------------------------------------------
    always_ff @(posedge app_clk_out) begin
        // Sync request toggle + payload into app clock domain.
        req_toggle_meta_app <= req_toggle_27;
        req_toggle_sync_app <= req_toggle_meta_app;

        req_write_meta_app <= req_write_hold_27;
        req_write_sync_app <= req_write_meta_app;
        req_addr_meta_app  <= req_addr_hold_27;
        req_addr_sync_app  <= req_addr_meta_app;
        req_wdata_meta_app <= req_wdata_hold_27;
        req_wdata_sync_app <= req_wdata_meta_app;

        // Default pulse strobes.
        app_cmd_en      <= 1'b0;
        app_wr_data_en  <= 1'b0;
        app_wr_data_end <= 1'b0;

        if (rst) begin
            app_state           <= A_IDLE;
            req_toggle_seen_app <= 1'b0;
            req_pending_app     <= 1'b0;

            cur_write_app       <= 1'b0;
            cur_addr_word_app   <= '0;
            cur_wdata_app       <= '0;
            cur_lane_app        <= 2'b00;

            app_burst_number    <= DDR_BURST_SINGLE;
            app_cmd             <= DDR_CMD_WR;
            app_addr            <= '0;
            app_wr_data         <= '0;
            app_wr_data_mask    <= 16'hFFFF;

            rsp_toggle_app      <= 1'b0;
            rsp_ok_hold_app     <= 1'b0;
            rsp_data_hold_app   <= '0;
        end else begin
            case (app_state)
                A_IDLE: begin
                    if (req_toggle_sync_app != req_toggle_seen_app) begin
                        req_toggle_seen_app <= req_toggle_sync_app;
                        // Wait one cycle before consuming synced payload.
                        req_pending_app     <= 1'b1;
                    end

                    if (req_pending_app) begin
                        req_pending_app   <= 1'b0;
                        cur_write_app     <= req_write_sync_app;
                        cur_addr_word_app <= req_addr_sync_app;
                        cur_wdata_app     <= req_wdata_sync_app;
                        cur_lane_app      <= req_addr_sync_app[1:0];

                        app_burst_number <= DDR_BURST_SINGLE;
                        app_addr         <= map_addr_word_to_app(req_addr_sync_app);

                        if (req_write_sync_app) begin
                            app_cmd          <= DDR_CMD_WR;
                            app_wr_data      <= pack_lane_data(req_addr_sync_app[1:0], req_wdata_sync_app);
                            app_wr_data_mask <= lane_write_mask(req_addr_sync_app[1:0]);
                            app_state        <= A_WR_WAIT_READY;
                        end else begin
                            app_cmd   <= DDR_CMD_RD;
                            app_state <= A_RD_WAIT_READY;
                        end
                    end
                end

                A_WR_WAIT_READY: begin
                    if (app_cmd_ready && app_wr_data_rdy) begin
                        app_cmd_en      <= 1'b1;
                        app_wr_data_en  <= 1'b1;
                        app_wr_data_end <= 1'b1;
                        app_state       <= A_WR_RESPOND;
                    end
                end

                A_WR_RESPOND: begin
                    rsp_ok_hold_app   <= 1'b1;
                    rsp_data_hold_app <= cur_wdata_app;
                    rsp_toggle_app    <= ~rsp_toggle_app;
                    app_state         <= A_IDLE;
                end

                A_RD_WAIT_READY: begin
                    if (app_cmd_ready) begin
                        app_cmd_en <= 1'b1;
                        app_state  <= A_RD_WAIT_DATA;
                    end
                end

                A_RD_WAIT_DATA: begin
                    if (app_rd_data_valid) begin
                        rsp_ok_hold_app   <= 1'b1;
                        rsp_data_hold_app <= unpack_lane_data(cur_lane_app, app_rd_data);
                        rsp_toggle_app    <= ~rsp_toggle_app;
                        app_state         <= A_IDLE;
                    end
                end

                default: app_state <= A_IDLE;
            endcase
        end
    end
endmodule
