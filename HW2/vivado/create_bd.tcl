# HW2 block design：S6 (BTNC, PL P16) 中斷按鈕 + PL 呼吸燈 PWM (rtl/breathing_pwm_top.vhd) -> LED0 (T22)
#
# 用法（在 vivado/ 目錄下）：
#   vivado -mode batch -source create_bd.tcl [-tclargs <專案目錄>]
#   專案目錄預設 ./build；create_project -force 會清空該目錄，不要指到 SDK workspace 所在的資料夾
#
# 設計重點：
#   - 按鈕經過 PL：S6 -> rtl/btn_debounce.v（同步 + 20ms 防彈跳）-> AXI GPIO (axi_gpio_btn,
#     開 interrupt) -> ip2intc_irpt -> PS7 IRQ_F2P[0] -> GIC（IRQ ID 61），ISR 在 SDK 端。
#   - 呼吸燈 PWM 在 PL 用 VHDL 做（rtl/breathing_pwm_top.vhd + configurable_counter.vhd，
#     FCLK_CLK0 = 50 MHz），CPU 只透過 M_AXI_GP0 -> AXI Interconnect -> AXI GPIO 寫 1 bit 的 mode
#     （0 = 恆亮、1 = 約 3.75 秒呼吸），PWM 波形全部由硬體產生，CPU 不用一直進中斷。

set proj_name  "hw2_led_isr"
set proj_dir   [expr {$argc > 0 ? [lindex $argv 0] : "./build"}]
set part       "xc7z020clg484-1"

create_project $proj_name $proj_dir -part $part -force

create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# PL 端的 RTL 模組，要先加進專案才能在 BD 裡用 module reference 放進去
# （要在 create_bd_design 之後才加：2018.2 在建 BD 之前先 add_files/update_compile_order，
#   create_bd_design 會報 couldn't read file "addr.tcl"）
add_files -norecurse [list rtl/configurable_counter.vhd rtl/breathing_pwm_top.vhd rtl/btn_debounce.v]
add_files -fileset sim_1 -norecurse [list rtl/tb_breathing_pwm.vhd rtl/tb_btn_debounce.v]
set_property FILE_TYPE {VHDL 2008} [get_files tb_breathing_pwm.vhd]
set_property top tb_breathing_pwm [get_filesets sim_1]
update_compile_order -fileset sources_1

# M_AXI_GP0 + FCLK_CLK0 給 PL 的 AXI GPIO / breathing_pwm_top 用
set_property CONFIG.PCW_USE_M_AXI_GP0 {1} [get_bd_cells ps7]
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} [get_bd_cells ps7]

# PL -> PS 中斷輸入 IRQ_F2P（UG585 Table 7-4：IRQ_F2P[0] = IRQ ID 61）
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {1} [get_bd_cells ps7]
set_property CONFIG.PCW_IRQ_F2P_INTR        {1} [get_bd_cells ps7]

# DDR3：EGO-XZ7 板上是 2 顆 GT8UB256M16BP-BG（256M x16，4Gb，Row 15），選 Micron 等效料號。
# 沒設的話 Vivado 預設 MT41J128M8（x8、1Gb、Row 14），DDR 參數錯 → 上板 CPU 開 cache 後
# 一開機就掛在 boot.S，main() 跑不到
set_property CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} [get_bd_cells ps7]

# DDR / FIXED_IO / PS_CLK 拉到外部（每個 Zynq 設計都要）
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR, PS_CLK" apply_board_preset "0" \
              Master "Disable" Slave "Disable"} [get_bd_cells ps7]

# AXI GPIO：1 bit 輸出 = 呼吸燈 mode
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_mode
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1}] \
    [get_bd_cells axi_gpio_mode]

# 自動接 AXI：會產生 AXI Interconnect + Processor System Reset，時脈用 FCLK_CLK0
# （rst_ps7_50M 不能拿掉：AXI 規格 IHI0022L A2.1.2 要求 ARESETn 同步於 ACLK 放開，
#   FCLK_RESET0_N 直接接的話 validate_bd_design 會報 8 個 CRITICAL WARNING [BD 41-1348]）
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} \
    [get_bd_intf_pins axi_gpio_mode/S_AXI]

# AXI GPIO：1 bit 輸入 = 防彈跳後的 S6，開 interrupt（輸入變化 -> ip2intc_irpt）
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_btn
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_INPUTS {1} \
                         CONFIG.C_INTERRUPT_PRESENT {1}] \
    [get_bd_cells axi_gpio_btn]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} \
    [get_bd_intf_pins axi_gpio_btn/S_AXI]

connect_bd_net [get_bd_pins axi_gpio_btn/ip2intc_irpt] [get_bd_pins ps7/IRQ_F2P]

# PL 按鈕同步 + 防彈跳（Verilog module reference）
create_bd_cell -type module -reference btn_debounce btn_debounce_0
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins btn_debounce_0/clk]
connect_bd_net [get_bd_pins [get_bd_cells -filter {VLNV =~ "*proc_sys_reset*"}]/peripheral_aresetn] \
               [get_bd_pins btn_debounce_0/resetn]
connect_bd_net [get_bd_pins btn_debounce_0/btn_out] [get_bd_pins axi_gpio_btn/gpio_io_i]

create_bd_port -dir I btn
connect_bd_net [get_bd_ports btn] [get_bd_pins btn_debounce_0/btn_in]

# PL 呼吸燈 PWM（VHDL module reference）
create_bd_cell -type module -reference breathing_pwm_top breathing_pwm_0
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins breathing_pwm_0/clk]
connect_bd_net [get_bd_pins [get_bd_cells -filter {VLNV =~ "*proc_sys_reset*"}]/peripheral_aresetn] \
               [get_bd_pins breathing_pwm_0/resetn]
connect_bd_net [get_bd_pins axi_gpio_mode/gpio_io_o] [get_bd_pins breathing_pwm_0/mode]

create_bd_port -dir O led0
connect_bd_net [get_bd_pins breathing_pwm_0/led_out] [get_bd_ports led0]

regenerate_bd_layout
validate_bd_design
save_bd_design

# BD 裡有 module reference（breathing_pwm_top、btn_debounce）時，2018.2 batch 模式不會自動幫各 IP 建 OOC 合成 run，
# synth_1 會報 module 'system_axi_gpio_mode_0' not found；改成 global 合成並明確產生輸出檔
set_property synth_checkpoint_mode None [get_files system.bd]
generate_target all [get_files system.bd]

make_wrapper -files [get_files system.bd] -top
add_files -norecurse [glob [get_property DIRECTORY [current_project]]/$proj_name.srcs/sources_1/bd/system/hdl/system_wrapper.v]
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse constraints/hw2.xdc

puts "Block design 建立完成，驗證通過（validate_bd_design 無錯誤）。"
puts "接下來：Generate Bitstream -> Export Hardware (含 bitstream) -> 開 SDK，"
puts "用匯出的 xparameters.h 核對 sdk/src/main.c 開頭那幾個裝置/中斷 ID 巨集。"
