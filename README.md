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
| [docs/05-rtl-simulation.md](docs/05-rtl-simulation.md) | **Bonus：** AHB、AXI-Lite slave wrapper FSM 的 Verilog RTL 與自我檢查 testbench，已在 Icarus Verilog 下跑過並通過 |

所有圖都用 [Mermaid](https://mermaid.js.org/)（`stateDiagram-v2` / `sequenceDiagram`）直接寫在 Markdown
裡 — GitHub 會原生渲染，不需要額外工具匯出。

## 設計決策

- **SIP = UART**，內含 DMA 引擎，對應白板上的範例（`ex. UART`）以及作業要求的
  `SIP(M+S, 內有DMA)`。
- AHB FSM 的狀態命名（`IDLE/NONSEQ/SEQ/BUSY/WAIT/ERR1/ERR2`）沿用課程前面教過的 AHB
  Manager/Subordinate 通用 FSM 慣例（來自 AHB 協定規格書 `IHI0033C`），這裡把它套用到實際的
  周邊 wrapper，而不只是抽象協定層級。
- AXI wrapper FSM 依 channel 拆開（write：AW/W/B，read：AR/R），因為這些 channel 彼此獨立 —
  這也是為什麼 AXI 版 MSC 可以讓 CPU 的狀態讀取跟 DMA 的 write burst 重疊，而 AHB 版不行
  （單一共享匯流排，同一時間只有一個 arbiter grant）。

## 參考資料

- AMBA AHB 協定規格書 — `IHI0033C_amba_ahb_protocol_spec.pdf`（課程教材，上層資料夾）
- AMBA AXI 協定規格書 — `IHI0022L_amba_axi_protocol_spec.pdf` / `AMBAaxi.pdf`（課程教材，上層資料夾）
- [opencores.org](https://opencores.org/) — 開源 IP core，含 AHB/AXI/Zynq 風格的 UART wrapper

## 可能的後續

- Master/DMA wrapper FSM 以及 AHB arbiter（docs 01/02）目前只有概念圖 — 要實作並模擬的話，
  需要再做一個代表記憶體端 slave 的 bus-functional model。
