set_property PACKAGE_PIN Y18 [get_ports clk]
set_property PACKAGE_PIN J17 [get_ports compare0]
set_property PACKAGE_PIN T20 [get_ports resetn]
set_property PACKAGE_PIN N4 [get_ports spi_cs]
set_property PACKAGE_PIN L3 [get_ports spi_scl]
set_property PACKAGE_PIN P5 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports compare0]
set_property IOSTANDARD LVCMOS33 [get_ports resetn]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_scl]

# 保护 TDC 层次与进位链
set_property DONT_TOUCH true [get_cells -hier -filter {NAME =~ *u_t1/g_tdc*}]
set_property KEEP      true [get_nets  -hier -filter {NAME =~ *u_t1/tap_a*}]
set_property KEEP      true [get_nets  -hier -filter {NAME =~ *u_t1/tap_b*}]

# 异步输入到采样触发器：TDC 本来就是异步采样，按 CDC 处理，
# 不按 200MHz 的 setup/hold 去卡它
set_false_path -from [get_ports {compare0 compare1}] -to [get_cells -hier -filter {NAME =~ *u_t1/samp_a_reg[*] || NAME =~ *u_t1/samp_b_reg[*]}]

set_property PACKAGE_PIN K16 [get_ports compare1]
set_property IOSTANDARD LVCMOS33 [get_ports compare1]




set_property PACKAGE_PIN E22 [get_ports key]
set_property IOSTANDARD LVCMOS33 [get_ports key]

# QSPI FLASH Constraints
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]


