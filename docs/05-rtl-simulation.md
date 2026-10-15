# Bonus：RTL + 模擬（第 1 題 — Slave Wrapper FSM）

針對 UART SIP 的暫存器檔（CTRL/STATUS/TXDATA/RXDATA），實作
[01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) 與 [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md)
裡的 **AHB 與 AXI-Lite slave wrapper FSM**。

## 範圍

在範圍內：
- `rtl/ahb_uart_slave_wrapper.vhd` — AHB-Lite slave wrapper FSM：
  `IDLE → NONSEQ → {WAIT* →} OKAY → IDLE` 與 `IDLE → NONSEQ → ERR1 → ERR2 → IDLE`，含背靠背的
  pipelined 傳輸。
- `rtl/axi_lite_uart_slave_wrapper.vhd` — AXI4-Lite slave wrapper：獨立的 write
  (`IDLE → WADDR → WDATA{wait*} → RESP → IDLE`) 與 read (`IDLE → RADDR → RDATA → IDLE`)
  channel FSM。

沒做的部分：**master/DMA wrapper FSM** 跟 **AHB arbiter FSM**，還是留在 docs 01/02 的圖那邊。要
讓它們動起來還得另外寫一個記憶體端的 bus-functional model 當對手，時間抓不夠就先放一邊 —
這兩個暫存器檔 slave wrapper 本身就能單獨測，先把這個做完整比較實際。

兩個 wrapper 共用同一套簡化過的 UART 暫存器模型，行為可以直接互相對照：

| 位移 | 暫存器 | 存取 | 行為 |
|---|---|---|---|
| `0x0` | CTRL | R/W | bit0 = enable |
| `0x4` | STATUS | RO | bit0 = tx_busy, bit1 = rx_ready |
| `0x8` | TXDATA | R/W | 寫入會啟動一次模擬的傳輸（忙碌 4 個 cycle）；忙碌中再寫入會被
  back-pressure（AHB：`WAIT`；AXI：`WREADY=0`） |
| `0xC` | RXDATA | RO | 讀取後會清除 `rx_ready`；testbench 用 `rx_byte_valid`/`rx_byte_data`
  後門訊號模擬收到一個 byte（RX FIFO 為空時應該 block 的讀取，這裡簡化成 non-blocking — 詳見
  RTL 裡的註解） |
| `≥0x10` | — | — | AHB：2-cycle `HRESP=ERROR`；AXI：`BRESP`/`RRESP = SLVERR` |

## 怎麼跑

需要 [GHDL](https://ghdl.github.io/ghdl/)（`winget install GHDL.GHDL`，Linux 上可用
`apt install ghdl`）：

```sh
sim/run_sims.sh
```

或手動：

```sh
ghdl -a --std=08 rtl/ahb_uart_slave_wrapper.vhd sim/tb_ahb_uart_slave_wrapper.vhd
ghdl -e --std=08 tb_ahb_uart_slave_wrapper
ghdl -r --std=08 tb_ahb_uart_slave_wrapper --vcd=sim/ahb_uart_slave_wrapper.vcd

ghdl -a --std=08 rtl/axi_lite_uart_slave_wrapper.vhd sim/tb_axi_lite_uart_slave_wrapper.vhd
ghdl -e --std=08 tb_axi_lite_uart_slave_wrapper
ghdl -r --std=08 tb_axi_lite_uart_slave_wrapper --vcd=sim/axi_lite_uart_slave_wrapper.vcd
```

每個 testbench 都會自我檢查（每項檢查 `report [PASS]/[FAIL]`，有失敗就 `severity failure`），
並匯出 `.vcd` 波形，想直接看 FSM 狀態轉換的話可以用 GTKWave 開。AXI 版用 `start_overlap` 訊號
搭配兩個 process（`write_thread`/`read_thread`）模擬「write 被 back-pressure 時，read channel
仍能獨立完成」這件事，對應原本 Verilog 版的 `fork`/`join`。

## 目前狀態

這兩個 wrapper 原本是用 Verilog 寫的，邏輯在 Icarus Verilog 12.0 下對著同一組測項跑過
28/28 全過；這次照課程規定翻成 VHDL（狀態機、暫存器模型、testbench 都是逐項對應翻譯，行為應該
一致），但這台機器目前沒有裝 GHDL，**VHDL 版本還沒有實際跑過模擬**。等裝好模擬器會補跑一次，
確認翻譯後一樣能通過全部測項。
