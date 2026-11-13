@echo off
rem 更 Digilent Zybo Z7-20  PetaLinux BSP箇絪 U-Boot / kernel / rootfs / dtb  prebuilt\
rem Zybo Z7-20 蛤 EGO-XZ7  XC7Z020console 常琌 UART1MIO48/49SD 常琌 SD0DDR 常琌 1 GB
cd /d "%~dp0"
set URL=https://github.com/Digilent/Petalinux-Zybo-Z7-20/releases/download/v2017.4-3/Petalinux-Zybo-Z7-20-2017.4-3.bsp
set IMG=Zybo-Z7-20/pre-built/linux/images
if not exist prebuilt mkdir prebuilt
if not exist prebuilt\zybo.bsp curl -L -o prebuilt\zybo.bsp %URL% || goto fail
tar -xzf prebuilt\zybo.bsp -C prebuilt %IMG%/u-boot.elf %IMG%/image.ub %IMG%/zImage %IMG%/system.dtb || goto fail
for %%f in (u-boot.elf image.ub zImage system.dtb) do move /y "prebuilt\Zybo-Z7-20\pre-built\linux\images\%%f" prebuilt\ >nul
rmdir /s /q prebuilt\Zybo-Z7-20
dir prebuilt
exit /b 0
:fail
echo 更┪秆溃ア毖
exit /b 1
