# HW4：btn_led_ctrl 的 Linux 驅動程式

平台：EGO-XZ7（Zynq-7000, XC7Z020），Linux 4.9.0-xilinx-v2017.4（沿用 HW3 的 SD 卡開機環境）。

## 題目

將 HW2 版本二的 RTL IP（`btn_led_ctrl`）掛載到 Linux，撰寫驅動程式模組（driver module）與使用者程式（user program）。

1. 驅動程式 `btnled.c` → `btnled.ko`；應用程式 `btnled_app.c` → 執行檔 `btnled_app`
2. Makefile
3. `insmod` → `lsmod` → `ls /dev/` → `./btnled_app`；`rmmod` → `lsmod` → `./btnled_app`（執行失敗）
4. 驅動程式內部說明：主 / 次裝置號（major / minor number）、模組名稱、字元裝置註冊、
   檔案操作（file operations：read / write / ioctl / lseek）、中斷服務常式（ISR）

## 架構

```
S6 ─→ btn_led_ctrl（PL，0x43C00000）─ irq ─→ IRQ_F2P[0] ─→ GIC ID 61 ─→ btnled_isr()
                ↑ AXI4-Lite                                              │ 讀取 INT_STATUS、寫 1 清除
                │                                                         ↓
         readl / writel ←─ btnled.ko ── 事件佇列（spinlock）──→ 喚醒 ─→ read() 回傳事件
                                ↑
          /dev/btnled（major 245, minor 0）←─ open / read / write / lseek / ioctl ─ btnled_app
```

IP 的暫存器與手勢功能同 HW2 版本二（[HW2/README.md](../HW2/README.md)）：單擊、雙擊、長按、按下、放開五種中斷，
OR 成一條準位觸發（level-triggered）的 `irq`。HW2 的 standalone 程式直接存取實體位址並自行設定 GIC；
在 Linux 下改由驅動程式負責，使用者程式只能透過裝置檔案 `/dev/btnled` 存取。

## 檔案

| 檔案 | 內容 |
|---|---|
| [`src/btnled.c`](src/btnled.c) | 驅動程式（platform driver + 字元裝置 + ISR） |
| [`src/btnled.h`](src/btnled.h) | 驅動程式與應用程式共用：暫存器位移量（offset）、事件格式、ioctl 命令 |
| [`src/btnled_app.c`](src/btnled_app.c) | 應用程式 |
| [`src/Makefile`](src/Makefile) | `make` 同時編譯 `btnled.ko` 與 `btnled_app` |
| `src/btnled.ko`、`src/btnled_app` | 編譯完成的驅動程式模組與執行檔 |
| [`dts/make_hw4_dtb.py`](dts/make_hw4_dtb.py) | 由 HW3 的 `ego.dtb` 產生 `hw4.dtb`，原始碼格式見 [`dts/hw4.dts`](dts/hw4.dts) |
| [`sd/hw4.dtb`](sd/hw4.dtb)、[`sd/uEnv.txt`](sd/uEnv.txt) | 放到 SD 卡根目錄，取代 HW3 的開機設定 |
| [`kernel/build_kernel.sh`](kernel/build_kernel.sh) | 在 WSL 下載 kernel 原始碼、套用組態、編譯 kernel |
| [`kernel/config-4.9.0-xilinx-v2017.4`](kernel/config-4.9.0-xilinx-v2017.4) | 板上 kernel 的組態檔，由 [`kernel/extract_config.py`](kernel/extract_config.py) 從 zImage 取出 |
| [`tools/serial_send.py`](tools/serial_send.py) | 透過 COM4 序列埠將檔案傳送到開發板 |
| [`tools/hw4_test.py`](tools/hw4_test.py) | 上板驗證腳本，輸出存於 [`log/hw4_test.txt`](log/hw4_test.txt) |

## Device tree

### 為什麼用 device tree

ARM 平台的周邊不像 PCI 可以自動偵測，kernel 必須事先知道「哪個位址有什麼硬體、中斷接到哪裡」。device tree
就是描述這些硬體資訊的資料結構：原始碼為 `.dts`（device tree source），編譯成二進位的 `.dtb`（device tree blob），
開機時由 bootloader 交給 kernel。驅動程式只寫「怎麼操作這種 IP」，「IP 在哪裡」由 device tree 提供。

與不使用 device tree、把硬體資訊寫死在驅動程式內的做法比較：

| 項目 | 不使用 device tree | 使用 device tree（本作業） |
|---|---|---|
| 暫存器位址 | 程式內寫死 `ioremap(0x43C00000, ...)` | 由 `reg` 屬性提供，`platform_get_resource()` 取得 |
| IRQ 編號 | 程式內寫死 Linux IRQ 編號（如 48），或用 module 參數傳入 | 由 `interrupts` 屬性提供，kernel 轉換成 Linux IRQ 編號，`platform_get_irq()` 取得 |
| 驅動程式何時開始運作 | `insmod` 時 `module_init` 直接存取硬體 | `insmod` 時註冊 platform driver，kernel 比對 `compatible` 成功才呼叫 probe |
| IP 位址或中斷改變時 | 修改驅動程式並重新編譯 | 只改 device tree，驅動程式不變 |
| 同一驅動程式管理多個相同 IP | 每個位址都要寫進程式 | 多個節點使用相同 `compatible`，每個各 probe 一次（本作業只有一個 IP，驅動程式只配置 1 個次裝置號） |

在 Zynq（ARM GIC）上，Linux IRQ 編號（virq）不等於硬體中斷編號：GIC ID 61 要先經過 kernel 的 IRQ domain 建立對應，
才會得到可用的 Linux IRQ 編號（本板為 48），而這個對應正是 kernel 解析 device tree `interrupts` 屬性時建立的。
因此不使用 device tree 時，ISR 的 IRQ 編號只能從其他已存在的節點借用、或寫死一個開機後才知道的數字。

### 節點內容

`hw4.dtb` 由 HW3 的 `ego.dtb` 修改而來，PS 端節點（UART、SD、GEM、GIC、時脈）不變，PL 端只有一個節點
（[`dts/hw4.dts`](dts/hw4.dts) 第 496～508 行）：

```
amba_pl {                                     // PL 周邊的匯流排節點
    #address-cells = <0x1>;                   // 子節點 reg 的位址佔 1 個 32-bit cell
    #size-cells = <0x1>;                      // 子節點 reg 的長度佔 1 個 cell
    compatible = "simple-bus";                // kernel 為底下每個子節點建立 platform device
    ranges;                                   // 子節點位址 = CPU 實體位址，不做轉換

    btn_led_ctrl@43c00000 {                   // 節點名稱 @ 單元位址（unit address）
        compatible = "nkust,btn-led-ctrl-1.0";
        reg = <0x43C00000 0x10000>;
        interrupt-parent = <0x4>;
        interrupts = <0x0 0x1D 0x4>;
        clocks = <0x1 0xF>;
    };
};
```

| 屬性 | 值 | 意義 | 來源 / 對應 |
|---|---|---|---|
| `compatible` | `"nkust,btn-led-ctrl-1.0"` | 「廠商,裝置名稱-版本」格式的識別字串，kernel 以此比對驅動程式 | 必須與 `btnled.c` 的 `of_match_table` 字串完全相同 |
| `reg` | `<0x43C00000 0x10000>` | 暫存器區段：起始位址 `0x43C00000`、長度 64 KB | Vivado Address Editor 中 `btn_led_ctrl_0/S00_AXI` 的位址與範圍 |
| `interrupt-parent` | `<0x4>` | 中斷送往哪個中斷控制器，`0x4` 是 phandle（節點的參照編號） | GIC 節點 `interrupt-controller@f8f01000` 的 `phandle = <0x4>` |
| `interrupts` | `<0x0 0x1D 0x4>` | GIC 的三個 cell：類型、編號、觸發方式 | 見下表 |
| `clocks` | `<0x1 0xF>` | 時脈來源：phandle `0x1` 的索引 15 輸出（從 0 起算） | `clkc@100`（`phandle = <0x1>`）的 `clock-output-names` 第 15 項為 `fclk0`（50 MHz），即 IP 的 `s00_axi_aclk` |

`interrupts` 三個 cell 的意義（GIC binding）：

| cell | 值 | 意義 |
|---|---|---|
| 第 1 個 | `0` | 中斷類型：0 = SPI（shared peripheral interrupt，周邊共用中斷），1 = PPI |
| 第 2 個 | `0x1D` = 29 | SPI 編號；GIC 中斷 ID = SPI 編號 + 32 = **61**，即 `IRQ_F2P[0]`（UG585 Table 7-4） |
| 第 3 個 | `4` | 觸發方式：4 = 高準位觸發（`IRQ_TYPE_LEVEL_HIGH`），與 IP 的 `irq` 行為一致 |

### 從 SD 卡到 probe 的流程

```
U-Boot  fatload mmc 0 0x1F000000 hw4.dtb
        bootm ... 0x1F000000             將 dtb 位址交給 kernel（ARM 慣例放在 r2 暫存器）
  ↓
kernel  展開 dtb → /proc/device-tree/
        amba_pl 是 simple-bus → 建立 platform device「43c00000.btn_led_ctrl」
        解析 interrupts <0 29 4> → GIC domain 建立對應：GIC ID 61 → Linux IRQ 48
        此時沒有驅動程式的 of_match_table 含 "nkust,btn-led-ctrl-1.0"，裝置維持未綁定
  ↓
insmod btnled.ko
        platform_driver_register() → platform bus 逐一比對 compatible → 相符
        → btnled_probe(pdev)
             platform_get_resource(pdev, IORESOURCE_MEM, 0)  → 0x43C00000～0x43C0FFFF（來自 reg）
             platform_get_irq(pdev, 0)                        → 48（來自 interrupts）
             devm_clk_get()                                   → fclk0（來自 clocks）
```

`btnled.c` 中對應的程式：

```c
static const struct of_device_id btnled_of_match[] = {
	{ .compatible = "nkust,btn-led-ctrl-1.0" },     // 與 device tree 節點相同
	{ }
};
MODULE_DEVICE_TABLE(of, btnled_of_match);

static struct platform_driver btnled_driver = {
	.probe  = btnled_probe,
	.remove = btnled_remove,
	.driver = {
		.name           = "btnled",
		.of_match_table = btnled_of_match,
	},
};
```

### 為什麼要修改 compatible

HW3 的 `ego.dtb` 將此節點設為 `compatible = "generic-uio"`，且 kernel 開機參數有 `uio_pdrv_genirq.of_id=generic-uio`。
`uio_pdrv_genirq` 已編入 kernel，開機時就比對成功並綁定節點、取得 IRQ 48，產生 `/dev/uio0`。一個裝置同一時間只能
由一個驅動程式綁定，IRQ 48 也已被佔用，`btnled.ko` 因此無法 probe。`hw4.dtb` 只將 `compatible` 改為
`nkust,btn-led-ctrl-1.0`，其餘屬性不變，讓節點保留給 `btnled.ko`。

`hw4.dtb` 由 [`dts/make_hw4_dtb.py`](dts/make_hw4_dtb.py) 產生（Python `fdt` 套件讀取 `ego.dtb`、修改屬性、寫回），
與 `ego.dtb` 逐行比較只有 `compatible` 這一行不同：

```
python make_hw4_dtb.py ../../HW3/sd/ego.dtb ../sd/hw4.dtb
```

### 上板確認

| 指令 | 結果 | 說明 |
|---|---|---|
| `cat /proc/device-tree/amba_pl/btn_led_ctrl@43c00000/compatible` | `nkust,btn-led-ctrl-1.0` | kernel 讀到的是 `hw4.dtb` |
| `ls /dev/uio*` | 不存在 | generic-uio 沒有綁定此節點 |
| `insmod btnled.ko` 後的 `dmesg` | `btnled 43c00000.btn_led_ctrl: ... regs 0x43c00000, irq 48` | probe 成功，位址與 IRQ 都來自 device tree |
| `grep btnled /proc/interrupts` | `48: ... GIC-0  61 Level  btnled` | Linux IRQ 48 對應 GIC ID 61、準位觸發，與 `interrupts` 屬性一致 |

## 驅動程式內部說明

### 模組名稱、主 / 次裝置號

| 項目 | 值 | 查看方式 |
|---|---|---|
| 模組名稱 | `btnled` | `lsmod`；`MODULE_*` 巨集位於 `btnled.c` 結尾 |
| 裝置檔案 | `/dev/btnled` | `ls -l /dev/btnled` |
| 主裝置號（major） | 動態配置（本次為 245）；`insmod btnled.ko major=240` 可指定 | `/proc/devices`、`ls -l` 第 5 欄 |
| 次裝置號（minor） | 0（僅一個裝置） | `ls -l` 第 6 欄 |

`dev_t` 是由主、次裝置號組成的 32-bit 編號（`MKDEV(major, minor)`）。`/dev/btnled` 這個 inode 不含程式碼，
只記錄 `c 245 0`；`open()` 時 kernel 依此編號找到驅動程式註冊的 `cdev`，再呼叫其 `file_operations`。

### 字元裝置註冊

依執行順序：

| 步驟 | 函式 | 位置 | 作用 |
|---|---|---|---|
| 1. 配置裝置號 | `alloc_chrdev_region(&btnled_devt, 0, 1, "btnled")` | `btnled_init()`（insmod） | 向 kernel 取得一個主裝置號與 1 個次裝置號；指定主裝置號時改用 `register_chrdev_region()` |
| 2. 建立 class | `class_create(THIS_MODULE, "btnled")` | `btnled_init()` | 產生 `/sys/class/btnled/` |
| 3. 註冊 platform driver | `platform_driver_register()` | `btnled_init()` | 比對 device tree，找到符合的節點即呼叫 probe |
| 4. 映射暫存器 | `devm_ioremap_resource()` | `btnled_probe()` | 將實體位址 `0x43C00000` 映射到 kernel 虛擬位址，之後以 `readl` / `writel` 存取 |
| 5. 註冊 ISR | `devm_request_irq(irq, btnled_isr, ...)` | `btnled_probe()` | 註冊於 GIC ID 61（Linux IRQ 編號 48） |
| 6. 註冊 cdev | `cdev_init()` + `cdev_add(&cdev, btnled_devt, 1)` | `btnled_probe()` | 將 `file_operations` 與 `dev_t` 關聯 |
| 7. 建立裝置檔案 | `device_create(btnled_class, ..., "btnled")` | `btnled_probe()` | 送出 uevent，由 udev 建立 `/dev/btnled` |
| 8. 致能 IP 中斷 | `writel(0x1F, INT_ENABLE)` | `btnled_probe()` | 前述步驟完成後才致能 |

`rmmod` 時順序相反：`btnled_remove()` 清除 `INT_ENABLE`，呼叫 `device_destroy()`、`cdev_del()`；`btnled_exit()`
呼叫 `platform_driver_unregister()`、`class_destroy()`、`unregister_chrdev_region()`。ISR 與 ioremap 以 `devm_` 系列
函式取得，remove 之後由 kernel 自動釋放。

### 檔案操作（file operations）

| 系統呼叫 | 驅動程式函式 | 行為 |
|---|---|---|
| `open()` | `btnled_open()` | 由 `inode->i_cdev` 取得裝置資料，存入 `file->private_data` |
| `read()` | `btnled_read()` | 從事件佇列取出 `struct btnled_event`（一次最多 16 筆）；佇列為空時在等待佇列（wait queue）中睡眠，由 ISR 喚醒；以 `O_NONBLOCK` 開啟時回傳 `-EAGAIN` |
| `write()` | `btnled_write()` | 將 32-bit 資料寫入暫存器，目標由檔案位置決定，寫入後位置加 4（相當於向 IP 傳送，Tx） |
| `lseek()` | `btnled_llseek()` | 將檔案位置設為暫存器位移量，範圍 `0x00`～`0x40` |
| `ioctl()` | `btnled_ioctl()` | `BTNLED_IOC_RD_REG` / `WR_REG` 讀寫單一暫存器、`FLUSH` 清空佇列、`STATS` 查詢中斷次數與主 / 次裝置號 |
| `poll()` | `btnled_poll()` | 佇列有事件時回傳 `POLLIN`，可搭配 `select()` / `poll()` 使用 |
| `close()` | `btnled_release()` | 無資源需釋放 |

`read()` 用於接收事件，因此讀取暫存器改用 ioctl。使用者空間（user space）與 kernel 之間的資料一律透過
`copy_to_user()` / `copy_from_user()` 複製，不直接使用使用者傳入的指標。

### 中斷服務常式（ISR）

```c
st = readl(INT_STATUS) & readl(INT_ENABLE);
if (!st) return IRQ_NONE;            // 非本 IP 發出的中斷
writel(st, INT_STATUS);              // 寫 1 清除（W1C）pending 位元
讀取 EVENT_CNT、HOLD_MS、DATA_OUT → 放入佇列 → wake_up_interruptible()
return IRQ_HANDLED;
```

此中斷為準位觸發，IP 的 `irq` 在 `INT_STATUS` 清除前持續為高準位；若未清除，離開 ISR 後會立即再次進入。
GIC 的設定（優先權、觸發方式、致能）由 kernel 依 device tree 的 `interrupts` 屬性完成，驅動程式不需存取 GIC 暫存器
（HW2 的 standalone 版本須自行呼叫 `XScuGic_*`）。

### 臨界區段（critical section）

事件佇列（32 筆環狀緩衝區，`head` / `tail`）同時由 ISR（寫入）與 `read()` / `ioctl()`（取出、清空）存取，
以自旋鎖（`spinlock_t lock`）保護：

- ISR 中使用 `spin_lock()`：此時本地中斷已停用。
- `read()`、`ioctl()` 使用 `spin_lock_irqsave()`：同時停用本地中斷，避免持有鎖期間 ISR 插入並要求同一把鎖而造成死結（deadlock）。
- 持有自旋鎖期間不可呼叫可能睡眠的函式，因此事件先複製到堆疊上的區域陣列，解鎖後再呼叫 `copy_to_user()`。
- 佇列已滿時捨棄最舊的一筆，`dropped` 計數加 1。

## 應用程式

```
./btnled_app                 等待按鈕事件：單擊切換恆亮 / 呼吸、雙擊切換亮度、長按切換呼吸速度，Ctrl-C 結束
./btnled_app watch <N>       同上，收到 N 筆後結束
./btnled_app info            顯示主 / 次裝置號、統計資料、全部暫存器
./btnled_app mode <0|1>      0 恆亮、1 呼吸
./btnled_app speed <0~3>
./btnled_app bright <0~31>
```

流程：`open("/dev/btnled", O_RDWR)` → `lseek(fd, DATA_IN, SEEK_SET)` + `write()` 寫入 1000 →
迴圈中以 `read()` 等待事件 → 依事件以 `lseek` + `write()` 修改 `CTRL` / `BRIGHT` / `SPEED` → `close()`。
驅動程式未載入時 `/dev/btnled` 不存在，`open()` 回傳 `ENOENT`，程式顯示錯誤訊息後結束（exit 1）。

## 編譯

模組必須以與板上 kernel 相同的原始碼與組態編譯：

- 版本：`vermagic` 字串（`4.9.0-xilinx-v2017.4 SMP preempt mod_unload modversions ARMv7 p2v8`）必須相同，否則 insmod 拒絕載入。
- 符號 CRC：此 kernel 啟用 `CONFIG_MODVERSIONS`，模組引用的每個 kernel 符號（symbol）都附有 CRC，必須與 kernel 一致，
  因此須先完整編譯一次 kernel 以產生 `Module.symvers`。

| 項目 | 來源 |
|---|---|
| kernel 原始碼 | https://github.com/Digilent/linux-digilent ，commit `1496c680c6df2e3911feed13aa9663a851bf30e9`（Digilent Petalinux-Zybo-Z7-20 v2017.4 BSP 的 `project-spec/configs/config` 所指定的版本） |
| 組態檔 | 板上 kernel 啟用 `CONFIG_IKCONFIG`，組態以 gzip 格式內嵌於 zImage，以 `extract_config.py` 取出 |
| 交叉編譯器 | Ubuntu 22.04 的 `gcc-9-arm-linux-gnueabihf`（板上 kernel 以 Linaro GCC 6.2 編譯，該版本已無法下載；4.9 版 kernel 搭配較新的 gcc 會編譯失敗，故固定使用 gcc-9） |

在 WSL（Ubuntu 22.04）中：

```
cd HW4/kernel
bash build_kernel.sh            # 安裝工具、下載原始碼至 ~/hw4/linux、套用組態、make zImage modules（8 核心約 2 分鐘）
cd ../src
PATH=~/hw4/bin:$PATH make       # 產生 btnled.ko 與 btnled_app
```

驗證：自行編譯的 `vmlinux` 中 `__kcrctab`（4565 個 CRC）與 `__kcrctab_gpl`（3918 個）兩個 section，在板上 zImage
解壓縮後的 kernel 中均可找到完全相同的資料，表示所有匯出符號的 CRC 一致；`modinfo btnled.ko` 的 `vermagic`
與板上 `uname -r` 相符。

`btnled_app` 採靜態連結（`-static`）：編譯主機的 glibc（2.35）比板上 rootfs 的版本新，動態連結的執行檔在板上會找不到新版符號。

## 上板驗證

1. 在 SD 卡（HW3 的內容）加入 `hw4.dtb`、`btnled.ko`、`btnled_app`，並以 [`sd/uEnv.txt`](sd/uEnv.txt) 取代 `uEnv.txt`。
   預設開機方式改為 `boot_hw4`：

   ```
   boot_hw4=fatload mmc 0 0x10000000 image.ub && fatload mmc 0 0x1F000000 hw4.dtb && bootm 0x10000000:kernel@0 0x10000000:ramdisk@0 0x1F000000
   ```

   檔案可用讀卡機複製，或在開發板執行 Linux 時，以 [`tools/serial_send.py`](tools/serial_send.py) 透過 COM4 直接寫入 SD 卡
   （板上 busybox 沒有 `base64`，改以 uuencode 編碼、perl `unpack("u")` 解碼，傳送後比對 MD5）：

   ```
   python serial_send.py ../sd/hw4.dtb /run/media/mmcblk0p1/hw4.dtb ../sd/uEnv.txt /run/media/mmcblk0p1/uEnv.txt ^
                         ../src/btnled.ko /run/media/mmcblk0p1/btnled.ko ../src/btnled_app /run/media/mmcblk0p1/btnled_app
   ```

2. 開機（SW8 設為 SD 開機，同 HW3），SD 卡掛載於 `/run/media/mmcblk0p1`：

   ```
   cd /run/media/mmcblk0p1
   insmod btnled.ko
   lsmod
   ls -l /dev/btnled
   ./btnled_app             # 按 S6
   rmmod btnled
   lsmod
   ./btnled_app             # 失敗：open /dev/btnled: No such file or directory
   ```

[`tools/hw4_test.py`](tools/hw4_test.py) 透過 COM4 自動執行上述步驟（`--watch N` 等待 N 筆按鈕事件），完整輸出見
[`log/hw4_test.txt`](log/hw4_test.txt)。

## 驗證結果

insmod：probe 成功，主裝置號 245、次裝置號 0，ISR 註冊於 GIC ID 61。

```
root@Zybo-Z7-20:/run/media/mmcblk0p1# insmod btnled.ko
btnled: loading out-of-tree module taints kernel.
btnled 43c00000.btn_led_ctrl: /dev/btnled major 245 minor 0, regs 0x43c00000, irq 48
btnled: loaded, major 245 minor 0
root@Zybo-Z7-20:/run/media/mmcblk0p1# lsmod
btnled 16384 0 - Live 0xbf08b000 (O)
...
root@Zybo-Z7-20:/run/media/mmcblk0p1# grep btnled /proc/devices
245 btnled
root@Zybo-Z7-20:/run/media/mmcblk0p1# ls -l /dev/btnled
crw-------    1 root     root      245,   0 Apr 17 10:15 /dev/btnled
```

（`taints kernel` 是載入 out-of-tree 模組的正常訊息，`(O)` 即表示 out-of-tree。）

以 ioctl 讀取暫存器、以 lseek + write 寫入暫存器：

```
root@Zybo-Z7-20:/run/media/mmcblk0p1# ./btnled_app info
/dev/btnled  major 245  minor 0  irq 0  queued 0  dropped 0
  0x00 CTRL       = 0x00000000
  0x0C INT_ENABLE = 0x0000001F
  0x24 BRIGHT     = 0x0000001F
  ...
root@Zybo-Z7-20:/run/media/mmcblk0p1# ./btnled_app bright 8; ./btnled_app info | grep BRIGHT
  0x24 BRIGHT     = 0x00000008
```

按下 S6：ISR 收到中斷 → 喚醒 `read()` 取得事件；`DATA_OUT` = `DATA_IN`（1000）+ `EVENT_CNT`；單擊時應用程式以 `write()` 切換模式。

```
root@Zybo-Z7-20:/run/media/mmcblk0p1# ./btnled_app watch 8
DATA_IN = 1000, mode FIXED, speed 3.75 s；按 S6（單擊 / 雙擊 / 長按），Ctrl-C 結束
#1   INT_STATUS 0x01 PRESS         EVENT_CNT 1    DATA_OUT 1001
#2   INT_STATUS 0x02 RELEASE       EVENT_CNT 2    DATA_OUT 1002  hold 159 ms
#3   INT_STATUS 0x04 CLICK         EVENT_CNT 3    DATA_OUT 1003  -> mode BREATH
#4   INT_STATUS 0x01 PRESS         EVENT_CNT 4    DATA_OUT 1004
#5   INT_STATUS 0x02 RELEASE       EVENT_CNT 5    DATA_OUT 1005  hold 170 ms
#6   INT_STATUS 0x04 CLICK         EVENT_CNT 6    DATA_OUT 1006  -> mode FIXED
#7   INT_STATUS 0x01 PRESS         EVENT_CNT 7    DATA_OUT 1007
#8   INT_STATUS 0x02 RELEASE       EVENT_CNT 8    DATA_OUT 1008  hold 153 ms
收到 8 筆事件
root@Zybo-Z7-20:/run/media/mmcblk0p1# grep btnled /proc/interrupts
 48:          8          0     GIC-0  61 Level     btnled
```

rmmod 之後 `/dev/btnled` 消失，應用程式無法開啟裝置：

```
root@Zybo-Z7-20:/run/media/mmcblk0p1# rmmod btnled
btnled: unloaded
root@Zybo-Z7-20:/run/media/mmcblk0p1# ls -l /dev/btnled
ls: /dev/btnled: No such file or directory
root@Zybo-Z7-20:/run/media/mmcblk0p1# ./btnled_app info; echo exit=$?
open /dev/btnled: No such file or directory（driver 載入了嗎？insmod btnled.ko）
exit=1
```

## 目錄

```
HW4/
├─ README.md
├─ src/       btnled.c、btnled.h、btnled_app.c、Makefile、btnled.ko、btnled_app
├─ dts/       make_hw4_dtb.py、hw4.dts
├─ sd/        hw4.dtb、uEnv.txt
├─ kernel/    build_kernel.sh、extract_config.py、config-4.9.0-xilinx-v2017.4
├─ tools/     serial_send.py、hw4_test.py
└─ log/       hw4_test.txt
```
