@echo off
rem 開 Vivado 專案（看 / 截圖 block design 用）
cd /d "%~dp0..\vivado\build\plbtn"
start "" C:\Xilinx\Vivado\2018.2\bin\vivado.bat hw2_led_isr.xpr
