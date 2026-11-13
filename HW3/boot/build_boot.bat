@echo off
rem 產生 SD 卡要放的檔案到 ..\sd\
rem 先跑過 ..\vivado 的 build_hw.tcl（產生 hw\system_wrapper.hdf）和 get_prebuilt.bat
cd /d "%~dp0"
call C:\Xilinx\SDK\2018.2\bin\xsct.bat fsbl.tcl || goto fail
python make_ego_dtb.py prebuilt\system.dtb ..\sd\ego.dtb || goto fail
call C:\Xilinx\SDK\2018.2\bin\bootgen.bat -image boot.bif -arch zynq -o ..\sd\BOOT.BIN -w on || goto fail
copy /y prebuilt\image.ub ..\sd\ >nul
copy /y prebuilt\zImage ..\sd\ >nul
copy /y prebuilt\system.dtb ..\sd\zybo.dtb >nul
dir ..\sd
exit /b 0
:fail
echo 失敗
exit /b 1
