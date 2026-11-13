# HW3：Linux 透過 SD 卡開機

平台：EGO-XZ7（Zynq-7000, XC7Z020），開發環境 Vivado 2018.2 + Xilinx SDK 2018.2。

## 題目

在 EGO-XZ7 上掛載 Linux。

- 基本要求：透過 SD 卡開機，需要 ① kernel image ② file system。
- Bonus：① bootloader ② kernel ③ file system 從原始碼自己 build（附 source URL），
  開機時在 bootloader 的 console 選 config 開機，進到 Linux 畫面。

這份做法是：硬體（PS 設定 + PL bitstream）和 FSBL 用自己的 Vivado 專案產生，U-Boot、kernel、rootfs
用 Digilent Zybo Z7-20 的預編檔，device tree 從 Zybo 的改成 EGO-XZ7 的版本。
U-Boot 的 console 裡可以選要開哪一個 kernel、配哪一個 device tree。

## 開機流程

```
BootROM（晶片內建，SW8 選 SD 開機）
  └─ 讀 SD 卡第一個 FAT 分割區的 BOOT.BIN
       ├─ FSBL         初始化 DDR、MIO、時脈，把 bitstream 燒進 PL
       ├─ bitstream    PL：HW2 版本二的 btn_led_ctrl
       └─ U-Boot       讀 uEnv.txt，倒數 4 秒，按任意鍵進 console
            └─ fatload image.ub（kernel + rootfs）、ego.dtb → bootm
                 └─ Linux 4.9 → rootfs（ramdisk）→ root shell
```

| 階段 | 執行位置 | 檔案 |
|---|---|---|
| BootROM | 晶片內 ROM | 無（燒死在晶片裡） |
| FSBL | OCM（晶片內 256 KB RAM） | `BOOT.BIN` 的第 1 個 partition |
| U-Boot | DDR | `BOOT.BIN` 的第 3 個 partition |
| kernel | DDR | `image.ub` 裡的 `kernel@0`，或 `zImage` |
| device tree | DDR | `ego.dtb` |
| rootfs | DDR（ramdisk） | `image.ub` 裡的 `ramdisk@0`，或包在 `zImage` 裡的 initramfs |

## SD 卡內容

SD 卡切一個 1 GB 的 FAT32 主分割區（設為 active），放這 6 個檔案：

| 檔案 | 內容 | 來源 |
|---|---|---|
| `BOOT.BIN` | FSBL + bitstream + U-Boot | [`boot/boot.bif`](boot/boot.bif) 用 bootgen 打包 |
| `uEnv.txt` | U-Boot 開機選單 | [`sd/uEnv.txt`](sd/uEnv.txt) |
| `ego.dtb` | EGO-XZ7 的 device tree | [`boot/make_ego_dtb.py`](boot/make_ego_dtb.py) 產生，可讀版本是 [`boot/ego.dts`](boot/ego.dts) |
| `image.ub` | FIT image：kernel + Zybo 的 dtb + ramdisk rootfs（55 MB） | Digilent 預編 |
| `zImage` | kernel，rootfs 以 initramfs 包在裡面（55 MB） | Digilent 預編 |
| `zybo.dtb` | Zybo Z7 原本的 device tree，對照用 | Digilent 預編 |

`BOOT.BIN`、`ego.dtb`、`uEnv.txt` 有放在 [`sd/`](sd/)；`image.ub`、`zImage`、`zybo.dtb` 太大沒進 git，
用 [`boot/get_prebuilt.bat`](boot/get_prebuilt.bat) 下載。

## 各元件來源

| 元件 | 版本 | 預編檔 | 原始碼 |
|---|---|---|---|
| FSBL | Xilinx SDK 2018.2 `zynq_fsbl` | 自己產生（[`boot/fsbl.tcl`](boot/fsbl.tcl)） | SDK 內附範本 |
| U-Boot | 2017.01（`xilinx-v2017.4`） | [Petalinux-Zybo-Z7-20 v2017.4-3](https://github.com/Digilent/Petalinux-Zybo-Z7-20/releases/tag/v2017.4-3) 的 `pre-built/linux/images/u-boot.elf` | https://github.com/Xilinx/u-boot-xlnx/tree/xilinx-v2017.4 |
| kernel | Linux 4.9.0-xilinx-v2017.4 | 同上，`image.ub`、`zImage` | https://github.com/Xilinx/linux-xlnx/tree/xilinx-v2017.4 |
| rootfs | PetaLinux 2017.4（Yocto） | 同上，`image.ub` 的 ramdisk | https://github.com/Digilent/Petalinux-Zybo-Z7-20 （PetaLinux 專案設定） |
| device tree | — | 從 Zybo 的 `system.dtb` 修改 | [`boot/make_ego_dtb.py`](boot/make_ego_dtb.py) |

借用 Zybo Z7-20 的檔案是因為它跟 EGO-XZ7 一樣是 XC7Z020，console 都在 UART1（MIO48/49），
SD 卡都在 SD0（MIO40-45），DDR 都是 1 GB。兩塊板子不一樣的地方（DDR 型號、PL 周邊）由自己的 FSBL
和 device tree 處理。

## PS 端設定

[`vivado/create_bd_linux.tcl`](vivado/create_bd_linux.tcl) 以 HW2 版本二的 block design 為基礎（PL 一樣是
`btn_led_ctrl`，`0x43C00000`、IRQ 61），PS 多開了 4 個周邊。腳位依 EGO-XZ7 User Guide V1.2：

| 周邊 | MIO | 板上元件 | 用途 |
|---|---|---|---|
| SD0 | 40-45（CD、WP 不接） | microSD J15，經 TXB0612 轉 1.8V（表 5） | FSBL 讀 `BOOT.BIN`，U-Boot 讀 kernel |
| UART1 | 48（RX）、49（TX） | J1 FT2232HQ 的 channel B（表 8） | U-Boot / Linux console，115200 8N1 |
| ENET0 | 16-27（RGMII）、52-53（MDIO） | Marvell 88E1518 PHY（表 14） | U-Boot 開機會初始化網路 |
| QSPI | 1-6（single SS） | Micron N25Q256 Flash（U8） | U-Boot 開機會從 QSPI 讀 MAC 位址 |

MIO Bank 500 設 3.3V、Bank 501 設 1.8V。

HW2 的硬體只用 JTAG 開機，PS 這 4 個周邊都沒開，直接拿來做 SD 開機會卡在不同地方：

| 少開的周邊 | 現象 | 怎麼看出來的 |
|---|---|---|
| SD0、UART1 | 序列埠沒有任何輸出 | xsct 讀 `BOOT_MODE` = 0x5（SD），CPU 停在 FSBL 的 `FsblHookFallback`（FSBL 沒有 SD driver） |
| ENET0 | U-Boot 停在 `Net:   ZYNQ GEM: e000b000 ...` | GEM 沒有時脈 |
| QSPI | 開了 ENET0 之後還是停在同一行 | xsct 抓 call stack：`eth_initialize` → `zynq_board_read_rom_ethaddr` → `spi_flash_probe` → `zynq_qspi_irq_poll` |

## Device tree

Zybo 的 `system.dtb` 裡 `amba_pl` 底下是 Zybo 範例設計的 PL 周邊（HDMI、VDMA、MIPI CSI 等），
EGO-XZ7 的 bitstream 裡沒有這些，kernel 照著去存取會出錯。`make_ego_dtb.py` 做了三件事：

1. 刪掉整個 `amba_pl`。
2. 新增 `amba_pl/btn_led_ctrl@43c00000`：

   ```dts
   btn_led_ctrl@43c00000 {
       compatible = "generic-uio";
       reg = <0x43c00000 0x10000>;
       interrupt-parent = <&intc>;   /* GIC */
       interrupts = <0 29 4>;        /* SPI 29 = IRQ ID 61 - 32，4 = level high */
       clocks = <&clkc 15>;          /* fclk0 */
   };
   ```

   kernel 的 bootargs 有 `uio_pdrv_genirq.of_id=generic-uio`，所以這個節點會變成 `/dev/uio0`。
3. `model` 改成 `EGO-XZ7 (Zynq XC7Z020)`，開機後用 `/proc/device-tree/model` 確認用的是哪一份 dtb。

PS 端的節點（UART、SD、GEM、GIC、時脈）兩塊板子相同，沒有改。

## U-Boot console：選 kernel、選 device tree

U-Boot 開機時會從 SD 卡匯入 [`uEnv.txt`](sd/uEnv.txt)，裡面定義了 3 種開機方式：

| 指令 | kernel + rootfs | device tree |
|---|---|---|
| `run boot_ego` | `image.ub`（kernel@0 + ramdisk@0） | `ego.dtb` |
| `run boot_zimage` | `zImage`（rootfs 是 initramfs） | `ego.dtb` |
| `run boot_zybo` | `image.ub` | `image.ub` 裡的 Zybo dtb |

倒數 4 秒內沒按鍵會自動跑 `uenvcmd=run boot_ego`。`boot_zybo` 用的是 Zybo 原本的 dtb，PL 周邊對不上，只當對照。

也可以在 console 自己打：

```
Zynq> fatls mmc 0
Zynq> fatload mmc 0 0x10000000 image.ub
Zynq> fatload mmc 0 0x1F000000 ego.dtb
Zynq> bootm 0x10000000:kernel@0 0x10000000:ramdisk@0 0x1F000000
```

`bootm` 的三個參數分別是 kernel、ramdisk、device tree 的位址。`image.ub` 是 FIT 格式，
`位址:kernel@0` 指定裡面的哪一個 image；第三個參數給 `ego.dtb` 的位址，就會取代 FIT 裡面附的 Zybo dtb。
`zImage` 用 `bootz <kernel 位址> - <dtb 位址>`，中間的 `-` 表示沒有另外的 ramdisk。

## 建置

需要 Vivado / SDK 2018.2、Python 3（`pip install fdt pyserial`）。

```
cd vivado
vivado -mode batch -source build_hw.tcl    # block design → bitstream → boot/hw/system_wrapper.hdf
cd ../boot
get_prebuilt.bat                           # 下載 Digilent BSP（122 MB），取出 u-boot.elf、image.ub、zImage、system.dtb
build_boot.bat                             # FSBL（xsct）→ ego.dtb → BOOT.BIN（bootgen），全部放到 ../sd/
```

timing：WNS 13.060 ns、WHS 0.055 ns。

SD 卡（以 119 GB 的卡為例，Windows 的格式化介面在 32 GB 以上沒有 FAT32 可選，要用 diskpart；
`clean` 會清掉整張卡，先 `list disk` 確認編號）：

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

1. SD 卡插 J15，SW8 撥成 SD 開機（User Guide 表 2，ON = 0、OFF = 1）：

   | SW8 | 1 | 2 | 3 | 4 | 5 | 6 |
   |---|---|---|---|---|---|---|
   | SD 開機 | ON | ON | OFF | OFF | ON | ON |
   | JTAG 開機（HW2） | ON | ON | ON | ON | ON | ON |

2. J1 接 USB，開序列埠（FT2232HQ 的第二個 channel，COM 編號看裝置管理員，以下以 COM4 為例），115200 8N1：
   `python -m serial.tools.miniterm COM4 115200`
3. 開電源，倒數時按任意鍵進 U-Boot console，打 `run boot_ego`。
4. rootfs 會自動以 root 登入，出現 `root@Zybo-Z7-20:~#`。

[`tools/`](tools/) 裡另外有 3 個測試用的腳本：

| 檔案 | 用途 |
|---|---|
| [`boot_test.py`](tools/boot_test.py) | 開序列埠，攔下 autoboot，在 U-Boot console 打指令選 kernel / dtb，進 Linux 後跑檢查指令，輸出存成 `boot_log.txt` |
| [`jtag_uboot.tcl`](tools/jtag_uboot.tcl) | 用 JTAG 載入 ps7_init、bitstream、U-Boot，U-Boot 再從 SD 卡讀 kernel。改硬體後不用先更新 SD 卡就能測 |
| [`update_bootbin.py`](tools/update_bootbin.py) | 不拔 SD 卡更新 `BOOT.BIN`：JTAG 把新的 `BOOT.BIN` 放進 DDR，再用 U-Boot 的 `fatwrite` 寫進 SD 卡 |

## 驗證結果

SD 卡冷開機（SW8 = SD，電源關再開，沒有接 JTAG）的完整序列埠紀錄在 [`log/boot_sd.txt`](log/boot_sd.txt)。

U-Boot：

```
U-Boot 2017.01 (Apr 17 2019 - 12:55:19 +0300)
DRAM:  ECC disabled 1 GiB
MMC:   sdhci@e0100000: 0 (SD)
SF: Detected n25q256a with page size 256 Bytes, erase size 4 KiB, total 32 MiB
reading uEnv.txt
Hit any key to stop autoboot:  4  0
Zynq> run boot_ego
## Loading kernel from FIT Image at 10000000 ...
## Loading ramdisk from FIT Image at 10000000 ...
   Loading Device Tree to 04eda000, end 04edfc0a ... OK
Starting kernel ...
```

Linux：

```
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

- kernel 和 rootfs 都正常起來，兩顆 Cortex-A9 都有啟動（`smp: Brought up 1 node, 2 CPUs`）。
- device tree 用的是 `ego.dtb`；DDR 1 GB 都抓到。
- rootfs 是 ramdisk，SD 卡的 FAT32 分割區自動掛在 `/run/media/mmcblk0p1`。
- PL 的 `btn_led_ctrl` 變成 `/dev/uio0`，中斷掛在 GIC 61，level 觸發，跟 HW2 一樣。

U-Boot 印 `PHY auto negotiation ... TIMEOUT` 是因為沒接網路線；U-Boot 的 banner 和 Linux 的 hostname
還是 Zybo，因為這兩個寫死在預編檔裡。

## 目錄

```
HW3/
├── vivado/
│   ├── create_bd_linux.tcl   block design（HW2 版本二 + SD0 / UART1 / ENET0 / QSPI）
│   └── build_hw.tcl          合成、實作、匯出 HDF
├── boot/
│   ├── get_prebuilt.bat      下載 Digilent 預編檔到 prebuilt/
│   ├── fsbl.tcl              產生 FSBL
│   ├── make_ego_dtb.py       Zybo dtb → ego.dtb
│   ├── ego.dts               ego.dtb 的文字版
│   ├── boot.bif              BOOT.BIN 的組成
│   └── build_boot.bat        上面三步一次跑完，輸出到 sd/
├── sd/                       SD 卡要放的檔案（大檔案不進 git）
├── tools/                    上板測試腳本
└── log/boot_sd.txt           SD 卡冷開機的序列埠紀錄
```
