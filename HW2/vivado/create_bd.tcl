# HW2 block design: PS7 only，S4 (PS MIO_51) 中斷按鈕 + LED0 (EMIO -> PL T22)
#
# 已經在 Vivado 2018.2 batch mode 實際跑過 validate_bd_design 驗證過，可以直接：
#   vivado -mode batch -source create_bd.tcl
# 或是把中段 PS7 設定那幾行貼進既有專案的 Tcl console。
#
# 設計重點：
#   - 完全不需要 PL 端邏輯 / AXI GP0 master：S4 中斷走 PS 內建 GPIO controller + GIC，
#     LED0 的 PWM/呼吸燈邏輯都在 SDK 軟體裡跑（TTC0 計時器中斷），PL 只負責把 EMIO
#     那一條 GPIO 接到實體腳位，所以關掉 M_AXI_GP0 後整個 BD 不需要任何 PL 時脈接線。
#   - LED0 透過 EMIO 的 "Make External" 自動產生 IOBUF（Vivado 的 BD wrapper 生成階段
#     自己加的，不用手動寫 IOBUF 原語），對外埠名稱是 led0_gpio_tri_io[0]。

set proj_name  "hw2_led_isr"
set proj_dir   "./build"
set part       "xc7z020clg484-1"

create_project $proj_name $proj_dir -part $part -force

create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# 不用 PL AXI master（S4/LED0 都不經過 PL 的 AXI 介面）
set_property CONFIG.PCW_USE_M_AXI_GP0 {0} [get_bd_cells ps7]

# S4 (MIO_51) 走 PS 內建 GPIO；LED0 多拉一條 EMIO GPIO 給 PL 用
set_property CONFIG.PCW_GPIO_MIO_GPIO_ENABLE  {1} [get_bd_cells ps7]
set_property CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} [get_bd_cells ps7]
set_property CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH  {1} [get_bd_cells ps7]

# S3/S4 兩顆 PS push button 都接 MIO_50/51，開內部 pull-up（板上另外也有 4.7K 外部上拉）
set_property CONFIG.PCW_MIO_50_PULLUP {enabled} [get_bd_cells ps7]
set_property CONFIG.PCW_MIO_51_PULLUP {enabled} [get_bd_cells ps7]
# 注意：MIO_50/51 的 IOTYPE 這顆 part/package 只接受 LVCMOS 3.3V（Vivado IP 本身的
# hard constraint），跟 EGO-XZ7 UG 文字 OCR 出來的「Bank501 (1.8V)」對不上 ——
# 以 Vivado 這邊為準，不要手動覆寫成 1.8V（會直接報錯 out of range）。

# TTC0（軟體 PWM 的計時器中斷來源），預設關閉要手動開
set_property CONFIG.PCW_TTC0_PERIPHERAL_ENABLE {1} [get_bd_cells ps7]

# DDR / FIXED_IO / PS_CLK 拉到外部（每個 Zynq 設計都要）
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR, PS_CLK" apply_board_preset "0" \
              Master "Disable" Slave "Disable"} [get_bd_cells ps7]

# LED0 的 EMIO GPIO 拉到外部，Vivado 會在產生 wrapper 時自動加 IOBUF
make_bd_intf_pins_external -name led0_gpio [get_bd_intf_pins ps7/GPIO_0]

validate_bd_design
save_bd_design

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [glob [get_property DIRECTORY [current_project]]/$proj_name.srcs/sources_1/bd/system/hdl/system_wrapper.v]
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse constraints/hw2.xdc

puts "Block design 建立完成，驗證通過（validate_bd_design 無錯誤）。"
puts "接下來：Generate Bitstream -> Export Hardware (含 bitstream) -> 開 SDK，"
puts "用匯出的 xparameters.h 核對 sdk/src/main.c 開頭那幾個裝置/中斷 ID 巨集。"
