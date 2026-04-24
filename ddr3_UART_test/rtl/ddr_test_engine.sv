/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : ddr_test_engine.sv
 * Summary   : Core test engine for single/block/bank DDR memory checks.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-23
 *
 * Notes:
 * - This engine is backend-agnostic and talks through a tiny req/rsp bus.
 * - UART shell sends one command at a time using cmd_valid/cmd_ready.
 * - Statistics are cumulative until CLR command is received.
 */
module ddr_test_engine #(
    parameter int ADDR_W = 25,
    parameter int DATA_W = 32,
    // If backend never returns rsp_valid, do not hang forever.
    // At 27 MHz this default is about 1 second.
    parameter int RSP_TIMEOUT_CYCLES = 27_000_000
) (
    input  logic                 clk,
    input  logic                 rst,

    // Command channel from UART shell.
    input  logic                 cmd_valid,
    output logic                 cmd_ready,
    input  logic [3:0]           cmd_code,
    input  logic [ADDR_W-1:0]    cmd_addr_word,
    input  logic [ADDR_W-1:0]    cmd_len_words,
    input  logic [DATA_W-1:0]    cmd_wdata,
    input  logic [7:0]           cmd_pattern,
    input  logic [DATA_W-1:0]    cmd_seed,

    // Completion/status back to UART shell.
    output logic                 busy,
    output logic                 done,
    output logic                 cmd_ok,
    output logic [DATA_W-1:0]    read_data,

    // Memory backend request/response.
    output logic                 mem_req_valid,
    input  logic                 mem_req_ready,
    output logic                 mem_req_write,
    output logic [ADDR_W-1:0]    mem_req_addr_word,
    output logic [DATA_W-1:0]    mem_req_wdata,

    input  logic                 mem_rsp_valid,
    input  logic                 mem_rsp_ok,
    input  logic [DATA_W-1:0]    mem_rsp_rdata,

    // Cumulative test statistics.
    output logic [31:0]          stat_total_reads,
    output logic [31:0]          stat_total_writes,
    output logic [31:0]          stat_error_count,
    output logic [ADDR_W-1:0]    stat_first_err_addr,
    output logic [DATA_W-1:0]    stat_first_err_exp,
    output logic [DATA_W-1:0]    stat_first_err_got
);
    // Command encoding shared with command shell.
    localparam logic [3:0] CMD_NOP   = 4'h0;
    localparam logic [3:0] CMD_MR    = 4'h1;
    localparam logic [3:0] CMD_MW    = 4'h2;
    localparam logic [3:0] CMD_MB    = 4'h3;
    localparam logic [3:0] CMD_BB    = 4'h4;
    localparam logic [3:0] CMD_CLR   = 4'h5;

    // Pattern encoding.
    localparam logic [7:0] PAT_ZERO  = 8'h00;
    localparam logic [7:0] PAT_ONES  = 8'h01;
    localparam logic [7:0] PAT_AA55  = 8'h02;
    localparam logic [7:0] PAT_55AA  = 8'h03;
    localparam logic [7:0] PAT_ADDR  = 8'h04;
    localparam logic [7:0] PAT_LFSR  = 8'h05;

    // Internal run mode.
    typedef enum logic [2:0] {
        MODE_NONE,
        MODE_SINGLE_RD,
        MODE_SINGLE_WR,
        MODE_BLOCK,
        MODE_BANK
    } mode_t;

    // Engine state machine.
    typedef enum logic [2:0] {
        S_IDLE,
        S_ISSUE_WR,
        S_WAIT_WR,
        S_ISSUE_RD,
        S_WAIT_RD,
        S_DONE
    } state_t;

    state_t state;
    mode_t  mode;

    logic [ADDR_W-1:0] base_addr;
    logic [ADDR_W-1:0] run_len;
    logic [ADDR_W-1:0] idx;
    logic [1:0]        bank_idx;
    logic              phase_check;

    logic [7:0]        pattern_sel;
    logic [DATA_W-1:0] seed_reg;
    logic [DATA_W-1:0] lfsr_reg;

    logic [DATA_W-1:0] single_wr_data;
    logic [DATA_W-1:0] expected_sent;
    logic [31:0]       rsp_wait_cnt;

    logic [ADDR_W-1:0] cur_addr;
    logic [DATA_W-1:0] cur_expected;
    logic [ADDR_W-1:0] cur_bank_offset;

    // 32-bit Fibonacci LFSR step.
    function automatic logic [31:0] lfsr_next(input logic [31:0] x);
        logic feedback;
        begin
            feedback  = x[31] ^ x[21] ^ x[1] ^ x[0];
            lfsr_next = {x[30:0], feedback};
        end
    endfunction

    // Convert current address/pattern into expected data value.
    function automatic logic [31:0] make_pattern(
        input logic [7:0]        pat,
        input logic [ADDR_W-1:0] addr_word,
        input logic [31:0]       lfsr_val
    );
        case (pat)
            PAT_ZERO: make_pattern = 32'h0000_0000;
            PAT_ONES: make_pattern = 32'hFFFF_FFFF;
            PAT_AA55: make_pattern = 32'hAAAA_AAAA;
            PAT_55AA: make_pattern = 32'h5555_5555;
            PAT_ADDR: make_pattern = {{(32-ADDR_W){1'b0}}, addr_word};
            default:  make_pattern = lfsr_val;
        endcase
    endfunction

    // Address offset used by bank-sweep mode.
    function automatic logic [ADDR_W-1:0] bank_offset(input logic [1:0] b);
        case (b)
            2'd0: bank_offset = 25'h0000000;  // 0 MB
            2'd1: bank_offset = 25'h0800000;  // 32 MB / 4-byte words
            2'd2: bank_offset = 25'h1000000;  // 64 MB / 4-byte words
            default: bank_offset = 25'h1800000; // 96 MB / 4-byte words
        endcase
    endfunction

    always_comb begin
        // Address generation is centralized so write/read phases stay aligned.
        cur_bank_offset = (mode == MODE_BANK) ? bank_offset(bank_idx) : '0;
        cur_addr        = base_addr + cur_bank_offset + idx;
        cur_expected    = make_pattern(pattern_sel, cur_addr, lfsr_reg);
    end

    // Combinational request bus defaults.
    always_comb begin
        mem_req_valid    = 1'b0;
        mem_req_write    = 1'b0;
        mem_req_addr_word = cur_addr;
        mem_req_wdata    = cur_expected;

        if (state == S_ISSUE_WR) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            if (mode == MODE_SINGLE_WR)
                mem_req_wdata = single_wr_data;
        end else if (state == S_ISSUE_RD) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_wdata = 32'h0000_0000;
        end
    end

    assign busy      = (state != S_IDLE);
    assign cmd_ready = (state == S_IDLE);

    always_ff @(posedge clk) begin
        logic [ADDR_W-1:0] idx_next;
        logic [DATA_W-1:0] lfsr_next_v;

        if (rst) begin
            state <= S_IDLE;
            mode  <= MODE_NONE;

            base_addr    <= '0;
            run_len      <= '0;
            idx          <= '0;
            bank_idx     <= '0;
            phase_check  <= 1'b0;
            pattern_sel  <= PAT_ZERO;
            seed_reg     <= 32'h1ACE_B00C;
            lfsr_reg     <= 32'h1ACE_B00C;
            single_wr_data <= '0;
            expected_sent  <= '0;
            rsp_wait_cnt   <= '0;

            done     <= 1'b0;
            cmd_ok   <= 1'b0;
            read_data <= '0;

            stat_total_reads   <= '0;
            stat_total_writes  <= '0;
            stat_error_count   <= '0;
            stat_first_err_addr <= '0;
            stat_first_err_exp  <= '0;
            stat_first_err_got  <= '0;
        end else begin
            // `done` is a one-cycle pulse.
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    // Accept one command when idle.
                    if (cmd_valid) begin
                        cmd_ok <= 1'b1;

                        case (cmd_code)
                            CMD_MR: begin
                                mode         <= MODE_SINGLE_RD;
                                base_addr    <= cmd_addr_word;
                                idx          <= '0;
                                state        <= S_ISSUE_RD;
                            end

                            CMD_MW: begin
                                mode           <= MODE_SINGLE_WR;
                                base_addr      <= cmd_addr_word;
                                idx            <= '0;
                                single_wr_data <= cmd_wdata;
                                state          <= S_ISSUE_WR;
                            end

                            CMD_MB: begin
                                mode        <= MODE_BLOCK;
                                base_addr   <= cmd_addr_word;
                                run_len     <= (cmd_len_words == 0) ? {{(ADDR_W-1){1'b0}},1'b1} : cmd_len_words;
                                idx         <= '0;
                                bank_idx    <= 2'd0;
                                phase_check <= 1'b0;
                                pattern_sel <= cmd_pattern;
                                seed_reg    <= (cmd_seed == 0) ? 32'h1ACE_B00C : cmd_seed;
                                lfsr_reg    <= (cmd_seed == 0) ? 32'h1ACE_B00C : cmd_seed;
                                state       <= S_ISSUE_WR;
                            end

                            CMD_BB: begin
                                mode        <= MODE_BANK;
                                base_addr   <= '0;
                                run_len     <= (cmd_len_words == 0) ? {{(ADDR_W-1){1'b0}},1'b1} : cmd_len_words;
                                idx         <= '0;
                                bank_idx    <= 2'd0;
                                phase_check <= 1'b0;
                                pattern_sel <= cmd_pattern;
                                seed_reg    <= (cmd_seed == 0) ? 32'h1ACE_B00C : cmd_seed;
                                lfsr_reg    <= (cmd_seed == 0) ? 32'h1ACE_B00C : cmd_seed;
                                state       <= S_ISSUE_WR;
                            end

                            CMD_CLR: begin
                                // Clear cumulative statistics quickly.
                                stat_total_reads    <= '0;
                                stat_total_writes   <= '0;
                                stat_error_count    <= '0;
                                stat_first_err_addr <= '0;
                                stat_first_err_exp  <= '0;
                                stat_first_err_got  <= '0;
                                cmd_ok              <= 1'b1;
                                state               <= S_DONE;
                            end

                            default: begin
                                cmd_ok <= 1'b0;
                                state  <= S_DONE;
                            end
                        endcase
                    end
                end

                S_ISSUE_WR: begin
                    if (mem_req_ready) begin
                        expected_sent <= mem_req_wdata;
                        rsp_wait_cnt  <= '0;
                        state         <= S_WAIT_WR;
                    end
                end

                S_WAIT_WR: begin
                    if (mem_rsp_valid) begin
                        stat_total_writes <= stat_total_writes + 1'b1;
                        if (!mem_rsp_ok)
                            cmd_ok <= 1'b0;

                        if (mode == MODE_SINGLE_WR) begin
                            state <= S_DONE;
                        end else begin
                            idx_next    = idx + 1'b1;
                            lfsr_next_v = lfsr_next(lfsr_reg);

                            idx <= idx_next;
                            if (pattern_sel == PAT_LFSR)
                                lfsr_reg <= lfsr_next_v;

                            if (idx_next >= run_len) begin
                                // End of fill pass -> switch to check pass.
                                idx         <= '0;
                                phase_check <= 1'b1;
                                lfsr_reg    <= seed_reg;
                                state       <= S_ISSUE_RD;
                            end else begin
                                state <= S_ISSUE_WR;
                            end
                        end
                    end else if (rsp_wait_cnt == RSP_TIMEOUT_CYCLES - 1) begin
                        // Backend did not answer in time.
                        cmd_ok <= 1'b0;
                        state  <= S_DONE;
                    end else begin
                        rsp_wait_cnt <= rsp_wait_cnt + 1'b1;
                    end
                end

                S_ISSUE_RD: begin
                    if (mem_req_ready) begin
                        expected_sent <= cur_expected;
                        rsp_wait_cnt  <= '0;
                        state         <= S_WAIT_RD;
                    end
                end

                S_WAIT_RD: begin
                    if (mem_rsp_valid) begin
                        stat_total_reads <= stat_total_reads + 1'b1;

                        if (mode == MODE_SINGLE_RD) begin
                            read_data <= mem_rsp_rdata;
                            if (!mem_rsp_ok)
                                cmd_ok <= 1'b0;
                            state <= S_DONE;
                        end else begin
                            // Compare in check phase for block/bank tests.
                            if ((!mem_rsp_ok) || (mem_rsp_rdata != expected_sent)) begin
                                cmd_ok <= 1'b0;
                                stat_error_count <= stat_error_count + 1'b1;

                                if (stat_error_count == 0) begin
                                    stat_first_err_addr <= cur_addr;
                                    stat_first_err_exp  <= expected_sent;
                                    stat_first_err_got  <= mem_rsp_rdata;
                                end
                            end

                            idx_next    = idx + 1'b1;
                            lfsr_next_v = lfsr_next(lfsr_reg);

                            idx <= idx_next;
                            if (pattern_sel == PAT_LFSR)
                                lfsr_reg <= lfsr_next_v;

                            if (idx_next >= run_len) begin
                                if (mode == MODE_BANK && bank_idx != 2'd3) begin
                                    // Next bank: restart fill+check.
                                    bank_idx    <= bank_idx + 1'b1;
                                    idx         <= '0;
                                    phase_check <= 1'b0;
                                    lfsr_reg    <= seed_reg;
                                    state       <= S_ISSUE_WR;
                                end else begin
                                    state <= S_DONE;
                                end
                            end else begin
                                state <= S_ISSUE_RD;
                            end
                        end
                    end else if (rsp_wait_cnt == RSP_TIMEOUT_CYCLES - 1) begin
                        // Backend did not answer in time.
                        cmd_ok <= 1'b0;
                        state  <= S_DONE;
                    end else begin
                        rsp_wait_cnt <= rsp_wait_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    mode  <= MODE_NONE;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
