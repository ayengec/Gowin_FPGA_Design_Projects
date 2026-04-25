/*
 * Project   : macos_tft18_spi_dht22
 * File      : button_event.sv
 * Summary   : Button synchronizer + debounce + one-clock press pulse generator.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-25
 */
module button_event #(
    parameter int CLK_HZ      = 27_000_000,
    parameter int DEBOUNCE_MS = 20
) (
    input  logic clk,
    input  logic rst_n,
    input  logic btn_n,       // active-low raw button input
    output logic press_pulse  // single-cycle pulse when a stable press is detected
);
    // Convert debounce time in milliseconds into clock cycles.
    localparam int DB_CYCLES_RAW = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam int DB_CYCLES     = (DB_CYCLES_RAW > 0) ? DB_CYCLES_RAW : 1;
    localparam int DB_W          = (DB_CYCLES > 1) ? $clog2(DB_CYCLES + 1) : 1;

    // Two-stage synchronizer to reduce metastability risk.
    logic sync0;
    logic sync1;

    // Debounced stable button value and previous sample.
    logic stable;
    logic stable_prev;

    // Counter that measures how long the sampled input differs from stable value.
    logic [DB_W-1:0] db_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0 <= 1'b1;
            sync1 <= 1'b1;
        end else begin
            sync0 <= btn_n;
            sync1 <= sync0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stable      <= 1'b1;
            stable_prev <= 1'b1;
            db_cnt      <= '0;
            press_pulse <= 1'b0;
        end else begin
            press_pulse <= 1'b0;

            if (sync1 == stable) begin
                // No change: keep counter cleared.
                db_cnt <= '0;
            end else begin
                // Input differs from stable state: wait until it stays there
                // for DB_CYCLES clocks, then accept the new stable value.
                if (db_cnt == DB_CYCLES - 1) begin
                    stable <= sync1;
                    db_cnt <= '0;
                end else begin
                    db_cnt <= db_cnt + 1'b1;
                end
            end

            stable_prev <= stable;

            // Generate pulse on stable high->low transition (button press).
            if (stable_prev && !stable)
                press_pulse <= 1'b1;
        end
    end
endmodule
