# HW2：Zynq-7020 中斷與 LED/Push Button 驅動

平台：EGO-XZ7（Zynq-7000, XC7Z020），開發環境 Vivado 2018.2 + Xilinx SDK 2018.2。

## 題目

1. 從 Zynq-7020 的手冊找出跟 BSP（Board Support Package）、ISR 相關的章節。
2. 找出中斷控制器相關的暫存器：1. IRQ #（port）、2. pending register（port status）、
   3. mask register（port enable）。
3. 按下 push button 產生中斷，按鈕訊號經過 FPGA（PL）再進中斷控制器；用找到的暫存器寫
   Driver + ISR，讓 LED 有客製化反應。

## 功能規格

- 輸入：S6（BTNC），PL pin P16，按下 = 1
- 輸出：LED0，PL pin T22
- 行為：
  1. 開機預設 LED0 恆亮。
  2. 按一下 S6 切換成呼吸燈，週期 2 秒（1 秒漸亮、1 秒漸暗）。
  3. 再按一下切回恆亮，之後每按一次就在兩個狀態間切換。

按鍵偵測用中斷，不用主迴圈 polling；ISR 與中斷設定都直接讀寫暫存器。

## Demo

[`demo/`](demo/) 資料夾裡雙擊 `demo.bat`，會依序燒 bitstream、初始化 PS、下載 ELF 並執行，
詳細步驟見 [`demo/README.md`](demo/README.md)。

## Vivado Block Design

![HW2 Vivado Block Design](Upload/image/block_design.png)
[看大圖](https://raw.githubusercontent.com/shj-F115112128/SOC_Practice/master/HW2/Upload/image/block_design.png)
（重建腳本：[`vivado/create_bd.tcl`](vivado/create_bd.tcl)）

| 方塊 | 用途 |
|---|---|
| `ps7` | Zynq PS。`M_AXI_GP0` 讓 CPU 存取 PL 的 AXI GPIO；`IRQ_F2P[0:0]` 收 PL 送來的中斷；`FCLK_CLK0` / `FCLK_RESET0_N` 提供 PL 時脈與 reset |
| `ps7_axi_periph` | AXI Interconnect，1 個 master 分給 2 個 slave（`M00_AXI` 接 `axi_gpio_mode`、`M01_AXI` 接 `axi_gpio_btn`） |
| `rst_ps7_50M` | Processor System Reset，把 PS 的非同步 reset 同步到 50 MHz 時脈再分給 PL |
| `axi_gpio_btn` | 1 bit 輸入，開 interrupt。`gpio_io_i` 接防彈跳後的按鈕，`ip2intc_irpt` 接 `IRQ_F2P` |
| `axi_gpio_mode` | 1 bit 輸出，`gpio_io_o` 接 `pwm_breath` 的 `mode` |
| `btn_debounce_0` | 自寫 RTL（[`btn_debounce.v`](vivado/rtl/btn_debounce.v)），同步 + 防彈跳 |
| `pwm_breath_0` | 自寫 RTL（[`pwm_breath.v`](vivado/rtl/pwm_breath.v)），依 `mode` 輸出恆亮或呼吸 PWM 到 `led0` |

`btn` 是單一訊號的 port，不是 GPIO 介面 port：按鈕要先經過 `btn_debounce` 才接到 AXI GPIO，
所以不能直接把 AXI GPIO 的 GPIO 介面 Make External。

`rst_ps7_50M` 不能拿掉。`FCLK_RESET0_N` 由軟體放開，跟 `FCLK_CLK0` 不同步，直接接到各 reset 腳的話
`validate_bd_design` 會報 8 個 `CRITICAL WARNING [BD 41-1348] ... is connected to asynchronous reset source`。

## 文件手冊

| 手冊 | 用途 |
|---|---|
| UG585 Zynq-7000 Technical Reference Manual（v1.14, 2023-06-30），[線上版](https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM) | GIC 中斷控制器、IRQ ID 表、PS 暫存器位址 |
| PG144 AXI GPIO LogiCORE IP Product Guide | AXI GPIO 的暫存器（`GPIO_DATA`、`GIER`、`IPISR`、`IPIER`） |
| EGO-XZ7 User Guide V1.2 | 板子的 LED / 按鈕接到哪個 FPGA pin |

暫存器位址要查 UG585；EGO-XZ7 User Guide 是板子的硬體手冊（排針、原理圖、pin 對應），不含暫存器位址。
下文頁碼都是 UG585 的 PDF 頁碼，截圖放在 [`Upload/image/ug585/`](Upload/image/ug585/)。

## 中斷相關暫存器

按鈕中斷要經過 AXI GPIO、GIC、CPU 三層，每一層都要開，中斷才會進到 ISR：

```
S6 → btn_debounce → axi_gpio_btn (IPISR/IPIER/GIER) → IRQ_F2P[0]
   → GIC (ID 61: ICDISPR1/ICDISER1 bit29) → CPU (CPSR.I) → S6IntrHandler
```

| 項目 | PL：`axi_gpio_btn`（基底 `0x41210000`，PG144） | GIC（UG585） |
|---|---|---|
| 1. IRQ #：port | GPIO 通道 1 bit0 → `ip2intc_irpt` → `IRQ_F2P[0]` | **IRQ ID 61**，p.238 Table 7-4 |
| 2. pending：port status | `IPISR` bit0（`0x41210120`） | `ICDISPR1` **bit29**（`0xF8F01204`），p.1523 |
| 3. mask：port enable | `IPIER` bit0（`0x41210128`）+ `GIER` bit31（`0x4121011C`） | `ICDISER1` **bit29**（`0xF8F01104`），p.1520 |

GIC 的 `ICD*1` 這組暫存器管 ID 32～63，所以 ID 61 是 61 - 32 = bit29。

### 1. IRQ #：port

![UG585 p.238 Table 7-4](Upload/image/ug585/p238_table7-4_spi_irq_id.png)

UG585 p.238 Table 7-4 最下面 PL [2:0] 那一列：`IRQF2P[2:0]` 對應 IRQ ID 63:61，
所以從 `IRQ_F2P[0]` 進來的就是 ID 61，Status Bits 是 `spi_status_0[31:29]`，同樣落在 bit29。
Vivado 產生的 `xparameters.h` 裡 `XPAR_FABRIC_AXI_GPIO_BTN_IP2INTC_IRPT_INTR` 也是 61U。

### 2. Pending register：port status

PL 端是 `axi_gpio_btn` 的 `IPISR`（offset `0x120`），bit0 = 通道 1 的輸入有變化。
它是 toggle-on-write，要對讀到 1 的 bit 寫 1 才會清掉；對 0 的 bit 寫 1 反而會變成 pending。

GIC 端是 `ICDISPR1`：

![UG585 p.1523 ICDISPR](Upload/image/ug585/p1523_gic_ICDISPR1.png)

> UG585 p.1523。`ICDISPR0`～`ICDISPR2` 分別管 ID 0～31、32～63、64～95，這裡用 `ICDISPR1` bit29。
> 讀到 1 表示 pending；清除要寫 `ICDICPR1`（`0xF8F01284`），程式在打開中斷前會先寫一次清掉殘留。

### 3. Mask register：port enable

PL 端要開兩個：

| 暫存器 | offset | 寫入值 | 說明 |
|---|---|---|---|
| `IPIER` | `0x128` | bit0 = 1 | 通道 1 的中斷 enable |
| `GIER` | `0x11C` | bit31 = 1 | 整顆 IP 的中斷總開關，沒開的話 `ip2intc_irpt` 永遠是 0 |

GIC 端是 `ICDISER1`：

![UG585 p.1520 ICDISER1](Upload/image/ug585/p1520_gic_ICDISER1.png)

> UG585 p.1520，`0xF8F01104`，寫 1 開啟對應 ID，寫 0 沒作用（關閉要寫 `ICDICER1`，`0xF8F01184`）。
> 上板用 debugger 讀到 `ICDISER1 = 0x20000000`，只有 bit29 是 1。

最後 CPU 的 CPSR.I 要清成 0（`Xil_ExceptionEnable()`）才會接 IRQ。

### 觸發方式

![UG585 p.240 Figure 7-4](Upload/image/ug585/p240_fig7-4_ICDICFR.png)

每個 SPI 在 `ICDICFR` 佔 2 bit，`01` 是 high level、`11` 是 rising edge。
ID 61 在 `ICDICFR3`（ID 48～63，`0xF8F01C0C`）的 bits[27:26]，(61 - 48) * 2 = 26。
`ip2intc_irpt` 在 `IPISR` 清掉之前會一直是 High，所以設成 `01`；上板讀到 `ICDICFR3 = 0x55555555`。

因為是 level 觸發，ISR 裡一定要清 `IPISR`，不然離開 ISR 後 GIC 又看到 pending，會一直重進 ISR。

另外 AXI GPIO 是輸入有變化就中斷，按下和放開各會進一次 ISR。ISR 清完 `IPISR` 後讀 `GPIO_DATA`，
是 1（按下）才切換模式。彈跳已經在 PL 的 `btn_debounce` 濾掉，所以一次按壓只會有這兩次中斷。

## 對應到 `main.c`

[`sdk/src/main.c`](sdk/src/main.c) 的中斷設定都是用 `Xil_In32` / `Xil_Out32` 直接讀寫暫存器：

| 函式 | 暫存器操作 |
|---|---|
| `SetupModeGpio()` | `axi_gpio_mode` 的 `GPIO_TRI` = 0（輸出）、`GPIO_DATA` = 0（恆亮） |
| `SetupBtnGpio()` | 設成輸入、清掉 `IPISR` 殘留，再開 `IPIER` bit0 和 `GIER` bit31 |
| `SetupInterruptSystem()` | ID 61 接到 `S6IntrHandler`，`ICDICFR3` 設 level 觸發，清 `ICDICPR1` 後開 `ICDISER1` bit29，最後 `Xil_ExceptionEnable()` |
| `S6IntrHandler()` | 讀 `IPISR` bit0、寫 1 清除，再讀 `GPIO_DATA`，是 1 才切換 `mode` |
| `main()` | 初始化完就空轉，LED 切換都由中斷處理 |

BSP 只留 CPU 收到 IRQ 後的分派：`XScuGic_InterruptHandler` 讀 `ICCIAR` 拿 ID、呼叫 ISR、寫 `ICCEOIR` 結束。

## PL 端 RTL

| 檔案 | 內容 | 驗證 |
|---|---|---|
| [`btn_debounce.v`](vivado/rtl/btn_debounce.v) | 2 級同步器 + 防彈跳，輸入要連續 20ms（50 MHz 下 1,000,000 clk）不變才採用 | [`tb_btn_debounce.v`](vivado/rtl/tb_btn_debounce.v)：按下、放開各彈跳 5 次，輸出只變 2 次 |
| [`pwm_breath.v`](vivado/rtl/pwm_breath.v) | `mode`=0 恆亮；`mode`=1 為 1 kHz PWM、100 階三角波，每階 10ms，來回 200 階 = 2 秒 | [`tb_pwm_breath.v`](vivado/rtl/tb_pwm_breath.v)：縮小參數逐階檢查亮燈 clk 數 |

兩個 testbench 在 xsim 都 PASS。

## 板上按鈕與 LED（EGO-XZ7 User Guide V1.2, §2.9）

| 訊號 | 接到 | FPGA Pin |
|---|---|---|
| S6 (BTNC) | PL | P16 |
| LED0 | PL | T22 |

腳位約束在 [`vivado/constraints/hw2.xdc`](vivado/constraints/hw2.xdc)（LVCMOS33）。

## 建置

```
cd vivado
vivado -mode batch -source create_bd.tcl -tclargs ./build/plbtn   # 建專案 + block design
# 之後在 Vivado：Generate Bitstream → Export Hardware（含 bitstream）
# SDK / hsi：用匯出的 HDF 產生 standalone BSP，再編譯 sdk/src/main.c
```

`vivado/build/` 有 gitignore，上板用的檔案另外複製一份在 [`demo/`](demo/)。
改完 `main.c` 後雙擊 `demo/build_elf.bat` 就能重新編譯。

## 驗證結果

- RTL：`tb_btn_debounce`、`tb_pwm_breath` xsim PASS。
- Vivado：timing met、0 critical warning，`xparameters.h` 的中斷 ID 是 61，跟 UG585 一致。
- 上板：燒錄、執行成功，debugger 讀到 CPU 停在 `main()` 迴圈、`ICDISER1 = 0x20000000`、
  `ICDICFR3` bits[27:26] = `01`、CPSR.I = 0。
