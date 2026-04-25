/*
 * Project   : macos_tft18_spi_dht22
 * File      : dht22_ctrl.sv
 * Summary   : Single-wire DHT22 reader with manual start pulse interface.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 *
 * Notes:
 * - The DHT22 data pin is open-drain style. This module only drives LOW or Z.
 * - Add a pull-up resistor (typically 4.7k) from DATA to 3V3.
 * - A minimum sampling gap is enforced internally (default 2000 ms).
 */
module dht22_ctrl #(
    parameter int CLK_HZ          = 27_000_000,
    parameter int START_LOW_US    = 1200,
    parameter int START_REL_US    = 30,
    parameter int RESP_TIMEOUT_US = 300,
    parameter int BIT_TIMEOUT_US  = 120,
    parameter int HIGH_TH_US      = 40,
    parameter int MIN_GAP_MS      = 2000
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       start,         // one-clock pulse
    inout  tri         dht22_io,

    output logic       ready,         // high when a new transaction can start
    output logic       busy,
    output logic       done_pulse,    // one-clock pulse on success or error
    output logic       valid,         // high when latest read is valid (CRC pass)
    output logic       crc_ok,
    output logic       timeout_err,

    output logic [15:0] hum_x10,      // humidity in 0.1% units
    output logic [15:0] temp_x10,     // absolute temperature in 0.1C units
    output logic        temp_neg
);
    localparam int US_DIV   = (CLK_HZ / 1_000_000 > 0) ? (CLK_HZ / 1_000_000) : 1;
    localparam int US_DIV_W = (US_DIV > 1) ? $clog2(US_DIV) : 1;
    localparam int MS_DIV   = (CLK_HZ / 1000 > 0) ? (CLK_HZ / 1000) : 1;
    localparam int MS_DIV_W = (MS_DIV > 1) ? $clog2(MS_DIV) : 1;
    localparam int GAP_W    = (MIN_GAP_MS > 1) ? $clog2(MIN_GAP_MS + 1) : 1;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_HOST_LOW,
        ST_HOST_RELEASE,
        ST_WAIT_RESP_LOW,
        ST_WAIT_RESP_HIGH,
        ST_WAIT_RESP_LOW2,
        ST_WAIT_BIT_HIGH,
        ST_MEASURE_BIT_HIGH
    } state_t;

    state_t state;

    logic [US_DIV_W-1:0] us_div_cnt;
    logic                tick_us;
    logic [MS_DIV_W-1:0] ms_div_cnt;
    logic                tick_ms;

    logic [GAP_W-1:0] gap_ms_cnt;

    logic io_drive_low;
    logic io_sync0;
    logic io_sync1;

    logic [11:0] us_cnt;
    logic [7:0]  high_us_cnt;
    logic [5:0]  bit_idx;
    logic [39:0] shift_data;

    wire dht_in = io_sync1;

    assign dht22_io = io_drive_low ? 1'b0 : 1'bz;
    assign ready    = (!busy) && (gap_ms_cnt == 0);

    function automatic logic crc_match(input logic [39:0] frame);
        logic [8:0] sum;
        begin
            sum      = frame[39:32] + frame[31:24] + frame[23:16] + frame[15:8];
            crc_match = (sum[7:0] == frame[7:0]);
        end
    endfunction

    // 1-us tick
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            us_div_cnt <= '0;
            tick_us    <= 1'b0;
        end else begin
            if (us_div_cnt == US_DIV - 1) begin
                us_div_cnt <= '0;
                tick_us    <= 1'b1;
            end else begin
                us_div_cnt <= us_div_cnt + 1'b1;
                tick_us    <= 1'b0;
            end
        end
    end

    // 1-ms tick
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_div_cnt <= '0;
            tick_ms    <= 1'b0;
        end else begin
            if (ms_div_cnt == MS_DIV - 1) begin
                ms_div_cnt <= '0;
                tick_ms    <= 1'b1;
            end else begin
                ms_div_cnt <= ms_div_cnt + 1'b1;
                tick_ms    <= 1'b0;
            end
        end
    end

    // Input synchronizer
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            io_sync0 <= 1'b1;
            io_sync1 <= 1'b1;
        end else begin
            io_sync0 <= dht22_io;
            io_sync1 <= io_sync0;
        end
    end

    // Main FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            io_drive_low <= 1'b0;
            busy         <= 1'b0;
            done_pulse   <= 1'b0;

            valid        <= 1'b0;
            crc_ok       <= 1'b0;
            timeout_err  <= 1'b0;

            hum_x10      <= 16'd0;
            temp_x10     <= 16'd0;
            temp_neg     <= 1'b0;

            us_cnt       <= '0;
            high_us_cnt  <= '0;
            bit_idx      <= '0;
            shift_data   <= '0;
            gap_ms_cnt   <= '0;
        end else begin
            done_pulse <= 1'b0;

            if (tick_ms && (gap_ms_cnt != 0))
                gap_ms_cnt <= gap_ms_cnt - 1'b1;

            case (state)
                ST_IDLE: begin
                    io_drive_low <= 1'b0;
                    busy         <= 1'b0;
                    us_cnt       <= '0;
                    high_us_cnt  <= '0;
                    bit_idx      <= '0;
                    shift_data   <= '0;

                    if (start && ready) begin
                        busy         <= 1'b1;
                        timeout_err  <= 1'b0;
                        valid        <= 1'b0;
                        crc_ok       <= 1'b0;
                        io_drive_low <= 1'b1;
                        us_cnt       <= '0;
                        state        <= ST_HOST_LOW;
                    end
                end

                ST_HOST_LOW: begin
                    if (tick_us) begin
                        if (us_cnt == START_LOW_US - 1) begin
                            io_drive_low <= 1'b0;
                            us_cnt       <= '0;
                            state        <= ST_HOST_RELEASE;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                ST_HOST_RELEASE: begin
                    if (tick_us) begin
                        if (us_cnt == START_REL_US - 1) begin
                            us_cnt <= '0;
                            state  <= ST_WAIT_RESP_LOW;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                ST_WAIT_RESP_LOW: begin
                    if (tick_us) begin
                        if (!dht_in) begin
                            us_cnt <= '0;
                            state  <= ST_WAIT_RESP_HIGH;
                        end else if (us_cnt == RESP_TIMEOUT_US - 1) begin
                            busy        <= 1'b0;
                            done_pulse  <= 1'b1;
                            timeout_err <= 1'b1;
                            valid       <= 1'b0;
                            crc_ok      <= 1'b0;
                            gap_ms_cnt  <= GAP_W'(MIN_GAP_MS);
                            state       <= ST_IDLE;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                ST_WAIT_RESP_HIGH: begin
                    if (tick_us) begin
                        if (dht_in) begin
                            us_cnt <= '0;
                            state  <= ST_WAIT_RESP_LOW2;
                        end else if (us_cnt == RESP_TIMEOUT_US - 1) begin
                            busy        <= 1'b0;
                            done_pulse  <= 1'b1;
                            timeout_err <= 1'b1;
                            valid       <= 1'b0;
                            crc_ok      <= 1'b0;
                            gap_ms_cnt  <= GAP_W'(MIN_GAP_MS);
                            state       <= ST_IDLE;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                ST_WAIT_RESP_LOW2: begin
                    if (tick_us) begin
                        if (!dht_in) begin
                            us_cnt      <= '0;
                            bit_idx     <= 6'd0;
                            shift_data  <= 40'd0;
                            state       <= ST_WAIT_BIT_HIGH;
                        end else if (us_cnt == RESP_TIMEOUT_US - 1) begin
                            busy        <= 1'b0;
                            done_pulse  <= 1'b1;
                            timeout_err <= 1'b1;
                            valid       <= 1'b0;
                            crc_ok      <= 1'b0;
                            gap_ms_cnt  <= GAP_W'(MIN_GAP_MS);
                            state       <= ST_IDLE;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                ST_WAIT_BIT_HIGH: begin
                    if (tick_us) begin
                        if (dht_in) begin
                            high_us_cnt <= 8'd0;
                            state       <= ST_MEASURE_BIT_HIGH;
                        end else if (us_cnt == BIT_TIMEOUT_US - 1) begin
                            busy        <= 1'b0;
                            done_pulse  <= 1'b1;
                            timeout_err <= 1'b1;
                            valid       <= 1'b0;
                            crc_ok      <= 1'b0;
                            gap_ms_cnt  <= GAP_W'(MIN_GAP_MS);
                            state       <= ST_IDLE;
                        end else begin
                            us_cnt <= us_cnt + 1'b1;
                        end
                    end
                end

                default: begin // ST_MEASURE_BIT_HIGH
                    if (tick_us) begin
                        if (dht_in) begin
                            if (high_us_cnt == BIT_TIMEOUT_US[7:0]) begin
                                busy        <= 1'b0;
                                done_pulse  <= 1'b1;
                                timeout_err <= 1'b1;
                                valid       <= 1'b0;
                                crc_ok      <= 1'b0;
                                gap_ms_cnt  <= GAP_W'(MIN_GAP_MS);
                                state       <= ST_IDLE;
                            end else if (high_us_cnt < 8'hFF) begin
                                high_us_cnt <= high_us_cnt + 1'b1;
                            end
                        end else begin
                            logic [39:0] frame_data_next;
                            logic [15:0] temp_word_next;

                            frame_data_next = {shift_data[38:0], (high_us_cnt > HIGH_TH_US)};
                            shift_data      <= frame_data_next;

                            if (bit_idx == 6'd39) begin
                                busy       <= 1'b0;
                                done_pulse <= 1'b1;
                                gap_ms_cnt <= GAP_W'(MIN_GAP_MS);

                                if (crc_match(frame_data_next)) begin
                                    temp_word_next = {frame_data_next[23:16], frame_data_next[15:8]};
                                    hum_x10        <= {frame_data_next[39:32], frame_data_next[31:24]};
                                    temp_neg       <= temp_word_next[15];
                                    temp_x10       <= {1'b0, temp_word_next[14:0]};
                                    crc_ok       <= 1'b1;
                                    timeout_err  <= 1'b0;
                                    valid        <= 1'b1;
                                end else begin
                                    crc_ok       <= 1'b0;
                                    timeout_err  <= 1'b0;
                                    valid        <= 1'b0;
                                end

                                state <= ST_IDLE;
                            end else begin
                                bit_idx <= bit_idx + 1'b1;
                                us_cnt  <= '0;
                                state   <= ST_WAIT_BIT_HIGH;
                            end
                        end
                    end
                end
            endcase
        end
    end

endmodule
