# 建 block design -> 合成 -> 實作 -> bitstream -> 匯出 HDF（含 bitstream）給 boot/ 產生 FSBL
#
# 用法（在 HW3/vivado/ 目錄下）：
#   vivado -mode batch -source build_hw.tcl
# 輸出：../boot/hw/system_wrapper.hdf

set here [file normalize [file dirname [info script]]]
set argv [list $here/build]
set argc 1
source $here/create_bd_linux.tcl

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "impl_1 沒有跑完，看 build/hw3_linux.runs/impl_1/runme.log"
}
open_run impl_1
report_timing_summary -file $here/build/timing.rpt
puts "WNS = [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"
puts "WHS = [get_property SLACK [get_timing_paths -max_paths 1 -hold]] ns"

set out [file normalize $here/../boot/hw]
file mkdir $out
write_hwdef -force -file $out/system_wrapper.hwdef
write_sysdef -force -hwdef $out/system_wrapper.hwdef \
    -bitfile [glob $here/build/hw3_linux.runs/impl_1/system_wrapper.bit] \
    -file $out/system_wrapper.hdf
puts "HDF：$out/system_wrapper.hdf"
