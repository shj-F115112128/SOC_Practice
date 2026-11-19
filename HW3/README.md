# HW3：Linux 透過 SD 卡開機

平台：EGO-XZ7（Zynq-7000, XC7Z020），開發環境 Vivado 2018.2 + Xilinx SDK 2018.2。

## 題目

在 EGO-XZ7 上掛載 Linux。

- 基本要求：透過 SD 卡開機，需要 ① kernel image ② file system。
- Bonus：① bootloader ② kernel ③ file system 從原始碼自己 build（附 source URL），
  開機時在 bootloader 的 console 選 config 開機，進到 Linux 畫面。

做法：硬體（PS 設定 + PL bitstream）和 FSBL 用自己的 Vivado 專案產生；U-Boot、kernel、rootfs 用 Digilent
Zybo Z7-20 的預編檔；device tree 從 Zybo 的改成 EGO-XZ7 版本。U-Boot console 裡可以選 kernel 和 device tree。

## 開機流程

```
BootROM（晶片內建，SW8 選 SD 開機）
  └─ 讀 SD 卡 FAT 分割區的 BOOT.BIN
       ├─ FSBL         在 OCM 執行：初始化 DDR、MIO、時脈，把 bitstream 燒進 PL
       ├─ bitstream    PL：HW2 版本二的 btn_led_ctrl
       └─ U-Boot       在 DDR 執行：讀 uEnv.txt，倒數 4 秒，按任意鍵進 console
            └─ fatload image.ub（kernel + rootfs）、ego.dtb → bootm
                 └─ Linux 4.9 → rootfs（ramdisk）→ root shell
```

## SD 卡內容

一個 1 GB 的 FAT32 主分割區（設為 active），放 6 個檔案：

| 檔案 | 內容 | 來源 |
|---|---|---|
| `BOOT.BIN` | FSBL + bitstream + U-Boot | [`boot/boot.bif`](boot/boot.bif) 用 bootgen 打包 |
| `uEnv.txt` | U-Boot 開機選單 | [`sd/uEnv.txt`](sd/uEnv.txt) |
| `ego.dtb` | EGO-XZ7 的 device tree | [`boot/make_ego_dtb.py`](boot/make_ego_dtb.py)，文字版 [`boot/ego.dts`](boot/ego.dts) |
| `image.ub` | FIT image：kernel + Zybo dtb + ramdisk rootfs | Digilent 預編 |
| `zImage` | kernel，rootfs 以 initramfs 包在裡面 | Digilent 預編 |
| `zybo.dtb` | Zybo 原本的 device tree，對照用 | Digilent 預編 |

`image.ub`、`zImage`、`zybo.dtb` 太大（各約 55 MB）沒進 git，用 [`boot/get_prebuilt.bat`](boot/get_prebuilt.bat) 下載。

## 各元件來源

| 元件 | 版本 | 原始碼 |
|---|---|---|
| FSBL | SDK 2018.2 `zynq_fsbl`，自己產生（[`boot/fsbl.tcl`](boot/fsbl.tcl)） | SDK 內附範本 |
| U-Boot | 2017.01（`xilinx-v2017.4`） | https://github.com/Xilinx/u-boot-xlnx/tree/xilinx-v2017.4 |
| kernel | Linux 4.9.0-xilinx-v2017.4 | https://github.com/Xilinx/linux-xlnx/tree/xilinx-v2017.4 |
| rootfs | PetaLinux 2017.4（Yocto） | https://github.com/Digilent/Petalinux-Zybo-Z7-20 |
| device tree | 從 Zybo 的 `system.dtb` 修改 | [`boot/make_ego_dtb.py`](boot/make_ego_dtb.py) |

U-Boot、kernel、rootfs 取自 [Petalinux-Zybo-Z7-20 v2017.4-3](https://github.com/Digilent/Petalinux-Zybo-Z7-20/releases/tag/v2017.4-3)
的 `pre-built/linux/images/`。能借用是因為兩塊板子都是 XC7Z020、console 在 UART1（MIO48/49）、SD 在 SD0（MIO40-45）、
DDR 1 GB；不同的地方（DDR 型號、PL 周邊）由自己的 FSBL 和 device tree 處理。

## PS 端設定

[`vivado/create_bd_linux.tcl`](vivado/create_bd_linux.tcl) 以 HW2 版本二的 block design 為基礎（PL 一樣是 `btn_led_ctrl`，
`0x43C00000`、IRQ 61），PS 多開 4 個周邊（MIO Bank 500 = 3.3V、Bank 501 = 1.8V）：

| 周邊 | MIO | 板上元件 | 沒開的話 |
|---|---|---|---|
| SD0 | 40-45 | microSD J15 | 序列埠沒輸出；xsct 看到 CPU 停在 FSBL 的 `FsblHookFallback` |
| UART1 | 48（RX）、49（TX） | J1 FT2232HQ channel B，115200 8N1 | 同上，沒有 console |
| ENET0 | 16-27（RGMII）、52-53（MDIO） | Marvell 88E1518 PHY | U-Boot 停在 `Net:   ZYNQ GEM: e000b000 ...`（GEM 沒時脈） |
| QSPI | 1-6（single SS） | Micron N25Q256 Flash | 同一行卡住：U-Boot 讀 MAC 位址時 `spi_flash_probe` → `zynq_qspi_irq_poll` |

## Device tree

Zybo 的 `amba_pl` 底下是它範例設計的 PL 周邊（HDMI、VDMA 等），EGO-XZ7 的 bitstream 沒有，kernel 存取會出錯。
`make_ego_dtb.py` 刪掉整個 `amba_pl`，改放 HW2 的 IP，並把 `model` 改成 `EGO-XZ7 (Zynq XC7Z020)` 方便確認用的是哪份 dtb：

```dts
btn_led_ctrl@43c00000 {
    compatible = "generic-uio";   /* bootargs 有 uio_pdrv_genirq.of_id=generic-uio → /dev/uio0 */
    reg = <0x43c00000 0x10000>;
    interrupt-parent = <&intc>;
    interrupts = <0 29 4>;        /* SPI 29 = IRQ ID 61 - 32，4 = level high */
    clocks = <&clkc 15>;          /* fclk0 */
};
```

PS 端節點（UART、SD、GEM、GIC、時脈）兩塊板子相同，沒有改。

## U-Boot console：選 kernel、選 device tree

[`uEnv.txt`](sd/uEnv.txt) 定義 3 種開機方式，倒數 4 秒沒按鍵自動跑 `boot_ego`：

| 指令 | kernel + rootfs | device tree |
|---|---|---|
| `run boot_ego` | `image.ub` | `ego.dtb` |
| `run boot_zimage` | `zImage`（initramfs） | `ego.dtb` |
| `run boot_zybo` | `image.ub` | Zybo dtb（PL 對不上，只當對照） |

也可以手動打：

```
Zynq> fatload mmc 0 0x10000000 image.ub
Zynq> fatload mmc 0 0x1F000000 ego.dtb
Zynq> bootm 0x10000000:kernel@0 0x10000000:ramdisk@0 0x1F000000
```

`bootm` 三個參數是 kernel、ramdisk、device tree；第三個給 `ego.dtb` 就會取代 FIT 裡附的 Zybo dtb。
`zImage` 改用 `bootz <kernel> - <dtb>`，`-` 表示沒有另外的 ramdisk。

## 建置

需要 Vivado / SDK 2018.2、Python 3（`pip install fdt pyserial`）：

```
cd vivado
vivado -mode batch -source build_hw.tcl    # bitstream → boot/hw/system_wrapper.hdf（WNS 13.060 ns）
cd ../boot
get_prebuilt.bat                           # 下載 Digilent 預編檔（122 MB）
build_boot.bat                             # FSBL → ego.dtb → BOOT.BIN，輸出到 ../sd/
```

SD 卡超過 32 GB 時 Windows 格式化介面沒有 FAT32，用 diskpart（`clean` 會清整張卡，先 `list disk` 確認編號）：

```
diskpart
list disk
select disk 2
clean
create partition primary size=1024
active
format fs=fat32 quick label=BOOT
assign letter=F
```

再把 `sd/` 底下 6 個檔案複製到 SD 卡根目錄。

## 上板

1. SD 卡插 J15，SW8 撥成 SD 開機（ON = 0）：

   | SW8 | 1 | 2 | 3 | 4 | 5 | 6 |
   |---|---|---|---|---|---|---|
   | SD 開機 | ON | ON | OFF | OFF | ON | ON |
   | JTAG 開機（HW2） | ON | ON | ON | ON | ON | ON |

2. J1 接 USB，開序列埠（COM 編號看裝置管理員）：`python -m serial.tools.miniterm COM4 115200`
3. 開電源，倒數時按任意鍵進 U-Boot console，打 `run boot_ego`，最後自動以 root 登入。

[`tools/`](tools/) 的測試腳本：[`boot_test.py`](tools/boot_test.py) 自動攔 autoboot、選 kernel / dtb、跑檢查指令存 log；
[`jtag_uboot.tcl`](tools/jtag_uboot.tcl) 用 JTAG 載 U-Boot，改硬體後不用先更新 SD 卡；
[`update_bootbin.py`](tools/update_bootbin.py) 不拔卡，用 U-Boot 的 `fatwrite` 更新 `BOOT.BIN`。

## 驗證結果

SD 卡冷開機（沒接 JTAG）的完整紀錄在 [`log/boot_sd.txt`](log/boot_sd.txt)。

```
U-Boot 2017.01 (Apr 17 2019 - 12:55:19 +0300)
DRAM:  ECC disabled 1 GiB
MMC:   sdhci@e0100000: 0 (SD)
reading uEnv.txt
Hit any key to stop autoboot:  4  0
Zynq> run boot_ego
## Loading kernel from FIT Image at 10000000 ...
## Loading ramdisk from FIT Image at 10000000 ...
   Loading Device Tree to 04eda000, end 04edfc0a ... OK
Starting kernel ...

root@Zybo-Z7-20:~# uname -a
Linux Zybo-Z7-20 4.9.0-xilinx-v2017.4 #1 SMP PREEMPT Wed Apr 17 13:10:48 EEST 2019 armv7l GNU/Linux
root@Zybo-Z7-20:~# cat /proc/device-tree/model
EGO-XZ7 (Zynq XC7Z020)
root@Zybo-Z7-20:~# head -1 /proc/meminfo
MemTotal:        1030180 kB
root@Zybo-Z7-20:~# df -h
/dev/mmcblk0p1         1020.0M    110.1M    909.9M  11% /run/media/mmcblk0p1
root@Zybo-Z7-20:~# cat /sys/class/uio/uio0/name /sys/class/uio/uio0/maps/map0/addr
btn_led_ctrl
0x43c00000
root@Zybo-Z7-20:~# grep btn /proc/interrupts
 48:          0          0     GIC-0  61 Level     btn_led_ctrl
```

- kernel、rootfs 正常啟動，兩顆 Cortex-A9 都起來；用的是 `ego.dtb`，DDR 1 GB 都抓到。
- SD 卡 FAT32 分割區自動掛在 `/run/media/mmcblk0p1`。
- PL 的 `btn_led_ctrl` 變成 `/dev/uio0`，中斷掛在 GIC 61、level，跟 HW2 一樣。

U-Boot 的 `PHY auto negotiation ... TIMEOUT` 是沒接網路線；banner 和 hostname 還是 Zybo，因為寫死在預編檔裡。
