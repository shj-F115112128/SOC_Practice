# SoC Practice — AMBA AHB/AXI Wrapper FSM + MSC

平台：EGO-XZ7（Zynq-7000），Bonus 的 VHDL 模擬用 Vivado 2018.2。

AMBA SoC 課程作業：

1. 畫出 **AXI 與 AHB 的 Master / Slave wrapper 有限狀態機**，SIP 任選，且需支援多 Master、多 Slave。
2. 畫出 **Message Sequence Chart (MSC)**，參與者為 `CPU (Master)` / `Mem Controller (Slave)` /
   `SIP (Master+Slave，內含 DMA)`，AHB、AXI 版本都要。
3. **Bonus：** 第 1 題 slave wrapper FSM 的 RTL code 與模擬。

## 目錄

| 文件 | 內容 |
|---|---|
| [docs/01-ahb-wrapper-fsm.md](docs/01-ahb-wrapper-fsm.md) | AHB slave wrapper FSM（UART 暫存器）、AHB master wrapper FSM（DMA）、多 Master 用的 arbiter FSM |
| [docs/02-axi-wrapper-fsm.md](docs/02-axi-wrapper-fsm.md) | AXI slave wrapper FSM（write/read channel）、AXI master wrapper FSM（DMA 讀寫）、多 Master/Slave 互連說明 |
| [docs/03-msc-ahb.md](docs/03-msc-ahb.md) | MSC：CPU 設定 UART → UART DMA 把 RX 資料 burst 寫入記憶體 → CPU 讀回狀態與資料，AHB 版 |
| [docs/04-msc-axi.md](docs/04-msc-axi.md) | 同樣情境在 AXI 5 個 channel 上重畫，凸顯 outstanding/並行交易 |
| [docs/05-rtl-simulation.md](docs/05-rtl-simulation.md) | **Bonus：** AHB、AXI slave + master/DMA wrapper、arbiter、記憶體 BFM 全套 VHDL RTL 與自我檢查 testbench，Vivado 2018.2 xsim 下 46/46 全過，系統層級測試完整跑過 MSC 的 A→B→C→D，含真的 IRQ port |

> 圖都用 [draw.io](https://www.diagrams.net/) 畫，原始 `.drawio` 檔放在 [`Upload/`](Upload/)，
> 匯出的 PNG 放在 [`Upload/image/`](Upload/image/) 並直接嵌在各篇 doc 裡；圖說下方都附了
> 「🔍 看大圖」連結，點開是原始解析度的圖檔，也連到可編輯的 `.drawio` 原始檔。

## 一些筆記

SIP 選 UART（內含 DMA），對應白板上的例子跟作業要求的 `SIP(M+S, 內有DMA)`。AHB 那邊的狀態命名
（`IDLE/NONSEQ/SEQ/BUSY/WAIT/ERR1/ERR2`）照課堂教的 Manager/Subordinate FSM 來，套到實際的周邊
wrapper 上。AXI 因為 write/read channel（AW/W/B 跟 AR/R）本來就是獨立的，所以 wrapper FSM 也拆
成兩條，這樣 AXI 版 MSC 才能讓 CPU 讀狀態跟 DMA 的 write burst 重疊 — AHB 是共用匯流排，同一時
間只有一個 master 拿得到 grant，做不到這點。

課程教材：`IHI0033C_amba_ahb_protocol_spec.pdf`、`IHI0022L_amba_axi_protocol_spec.pdf`（上層資
料夾）。UART 暫存器配置比照實驗室 EGO-XZ7（Zynq-7000）板子上常見的 UART 控制器風格。

Bonus 的兩個 slave wrapper 原本是用 Verilog 寫的（邏輯對著同一組測項在 Icarus Verilog 下跑過
28/28 全過），課程規定要交 VHDL，所以照原本邏輯翻成 VHDL（`rtl/*.vhd`），用實驗室的
Vivado 2018.2 xsim 重新跑過一次，一樣全過，時間戳記也跟 Verilog 版幾乎完全對得上。後來把
docs 01/02 畫的 master/DMA wrapper FSM、AHB arbiter 也刻成 RTL，再加一個簡化的記憶體 slave
模型，兜出兩個系統層級 testbench，讓模擬波型能完整跑過 03/04 文件畫的 MSC 四個階段（A 設定→
B 仲裁/DMA 寫入記憶體→C 中斷/讀狀態→D 讀回資料），不只是暫存器存取那一段。細節（包括翻譯
過程跟系統層級兩階段各自踩到的真實 bug）見 [docs/05-rtl-simulation.md](docs/05-rtl-simulation.md)。
