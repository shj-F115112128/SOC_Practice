#!/bin/bash
# 在 WSL（Ubuntu 22.04）準備編 driver 用的 kernel 原始碼：
#   1. 安裝編譯工具（ARM 交叉編譯器 gcc-9、bc、bison、flex…）
#   2. 下載板子 kernel 的原始碼：Digilent linux-digilent，commit 1496c680（Digilent Zybo Z7 PetaLinux 2017.4 BSP 用的版本）
#   3. 套用從板子 zImage 取出的 config，編完整個 kernel，產生 Module.symvers（module 的 symbol CRC 要跟板子一致）
# 用法（在 HW4/kernel 目錄）：bash build_kernel.sh      輸出在 ~/hw4/linux
set -e

COMMIT=1496c680c6df2e3911feed13aa9663a851bf30e9
WORK=$HOME/hw4
KDIR=$WORK/linux
HERE=$(cd "$(dirname "$0")" && pwd)

if ! command -v arm-linux-gnueabihf-gcc-9 >/dev/null || ! command -v bison >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential gcc-9 gcc-9-arm-linux-gnueabihf binutils-arm-linux-gnueabihf \
        libc6-dev-armhf-cross bc bison flex libssl-dev
fi

# kernel 4.9 太舊，用新版 gcc 編會出錯；交叉編譯器和主機編譯器都固定用 gcc-9
mkdir -p "$WORK/bin"
for t in /usr/bin/arm-linux-gnueabihf-*; do
    ln -sf "$t" "$WORK/bin/$(basename "$t")"
done
ln -sf /usr/bin/arm-linux-gnueabihf-gcc-9 "$WORK/bin/arm-linux-gnueabihf-gcc"
export PATH=$WORK/bin:$PATH

if [ ! -f "$KDIR/Makefile" ]; then
    mkdir -p "$WORK"
    cd "$WORK"
    wget -nc -O linux-digilent.tar.gz "https://github.com/Digilent/linux-digilent/archive/$COMMIT.tar.gz"
    tar xzf linux-digilent.tar.gz
    mv "linux-digilent-$COMMIT" "$KDIR"
fi

cd "$KDIR"
cp "$HERE/config-4.9.0-xilinx-v2017.4" .config
MK="make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- HOSTCC=gcc-9"
$MK olddefconfig
$MK -j"$(nproc)" zImage modules

echo
echo "kernel release: $(cat include/config/kernel.release)"
echo "Module.symvers: $(wc -l < Module.symvers) symbols"
