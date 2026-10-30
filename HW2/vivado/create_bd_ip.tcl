# HW2 IP 封裝版 block design：ps7 + 自製 IP btn_led_ctrl（ip_repo/btn_led_ctrl_1.0）
#
# 用法（在 vivado/ 目錄下）：
#   vivado -mode batch -source create_bd_ip.tcl [-tclargs <專案目錄>]
#   專案目錄預設 ./build/ipw；create_project -force 會清空該目錄
#
# 跟 create_bd.tcl 的差別：btn_debounce_0、axi_gpio_btn、axi_gpio_mode、breathing_pwm_0 四個方塊
# 包成一顆 btn_led_ctrl。CPU 經 M_AXI_GP0 讀寫它的 4 個暫存器（0x43C00000），它的 irq 接 IRQ_F2P[0]（IRQ ID 61）。

set here       [file dirname [file normalize [info script]]]
set proj_name  "hw2_ipw"
set proj_dir   [expr {$argc > 0 ? [lindex $argv 0] : "./build/ipw"}]
set part       "xc7z020clg484-1"

create_project $proj_name $proj_dir -part $part -force

# 自製 IP 所在的 repository
set_property ip_repo_paths [file normalize $here/../ip_repo] [current_project]
update_ip_catalog

create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# M_AXI_GP0 + FCLK_CLK0（50 MHz）、PL -> PS 中斷 IRQ_F2P，設定同 create_bd.tcl
set_property CONFIG.PCW_USE_M_AXI_GP0            {1}  [get_bd_cells ps7]
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} [get_bd_cells ps7]
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT     {1}  [get_bd_cells ps7]
set_property CONFIG.PCW_IRQ_F2P_INTR             {1}  [get_bd_cells ps7]
# EGO-XZ7 的 DDR3（原因見 create_bd.tcl）
set_property CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} [get_bd_cells ps7]

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR, PS_CLK" apply_board_preset "0" \
              Master "Disable" Slave "Disable"} [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:user:btn_led_ctrl:1.0 btn_led_ctrl_0

# S00_AXI 接 M_AXI_GP0：自動產生 AXI Interconnect + Processor System Reset，時脈 FCLK_CLK0
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} \
    [get_bd_intf_pins btn_led_ctrl_0/S00_AXI]

connect_bd_net [get_bd_pins btn_led_ctrl_0/irq] [get_bd_pins ps7/IRQ_F2P]

create_bd_port -dir I btn
connect_bd_net [get_bd_ports btn] [get_bd_pins btn_led_ctrl_0/btn]
create_bd_port -dir O led0
connect_bd_net [get_bd_pins btn_led_ctrl_0/led0] [get_bd_ports led0]

regenerate_bd_layout
validate_bd_design
save_bd_design

generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [glob [get_property DIRECTORY [current_project]]/$proj_name.srcs/sources_1/bd/system/hdl/system_wrapper.v]
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

# 腳位跟版本一相同：btn = S6 (P16)、led0 = LED0 (T22)
add_files -fileset constrs_1 -norecurse constraints/hw2.xdc

# 模擬：IP 的 testbench
add_files -fileset sim_1 -norecurse rtl/tb_btn_led_ctrl.v
set_property top tb_btn_led_ctrl [get_filesets sim_1]

puts "Block design 建立完成。接下來：Generate Bitstream -> Export Hardware (含 bitstream) -> SDK 編譯 sdk/src_ip/main.c"
