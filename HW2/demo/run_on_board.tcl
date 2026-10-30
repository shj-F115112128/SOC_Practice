# 上板：燒 bitstream -> ps7_init -> 下載 ELF -> 執行
# 用法：雙擊 demo.bat（版本一）或 demo_ip.bat（IP 封裝版，檔案在 ip/）；板子 SW8 全 ON = JTAG 開機
#      xsct run_on_board.tcl [子資料夾]
set here [file dirname [file normalize [info script]]]
if {$argc > 0} { set here [file join $here [lindex $argv 0]] }
set elf  [lindex [glob -directory $here *.elf] 0]
connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 1000
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file [file join $here system_wrapper.bit]
targets -set -nocase -filter {name =~ "APU*"}
source [file join $here ps7_init.tcl]
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf
con
puts "DONE: [file tail $elf] running on CPU0. LED0 = fixed on, press S6 (BTNC) to toggle breathing."
jtagterminal -start
