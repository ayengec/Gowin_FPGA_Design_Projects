# Project   : macos_i2c_rtc_uart
# File      : macos_i2c_rtc_uart.sdc
# Summary   : Base timing constraints for 27 MHz system clock.
# Designer  : Alican Yengec
# Updated   : 2026-04-26

create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]
