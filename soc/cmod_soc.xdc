# Cmod A7-35T pins for the matrix_soc (PicoRV32) design. Used when matrix_soc_wrapper is the top.
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports sysclk]
create_clock -period 83.333 -name sysclk [get_ports sysclk]
# BTN0 resets the CPU and peripherals (active high).
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports ext_reset_in_0]
# USB serial bridge. Names are from the PC's point of view, as on Digilent's master XDC.
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports uart_rxd_out]
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports uart_txd_in]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
