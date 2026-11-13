# 用 vivado/build_hw.tcl 匯出的 HDF 產生並編譯 FSBL（xsct）
# 用法（在 HW3/boot/ 目錄下）：xsct fsbl.tcl
# 輸出：fsbl/executable.elf；hw/ 底下會多出 ps7_init.*、system_wrapper.bit
set hw [hsi::open_hw_design hw/system_wrapper.hdf]
hsi::generate_app -hw $hw -os standalone -proc ps7_cortexa9_0 -app zynq_fsbl -compile -sw fsbl -dir fsbl
hsi::close_hw_design $hw
