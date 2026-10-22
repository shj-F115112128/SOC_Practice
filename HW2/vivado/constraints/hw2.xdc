# HW2 - LED0 (PL pwm_breath 輸出) / S6 按鈕 (PL btn_debounce 輸入) 腳位約束
# 來源：EGO-XZ7 User Guide V1.2
#   §2.9.3 User LED：LED0 = T22（Bank33 = 3.3V）
#   §2.9.1 User Push Buttons：S6 (BTNC) = P16，按下 = 1（同排的 S5/T18 在 project_1 當 active-high rst 用過）
#     按鈕所在 Bank 的電壓是 VADJ（JP1 選 3.3V / 2.5V），這裡用 LVCMOS33，JP1 要在 3.3V

set_property PACKAGE_PIN T22      [get_ports led0]
set_property IOSTANDARD  LVCMOS33 [get_ports led0]

set_property PACKAGE_PIN P16      [get_ports btn]
set_property IOSTANDARD  LVCMOS33 [get_ports btn]
