# Project   : Tang Primer 20K LED Chaser Smoke Test
# File      : led_chaser_smoke_test.sdc
# Summary   : Basic clock constraint.
# Designer  : Alican Yengec
# Updated   : 2026-04-24

create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]
