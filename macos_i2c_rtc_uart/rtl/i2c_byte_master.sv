/*
 * Project   : macos_i2c_rtc_uart
 * File      : i2c_byte_master.sv
 * Summary   : Open-drain I2C byte engine (start/stop/read/write, ACK check).
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-26
 */
module i2c_byte_master #(
    parameter int CLK_HZ = 27_000_000,
    parameter int I2C_HZ = 100_000
) (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       cmd_valid,
    output logic       cmd_ready,
    input  logic       cmd_start,
    input  logic       cmd_stop,
    input  logic       cmd_read,
    input  logic       cmd_read_nack,
    input  logic [7:0] cmd_wdata,

    output logic       rsp_valid,
    input  logic       rsp_ready,
    output logic [7:0] rsp_rdata,
    output logic       rsp_ack_error,

    output logic       busy,

    inout  tri         i2c_scl,
    inout  tri         i2c_sda
);
    localparam int HALF_DIV_RAW = CLK_HZ / (I2C_HZ * 2);
    localparam int HALF_DIV     = (HALF_DIV_RAW > 0) ? HALF_DIV_RAW : 1;
    localparam int DIV_W        = (HALF_DIV > 1) ? $clog2(HALF_DIV) : 1;

    logic [DIV_W-1:0] div_cnt;
    logic             tick;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= '0;
            tick    <= 1'b0;
        end else begin
            if (div_cnt == HALF_DIV - 1) begin
                div_cnt <= '0;
                tick    <= 1'b1;
            end else begin
                div_cnt <= div_cnt + 1'b1;
                tick    <= 1'b0;
            end
        end
    end

    logic scl_drive_low;
    logic sda_drive_low;

    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    logic sda_in;
    assign sda_in = i2c_sda;

    typedef enum logic [3:0] {
        ST_IDLE      = 4'd0,
        ST_START_A   = 4'd1,
        ST_START_B   = 4'd2,
        ST_BIT_SETUP = 4'd3,
        ST_BIT_HIGH  = 4'd4,
        ST_BIT_HOLD  = 4'd5,
        ST_ACK_SETUP = 4'd6,
        ST_ACK_HIGH  = 4'd7,
        ST_ACK_HOLD  = 4'd8,
        ST_STOP_A    = 4'd9,
        ST_STOP_B    = 4'd10,
        ST_STOP_C    = 4'd11,
        ST_RSP       = 4'd12
    } state_t;

    state_t state;

    logic       op_stop;
    logic       op_read;
    logic       op_read_nack;
    logic [7:0] tx_shift;
    logic [7:0] rx_shift;
    logic [2:0] bit_idx;
    logic       ack_error;

    always_comb begin
        scl_drive_low = 1'b0;
        sda_drive_low = 1'b0;

        unique case (state)
            ST_IDLE: begin
            end

            ST_START_A: begin
            end

            ST_START_B: begin
                sda_drive_low = 1'b1;
            end

            ST_BIT_SETUP: begin
                scl_drive_low = 1'b1;
                if (op_read)
                    sda_drive_low = 1'b0;
                else
                    sda_drive_low = ~tx_shift[bit_idx];
            end

            ST_BIT_HIGH: begin
                if (!op_read)
                    sda_drive_low = ~tx_shift[bit_idx];
            end

            ST_BIT_HOLD: begin
                scl_drive_low = 1'b1;
                if (!op_read)
                    sda_drive_low = ~tx_shift[bit_idx];
            end

            ST_ACK_SETUP: begin
                scl_drive_low = 1'b1;
                if (op_read)
                    sda_drive_low = ~op_read_nack;
                else
                    sda_drive_low = 1'b0;
            end

            ST_ACK_HIGH: begin
                if (op_read)
                    sda_drive_low = ~op_read_nack;
            end

            ST_ACK_HOLD: begin
                scl_drive_low = 1'b1;
                if (op_read)
                    sda_drive_low = ~op_read_nack;
            end

            ST_STOP_A: begin
                scl_drive_low = 1'b1;
                sda_drive_low = 1'b1;
            end

            ST_STOP_B: begin
                sda_drive_low = 1'b1;
            end

            ST_STOP_C: begin
            end

            ST_RSP: begin
            end

            default: begin
            end
        endcase
    end

    assign cmd_ready = (state == ST_IDLE);
    assign busy      = (state != ST_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            op_stop       <= 1'b0;
            op_read       <= 1'b0;
            op_read_nack  <= 1'b0;
            tx_shift      <= 8'h00;
            rx_shift      <= 8'h00;
            bit_idx       <= 3'd7;
            ack_error     <= 1'b0;
            rsp_valid     <= 1'b0;
            rsp_rdata     <= 8'h00;
            rsp_ack_error <= 1'b0;
        end else begin
            if (state == ST_RSP) begin
                if (rsp_valid && rsp_ready) begin
                    rsp_valid <= 1'b0;
                    state     <= ST_IDLE;
                end
            end

            unique case (state)
                ST_IDLE: begin
                    if (cmd_valid) begin
                        op_stop       <= cmd_stop;
                        op_read       <= cmd_read;
                        op_read_nack  <= cmd_read_nack;
                        tx_shift      <= cmd_wdata;
                        rx_shift      <= 8'h00;
                        bit_idx       <= 3'd7;
                        ack_error     <= 1'b0;
                        rsp_ack_error <= 1'b0;

                        if (cmd_start)
                            state <= ST_START_A;
                        else
                            state <= ST_BIT_SETUP;
                    end
                end

                ST_START_A: if (tick) state <= ST_START_B;

                ST_START_B: if (tick) state <= ST_BIT_SETUP;

                ST_BIT_SETUP: if (tick) state <= ST_BIT_HIGH;

                ST_BIT_HIGH: begin
                    if (tick) begin
                        if (op_read)
                            rx_shift[bit_idx] <= sda_in;
                        state <= ST_BIT_HOLD;
                    end
                end

                ST_BIT_HOLD: begin
                    if (tick) begin
                        if (bit_idx == 3'd0)
                            state <= ST_ACK_SETUP;
                        else begin
                            bit_idx <= bit_idx - 1'b1;
                            state   <= ST_BIT_SETUP;
                        end
                    end
                end

                ST_ACK_SETUP: if (tick) state <= ST_ACK_HIGH;

                ST_ACK_HIGH: begin
                    if (tick) begin
                        if (!op_read)
                            ack_error <= sda_in;
                        state <= ST_ACK_HOLD;
                    end
                end

                ST_ACK_HOLD: begin
                    if (tick) begin
                        rsp_rdata <= rx_shift;
                        if (op_read)
                            rsp_ack_error <= 1'b0;
                        else
                            rsp_ack_error <= ack_error;

                        if (op_stop)
                            state <= ST_STOP_A;
                        else
                            state <= ST_RSP;
                    end
                end

                ST_STOP_A: if (tick) state <= ST_STOP_B;

                ST_STOP_B: if (tick) state <= ST_STOP_C;

                ST_STOP_C: begin
                    if (tick) begin
                        rsp_valid <= 1'b1;
                        state     <= ST_RSP;
                    end
                end

                ST_RSP: begin
                    if (!rsp_valid)
                        rsp_valid <= 1'b1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
