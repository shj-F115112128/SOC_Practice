# 不經過 SD 卡的 BOOT.BIN，直接用 JTAG 載入 ps7_init + bitstream + U-Boot
# U-Boot 起來後一樣從 SD 卡讀 kernel / dtb。改硬體後想先測、不想拔卡更新 BOOT.BIN 時用
# 用法（在 HW3/tools/ 目錄下）：xsct jtag_uboot.tcl
connect
targets -set -filter {name =~ "APU*"}
rst -system
after 1000
targets -set -filter {name =~ "xc7z020"}
fpga -f ../boot/hw/system_wrapper.bit
targets -set -filter {name =~ "APU*"}
source ../boot/hw/ps7_init.tcl
ps7_init
ps7_post_config
targets -set -filter {name =~ "*#0"}
dow ../boot/prebuilt/u-boot.elf
con
