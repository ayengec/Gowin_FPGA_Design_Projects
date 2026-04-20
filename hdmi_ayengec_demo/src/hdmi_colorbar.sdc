# Project   : Tang Primer 20K HDMI Colorbar (Phase-1)
# Summary   : Base timing constraint for 27MHz input clock.

create_clock -name I_clk -period 37.037 [get_ports {I_clk}]

create_generated_clock -name serial_clk -source [get_ports {I_clk}] -multiply_by 55 -divide_by 4 [get_nets {serial_clk}]

create_generated_clock -name pix_clk -source [get_nets {serial_clk}] -divide_by 5 [get_nets {pix_clk}]