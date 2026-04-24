# Project   : Tang Primer 20K DDR3 UART Tester (Phase-1)
# File      : ddr3_uart_tester.sdc
# Summary   : Base timing constraint for 27MHz input clock.

create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
