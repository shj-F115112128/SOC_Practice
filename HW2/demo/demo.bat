@echo off
rem HW2 demo：燒 bitstream + 下載 ELF + 執行（板子 SW8 全 ON、JTAG 線接好、電源打開）
cd /d "%~dp0"
call C:\Xilinx\SDK\2018.2\bin\xsct.bat run_on_board.tcl
pause
