# HW3 block design：HW2 版本二（ps7 + btn_led_ctrl）再打開 PS 端 SD0、UART1、ENET0、QSPI，
# 讓 FSBL / U-Boot / Linux 可以從 SD 卡開機，console 走 J1 的 USB-UART
#
# 用法（在 HW3/vivado/ 目錄下）：
#   vivado -mode batch -source build_hw.tcl
#   （build_hw.tcl 會 source 這支，再跑合成、實作、產生 bitstream、匯出 HDF）
#
# PL 端沿用 HW2 版本二：btn_led_ctrl 接 M_AXI_GP0（0x43C00000），irq 接 IRQ_F2P[0]（IRQ ID 61），
# IP 和腳位約束直接用 HW2/ip_repo、HW2/vivado/constraints。

set hw2        [file normalize [file dirname [info script]]/../../HW2/vivado]
set proj_name  "hw3_linux"
set proj_dir   [expr {$argc > 0 ? [lindex $argv 0] : "./build"}]
set part       "xc7z020clg484-1"

create_project $proj_name $proj_dir -part $part -force

# 自製 IP 所在的 repository
set_property ip_repo_paths [file normalize $hw2/../ip_repo] [current_project]
update_ip_catalog

create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7

# M_AXI_GP0 + FCLK_CLK0（50 MHz）、PL -> PS 中斷 IRQ_F2P，同 HW2
set_property CONFIG.PCW_USE_M_AXI_GP0            {1}  [get_bd_cells ps7]
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} [get_bd_cells ps7]
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT     {1}  [get_bd_cells ps7]
set_property CONFIG.PCW_IRQ_F2P_INTR             {1}  [get_bd_cells ps7]
# EGO-XZ7 的 DDR3（原因見 HW2/vivado/create_bd.tcl）
set_property CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41J256M16 RE-125} [get_bd_cells ps7]

# SD 卡開機與 Linux 需要的 PS 周邊（腳位依 EGO-XZ7 User Guide 表 5、表 8、表 14）
#   MIO Bank 500 = 3.3V、Bank 501 = 1.8V（SD 經 TXB0612 轉 1.8V）
#   microSD J15：MIO40-45 = SD0（CD 腳未接，不啟用）
#   J1 FT2232 UART：MIO48 = RXD、MIO49 = TXD = UART1，115200
#   Ethernet（Marvell 88E1518，表 14）：RGMII = MIO16-27 = ENET0，MDC/MDIO = MIO52/53
#     U-Boot 開機會初始化 GEM，沒開 ENET0 的話 GEM 沒時脈，U-Boot 卡在 Net:
#   QSPI Flash（Micron N25Q256，U8）：MIO1-6，single SS
#     這版 U-Boot 會從 QSPI 讀 MAC 位址，沒開 QSPI 一樣卡在 Net:
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE {0} \
    CONFIG.PCW_SD0_GRP_WP_ENABLE {0} \
    CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_UART1_BAUD_RATE {115200} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_ENABLE {1} \
    CONFIG.PCW_QSPI_GRP_SINGLE_SS_IO {MIO 1 .. 6} \
    CONFIG.PCW_QSPI_GRP_FBCLK_ENABLE {0} \
] [get_bd_cells ps7]

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

# 腳位同 HW2：btn = S6 (P16)、led0 = LED0 (T22)
add_files -fileset constrs_1 -norecurse $hw2/constraints/hw2.xdc
