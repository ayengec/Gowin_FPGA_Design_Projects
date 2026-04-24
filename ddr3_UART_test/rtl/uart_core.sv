/*
 * Project   : Tang Primer 20K DDR3 UART Tester (Real DDR3)
 * File      : uart_core.sv
 * Summary   : Simple wrapper that combines UART RX and UART TX.
 * Designer  : Alican Yengec
 * Language  : SystemVerilog
 * Updated   : 2026-04-23
 *
 * Why a wrapper?
 * - Keeps the top-level clean.
 * - Gives a single place to tune baud parameters.
 * - Makes future replacement (FIFO/DMA UART) easier.
 */
module uart_core #(
    parameter int CLK_HZ   = 27_000_000,
    parameter int BAUDRATE = 115200
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       rx,
    output logic       tx,

    output logic [7:0] rx_data,
    output logic       rx_valid,

    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx_busy
);
    // RX path: serial line -> byte + valid pulse.
    // `rx_valid` is a one-clock strobe when a full 8N1 frame is decoded.
    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_rx (
        .clk   (clk),
        .rst   (rst),
        .rx    (rx),
        .data  (rx_data),
        .valid (rx_valid)
    );

    // TX path: byte + start pulse -> serialized 8N1 frame on `tx`.
    // `tx_busy` allows upstream logic to avoid overrun.
    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUDRATE(BAUDRATE)
    ) u_tx (
        .clk   (clk),
        .rst   (rst),
        .start (tx_start),
        .data  (tx_data),
        .tx    (tx),
        .busy  (tx_busy)
    );
endmodule
