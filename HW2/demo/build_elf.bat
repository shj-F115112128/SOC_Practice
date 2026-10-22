@echo off
rem 改完 sdk\src\main.c 之後重新編譯，輸出覆蓋 demo\hw2_led_isr.elf（再跑 demo.bat 上板）
rem BSP / linker script 在 vivado\build\plbtn\hw2_led_isr.sdk（由 Vivado 匯出的 HDF 產生）
cd /d "%~dp0"
set GCC=C:\Xilinx\SDK\2018.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe
set SDK=..\vivado\build\plbtn\hw2_led_isr.sdk
set BSP=%SDK%\hw2_app_bsp\ps7_cortexa9_0
set FLAGS=-mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard

"%GCC%" -Wall -Wextra -O0 -g %FLAGS% -I%BSP%\include -c ..\sdk\src\main.c -o "%TEMP%\hw2_main.o"
if errorlevel 1 goto fail
"%GCC%" %FLAGS% -Wl,-T -Wl,%SDK%\app_tmpl\lscript.ld -specs=%SDK%\app_tmpl\Xilinx.spec -Wl,--build-id=none ^
    -L%BSP%\lib "%TEMP%\hw2_main.o" -Wl,--start-group,-lxil,-lgcc,-lc,--end-group -o hw2_led_isr.elf
if errorlevel 1 goto fail
echo BUILD OK: demo\hw2_led_isr.elf
pause
exit /b 0

:fail
echo BUILD FAILED
pause
exit /b 1
