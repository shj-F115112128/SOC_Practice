# HW2 - LED0 (EMIO GPIO -> PL) 腳位約束
# 來源：EGO-XZ7 User Guide V1.2, §2.9.3 User LED（LED0 = T22, Bank13 = 3.3V）
#
# S3/S4 push button 是 PS MIO_50/51，由 Vivado PS7 IP 內部直接接到晶片的固定腳位，
# 不需要（也不能）在這裡用 XDC 另外指定 PACKAGE_PIN。

set_property PACKAGE_PIN T22      [get_ports {led0_gpio_tri_io[0]}]
set_property IOSTANDARD  LVCMOS33 [get_ports {led0_gpio_tri_io[0]}]
