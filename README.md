# SoC Practice — AMBA AHB/AXI Wrapper FSM + MSC

AMBA SoC 課程作業（10/15 繳交）參考解答：

1. 畫出 **AXI 與 AHB 的 Master / Slave wrapper 有限狀態機**，SIP 任選（這裡選用 UART，仿照
   [opencores.org](https://opencores.org/) 上的核心風格），且需支援多 Master、多 Slave。
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
| [docs/05-rtl-simulation.md](docs/05-rtl-simulation.md) | **Bonus：** AHB、AXI-Lite slave wrapper FSM 的 VHDL RTL 與自我檢查 testbench（GHDL） |

圖都放在 [`diagrams/`](diagrams/) 資料夾，用 draw.io 畫、存成 `.drawio`，在 GitHub 上點開檔案
就能直接看；各篇 doc 裡用連結指過去，沒有把圖直接嵌在 Markdown 裡。

## 一些筆記

SIP 選 UART（內含 DMA），對應白板上的例子跟作業要求的 `SIP(M+S, 內有DMA)`。AHB 那邊的狀態命名
（`IDLE/NONSEQ/SEQ/BUSY/WAIT/ERR1/ERR2`）照課堂教的 Manager/Subordinate FSM 來，套到實際的周邊
wrapper 上。AXI 因為 write/read channel（AW/W/B 跟 AR/R）本來就是獨立的，所以 wrapper FSM 也拆
成兩條，這樣 AXI 版 MSC 才能讓 CPU 讀狀態跟 DMA 的 write burst 重疊 — AHB 是共用匯流排，同一時
間只有一個 master 拿得到 grant，做不到這點。

課程教材：`IHI0033C_amba_ahb_protocol_spec.pdf`、`IHI0022L_amba_axi_protocol_spec.pdf`（上層資
料夾）。UART 暫存器配置參考了 [opencores.org](https://opencores.org/) 上常見的 UART core 風格。

Master/DMA wrapper FSM 跟 AHB arbiter（docs 01/02）目前還只有概念圖，沒刻成 RTL — 要模擬的話
還要再寫一個記憶體端的 slave 模型，這次先沒做。Bonus 的兩個 slave wrapper 原本是用 Verilog
寫的（邏輯對著同一組測項在 Icarus Verilog 下跑過 28/28 全過），課程規定要交 VHDL，所以照原本
邏輯翻成 VHDL（`rtl/*.vhd`），但這台機器還沒裝 GHDL，翻譯後的版本還沒有實際跑過模擬 — 細節見
[docs/05-rtl-simulation.md](docs/05-rtl-simulation.md)。
