# Bonus：RTL + 模擬（第 1 題 — Slave Wrapper FSM）

針對 UART SIP 的暫存器檔（CTRL/STATUS/TXDATA/RXDATA），實作並模擬
[01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) 與 [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md)
裡的 **AHB 與 AXI-Lite slave wrapper FSM**，使用 [Icarus Verilog](http://iverilog.icarus.com/)。

## 範圍

在範圍內（已實作 + 已模擬）：
- `rtl/ahb_uart_slave_wrapper.v` — AHB-Lite slave wrapper FSM：
  `IDLE → NONSEQ → {WAIT* →} OKAY → IDLE` 與 `IDLE → NONSEQ → ERR1 → ERR2 → IDLE`，含背靠背的
  pipelined 傳輸。
- `rtl/axi_lite_uart_slave_wrapper.v` — AXI4-Lite slave wrapper：獨立的 write
  (`IDLE → WADDR → WDATA{wait*} → RESP → IDLE`) 與 read (`IDLE → RADDR → RDATA → IDLE`)
  channel FSM。

不在範圍內（留在 docs 01/02 的概念 Mermaid 圖，沒有實作成 RTL）：**master/DMA wrapper FSM** 與
**AHB arbiter FSM**（多 Master 仲裁用）— 這兩個要有意義地模擬，需要再做一個代表記憶體端 slave
的 bus-functional model，工作量超出這次 bonus 的範圍。這兩個暫存器檔 slave wrapper 是真正能
獨立測試、也最直接對應「wrapper FSM」本身的部分，所以優先做這兩個。

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

需要 Icarus Verilog（`winget install Icarus.Verilog`，Linux 上可用 `apt install iverilog`）：

```sh
sim/run_sims.sh
```

或手動：

```sh
iverilog -g2005 -o sim/ahb_tb.vvp rtl/ahb_uart_slave_wrapper.v sim/tb_ahb_uart_slave_wrapper.v
vvp sim/ahb_tb.vvp

iverilog -g2005 -o sim/axi_tb.vvp rtl/axi_lite_uart_slave_wrapper.v sim/tb_axi_lite_uart_slave_wrapper.v
vvp sim/axi_tb.vvp
```

每個 testbench 都會自我檢查（每項檢查印出 `$display [PASS]/[FAIL]`，任何失敗就 `$fatal`），
並匯出 `.vcd` 波形，想直接看 FSM 狀態轉換的話可以用 GTKWave 開。

## 結果

### AHB UART slave wrapper — `sim/tb_ahb_uart_slave_wrapper.v`

涵蓋：一般的 OKAY 讀寫、背靠背的 pipelined 傳輸（`NONSEQ→NONSEQ`）、TXDATA 寫入撞上 `tx_busy`
時插入 `WAIT`、RX 資料到達後讀取的流程，以及位址超出範圍時 2-cycle 的 `ERROR` 回應、之後恢復
正常存取。

```
[PASS] 66000: CTRL write returns OKAY
[PASS] 96000: CTRL read-back == 1
[PASS] 116000: xfer1 (STATUS) completes same cycle xfer2 address phase issued
[PASS] 116000: xfer1 STATUS resp OKAY
[PASS] 126000: pipelined xfer2 (CTRL) read-back == 1
[PASS] 166000: first TXDATA write OKAY, tx_busy now set
[PASS] 196000: STATUS.tx_busy == 1 right after TXDATA write
[PASS] 226000: second TXDATA write (into WAIT) eventually OKAY
[PASS] 256000: TXDATA committed only after wait states cleared
[PASS] 286000: STATUS.tx_busy == 0 after TX finished
[PASS] 336000: STATUS.rx_ready == 1 after byte arrival
[PASS] 366000: RXDATA read == 0xA5
[PASS] 396000: STATUS.rx_ready == 0 after RXDATA read (cleared)
[PASS] 446000: out-of-range address returns HRESP=ERROR
[PASS] 476000: FSM recovers to normal OKAY access after ERROR

==== AHB UART slave wrapper: 15 passed, 0 failed ====
```

### AXI-Lite UART slave wrapper — `sim/tb_axi_lite_uart_slave_wrapper.v`

涵蓋跟 AHB 版一樣的情境，再加上 MSC 文件裡提到的協定差異：獨立的 `STATUS` 讀取（read
channel）**不用等** write channel 上被 back-pressure 的 TXDATA 寫入完成就能完成（用
`fork`/`join` 同時發出兩者）— 這在 AHB 單一共享匯流排上是做不到的。

```
[PASS] 76000: CTRL write returns OKAY
[PASS] 106000: CTRL read-back == 1
[PASS] 146000: first TXDATA write OKAY, tx_busy now set
[PASS] 176000: STATUS.tx_busy == 1 right after TXDATA write
[PASS] 216000: STATUS read (read channel) completes independently
[PASS] 216000: second TXDATA write eventually OKAY once tx_busy clears
[PASS] 246000: TXDATA committed only after back-pressure cleared
[PASS] 296000: STATUS.rx_ready == 1 after byte arrival
[PASS] 326000: RXDATA read == 0xA5
[PASS] 356000: STATUS.rx_ready == 0 after RXDATA read (cleared)
[PASS] 386000: out-of-range read returns RRESP=SLVERR
[PASS] 426000: out-of-range write returns BRESP=SLVERR
[PASS] 456000: FSM recovers to normal OKAY access after SLVERR

==== AXI-Lite UART slave wrapper: 13 passed, 0 failed ====
```

兩個測試套件在 Icarus Verilog 12.0 下全部通過（28/28 項檢查）。
