# Bonus：RTL + 模擬（第 1 題 — Slave Wrapper FSM）

針對 UART SIP 的暫存器檔（CTRL/STATUS/TXDATA/RXDATA），實作
[01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) 與 [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md)
裡的 **AHB 與 AXI-Lite slave wrapper FSM**，課程規定用 VHDL，模擬用實驗室慣用的
**Vivado 2018.2 xsim**（板子是 EGO-XZ7，Zynq-7000）。

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

需要 Vivado（實驗室用的是 2018.2；`xvhdl`/`xelab`/`xsim` 要在 PATH 上，Windows 下即
`<Vivado 安裝路徑>\2018.2\bin`）：

```sh
sim/run_sims.sh
```

或手動（以 AHB 為例，AXI 版同樣流程）：

```sh
xvhdl --2008 rtl/ahb_uart_slave_wrapper.vhd sim/tb_ahb_uart_slave_wrapper.vhd
xelab tb_ahb_uart_slave_wrapper -s ahb_sim
xsim ahb_sim -R
```

每個 testbench 都會自我檢查（每項檢查 `report [PASS]/[FAIL]`，有失敗就 `severity failure`），
跑完呼叫 `std.env.finish` 讓 xsim 自己結束（不然 `clk_gen` 一直跑，模擬永遠不會自然停）。AXI 版
用兩個常駐的 `write_driver`/`read_driver` process 分別獨佔 AW/W/B 跟 AR/R 兩組訊號，`stim`
process 只透過 `wr_req`/`rd_req` 兩個簡單的 handshake 訊號下指令——這樣兩個 process 天生就是
並行的，不需要再另外搞一個 `fork`/`join` 等價物，也借此避免「兩個 process 都去 drive 同一條
AXI 訊號」這種 VHDL 多重 driver 衝突（細節見 testbench 檔頭註解）。

## 結果（已在 Vivado 2018.2 xsim 上跑過，全部通過）

### AHB UART slave wrapper — `sim/tb_ahb_uart_slave_wrapper.vhd`

涵蓋：一般的 OKAY 讀寫、背靠背的 pipelined 傳輸（`NONSEQ→NONSEQ`）、TXDATA 寫入撞上 `tx_busy`
時插入 `WAIT`、RX 資料到達後讀取的流程，以及位址超出範圍時 2-cycle 的 `ERROR` 回應、之後恢復
正常存取。

```
Note: [PASS] CTRL write returns OKAY                                            Time: 66 ns
Note: [PASS] CTRL read-back == 1                                                Time: 96 ns
Note: [PASS] xfer1 (STATUS) completes same cycle xfer2 address phase issued     Time: 116 ns
Note: [PASS] xfer1 STATUS resp OKAY                                             Time: 116 ns
Note: [PASS] pipelined xfer2 (CTRL) read-back == 1                              Time: 126 ns
Note: [PASS] first TXDATA write OKAY, tx_busy now set                          Time: 166 ns
Note: [PASS] STATUS.tx_busy == 1 right after TXDATA write                      Time: 196 ns
Note: [PASS] second TXDATA write (into WAIT) eventually OKAY                   Time: 226 ns
Note: [PASS] TXDATA committed only after wait states cleared                   Time: 256 ns
Note: [PASS] STATUS.tx_busy == 0 after TX finished                             Time: 286 ns
Note: [PASS] STATUS.rx_ready == 1 after byte arrival                           Time: 336 ns
Note: [PASS] RXDATA read == 0xA5                                               Time: 366 ns
Note: [PASS] STATUS.rx_ready == 0 after RXDATA read (cleared)                  Time: 396 ns
Note: [PASS] out-of-range address returns HRESP=ERROR                         Time: 446 ns
Note: [PASS] FSM recovers to normal OKAY access after ERROR                   Time: 476 ns

==== AHB UART slave wrapper: 15 passed, 0 failed ====
```

### AXI-Lite UART slave wrapper — `sim/tb_axi_lite_uart_slave_wrapper.vhd`

涵蓋跟 AHB 版一樣的情境，再加上 MSC 文件裡提到的協定差異：獨立的 `STATUS` 讀取（read
channel）**不用等** write channel 上被 back-pressure 的 TXDATA 寫入完成就能完成。

```
Note: [PASS] CTRL write returns OKAY                                           Time: 76 ns
Note: [PASS] CTRL read-back == 1                                               Time: 106 ns
Note: [PASS] first TXDATA write OKAY, tx_busy now set                         Time: 146 ns
Note: [PASS] STATUS.tx_busy == 1 right after TXDATA write                     Time: 176 ns
Note: [PASS] STATUS read (read channel) completes independently               Time: 216 ns
Note: [PASS] second TXDATA write eventually OKAY once tx_busy clears          Time: 216 ns
Note: [PASS] TXDATA committed only after back-pressure cleared                Time: 246 ns
Note: [PASS] STATUS.rx_ready == 1 after byte arrival                          Time: 296 ns
Note: [PASS] RXDATA read == 0xA5                                              Time: 326 ns
Note: [PASS] STATUS.rx_ready == 0 after RXDATA read (cleared)                 Time: 356 ns
Note: [PASS] out-of-range read returns RRESP=SLVERR                           Time: 386 ns
Note: [PASS] out-of-range write returns BRESP=SLVERR                         Time: 426 ns
Note: [PASS] FSM recovers to normal OKAY access after SLVERR                 Time: 456 ns

==== AXI-Lite UART slave wrapper: 13 passed, 0 failed ====
```

兩個測試套件在 Vivado 2018.2 xsim 下全部通過（28/28 項檢查），跟原本 Verilog 版本
（Icarus Verilog 12.0 下 28/28）結果一致——時間戳記也幾乎完全對得上，代表翻譯過程沒有
改變任何時序行為。

### 翻譯過程中遇到的一個真實問題

第一次照 Verilog task 的寫法直接翻成 VHDL procedure 時（procedure 內直接存取外層 architecture
的訊號並賦值），`xvhdl` 直接報錯：`cannot assign signal ... from within a subprogram`。VHDL
的規則跟 Verilog task 不一樣：procedure 只能透過**明確宣告的 signal-class 參數**去驅動訊號，
不能像 Verilog task 那樣直接賦值給外層作用域的訊號。兩個 testbench 的 `ahb_write`/`ahb_read`/
`axi_write`/`axi_read` 都補上了完整的 signal 參數列表才能通過編譯。

AXI 版還有第二個更隱晦的問題：原本設計是 `stim` process 跟兩個一次性的 `write_thread`/
`read_thread` process 都呼叫同一個會驅動 AXI 訊號的 procedure——這樣等於同一條訊號（例如
`awvalid`）同時有兩個不同 process 在當 driver。VHDL 的 resolved signal 允許多重 driver，但
沒有 process 在「主動」驅動時，driver 還是會保留它最後一次指定的值；當另一個 process 真的
開始驅動（例如設成 `'1'`）時，兩個 driver 的值衝突（`'0'` 跟 `'1'`）就會被解析成 `'X'`，讓
後續的握手邏輯永遠等不到正確的值，模擬卡住、`xsim` 一直不會結束（但看起來像是「跑得很慢」，
不會立即報錯）。這點在 Icarus Verilog 的 `fork`/`join` 寫法下不會發生，因為 Verilog 是
procedural assignment、沒有 VHDL 這種多重 driver 解析語意。修法是讓每個 AXI channel 從頭到尾
都只有一個常駐 process 在驅動（`write_driver`/`read_driver`），`stim` 改成只透過簡單的
`req`/`done` 訊號下指令，不直接碰 AXI 訊號本身。
