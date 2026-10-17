# Bonus：RTL + 模擬

針對 UART SIP，實作 [01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) 與
[02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md) 裡畫的**全部**狀態機（slave wrapper、
master/DMA wrapper、AHB arbiter），讓模擬波型真的能跑出 [03-msc-ahb.md](03-msc-ahb.md)／
[04-msc-axi.md](04-msc-axi.md) 畫的 A→B→C→D 四個階段，不只是暫存器存取那一段。課程規定用
VHDL，模擬用實驗室慣用的 **Vivado 2018.2 xsim**（板子是 EGO-XZ7，Zynq-7000）。

## 範圍

**暫存器檔 slave wrapper**（單獨測，對應 MSC 的 phase A/C 那種單純讀寫）：
- `rtl/ahb_uart_slave_wrapper.vhd` — AHB-Lite slave wrapper FSM：
  `IDLE → NONSEQ → {WAIT* →} OKAY → IDLE` 與 `IDLE → NONSEQ → ERR1 → ERR2 → IDLE`，含背靠背的
  pipelined 傳輸。
- `rtl/axi_lite_uart_slave_wrapper.vhd` — AXI4-Lite slave wrapper：獨立的 write
  (`IDLE → WADDR → WDATA{wait*} → RESP → IDLE`) 與 read (`IDLE → RADDR → RDATA → IDLE`)
  channel FSM。

**系統層級**（這兩個 wrapper 再加上 master/DMA wrapper、記憶體 slave BFM，AHB 版還要再加一個
arbiter，兜起來跑完整的 MSC）：
- `rtl/ahb_uart_master_wrapper.vhd` — AHB master/DMA wrapper FSM：`IDLE → REQ → NONSEQ → SEQ* →
  LAST → DONE → IDLE`，收集 `BURST_LEN`（預設 4）個 RX byte 後，以 master 身份 burst 寫進記憶體。
- `rtl/ahb_arbiter.vhd` — 固定優先權（CPU > DMA）arbiter，`GRANT_NONE/GRANT_CPU/GRANT_DMA`。
- `rtl/ahb_mem_slave_bfm.vhd` — DMA burst 目標 + CPU 讀回用的簡化記憶體 slave（純模擬用，不是
  真的要合成的記憶體控制器，見 01 文件最後一節）。
- `rtl/axi_uart_master_wrapper.vhd` — AXI master/DMA wrapper FSM（只做 write 路徑，對稱的 read
  路徑只有 `Upload/axi_master_fsm.drawio` 上的概念設計，沒有刻成 RTL——要做到跟 write 路徑一樣
  完整，還需要一個目前專案裡完全沒有的「TX FIFO 門檻觸發」機制，AHB 版同樣沒做這塊）：
  `IDLE → AW → W{WLAST} → BWAIT → IDLE`，**真正的 AXI4 INCR burst**（一次 `AWVALID`+`AWLEN`+
  `AWBURST` 帶出整段傳輸，`BURST_LEN` 拍 `W` 用 `WLAST` 標最後一拍，一個 `BVALID` 收尾），不是
  AXI4-Lite 的「每拍各自一組 AW/W/B」。
- `rtl/axi_mem_slave_bfm.vhd` — write 側配合升級成能收真正的 AXI4 burst（`WLAST` 結束，內部位址
  自動遞增）；read 側（CPU phase D 讀回）維持 AXI4-Lite 單拍，因為 CPU 本來就是發
  `BURST_LEN` 次各自獨立的讀取，不需要真的 burst。
- AXI 版不需要另外的 arbiter RTL：CPU 跟 DMA 各自用自己獨立的 channel 直接接到各自要存取的
  slave，沒有共享匯流排的仲裁問題（見 02 文件最後一節）。

兩個暫存器檔 wrapper 共用同一套簡化過的 UART 暫存器模型，行為可以直接互相對照：

| 位移 | 暫存器 | 存取 | 行為 |
|---|---|---|---|
| `0x0` | CTRL | R/W | bit0 = enable |
| `0x4` | STATUS | RO | bit0 = tx_busy, bit1 = rx_ready, bit2 = dma_done（DMA burst 完成後
  設起來，CPU 讀 STATUS 時清掉——對應 MSC phase D 的「中斷＋讀狀態」） |
| `0x8` | TXDATA | R/W | 寫入會啟動一次模擬的傳輸（忙碌 4 個 cycle）；忙碌中再寫入會被
  back-pressure（AHB：`WAIT`；AXI：`WREADY=0`） |
| `0xC` | RXDATA | RO | 讀取後會清除 `rx_ready`；testbench 用 `rx_byte_valid`/`rx_byte_data`
  後門訊號模擬收到一個 byte（RX FIFO 為空時應該 block 的讀取，這裡簡化成 non-blocking — 詳見
  RTL 裡的註解） |
| `≥0x10` | — | — | AHB：2-cycle `HRESP=ERROR`；AXI：`BRESP`/`RRESP = SLVERR` |

`rx_ready_o`/`rx_data_o`/`dma_consume`/`dma_done_set` 是兩個暫存器檔 wrapper 額外加的 hook，
用來跟對應的 master/DMA wrapper 接起來（預設值讓舊的單獨測 testbench 不受影響）。另外還加了
`irq_o`（純組合邏輯接到內部 `dma_done`）——對照 MSC chart 畫的「SIP 發出中斷」這一步，兩個系統
testbench 的 CPU 端現在是真的在等這個 port 變成 `'1'`（`wait until irq_o = '1'`），不是用內部
測試訊號偷看 DMA 完成與否；STATUS 被讀過一次之後 `dma_done` 清掉，`irq_o` 也跟著降下來。

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

### AHB 系統層級 MSC — `sim/tb_ahb_system_msc.vhd`

把 arbiter、兩個暫存器檔/master wrapper、記憶體 BFM 接起來，實際跑一次 03 文件畫的四個階段：
CPU 設定 SIP（phase A）→ DMA 收滿 4 個 byte 後跟 arbiter 要匯流排（phase B，`HBUSREQ1`/
`HGRANT1`）→ burst 寫進記憶體（phase C，`NONSEQ`+3 個 `SEQ`）→ SIP 發 `irq_o` 中斷、CPU 讀
`STATUS.dma_done` 再把記憶體內容讀回來比對（phase D）。

```
Note: [PASS] phase A: CTRL write (enable) returns OKAY
Note: [PASS] phase B: DMA requested/was granted the bus (HBUSREQ1/HGRANT1)
Note: [PASS] phase C/D: SIP asserted IRQ (intr) after the burst completed
Note: [PASS] phase D: STATUS.dma_done == 1 after burst
Note: [PASS] phase D: IRQ deasserts once STATUS has been read (serviced)
Note: [PASS] phase D: memory[0] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[1] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[2] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[3] == byte DMA'd by the SIP

==== AHB system MSC (A/B/C/D): 9 passed, 0 failed ====
```

### AXI 系統層級 MSC — `sim/tb_axi_system_msc.vhd`

一樣四個階段，但 phase C 的 `STATUS` 讀取改用 CPU 自己獨立的 read channel，刻意安排成跟
phase B 的 DMA write burst**同時進行**（04 文件強調的那個 AHB 做不到的差異）：

```
Note: [PASS] phase A: CTRL write (enable) returns OKAY
Note: [PASS] phase C: STATUS read completes independently of the DMA write channel
Note: [PASS] phase C: SIP asserted IRQ (intr) once the write burst completed
Note: [PASS] phase C: STATUS.dma_done == 1 after burst
Note: [PASS] phase C: IRQ deasserts once STATUS has been read (serviced)
Note: [PASS] phase D: memory[0] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[1] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[2] == byte DMA'd by the SIP
Note: [PASS] phase D: memory[3] == byte DMA'd by the SIP

==== AXI system MSC (A/B/C/D): 9 passed, 0 failed ====
```

四個 testbench 在 Vivado 2018.2 xsim 下全部通過（15+13+9+9 = 46/46 項檢查），其中暫存器檔
wrapper 那兩個跟原本 Verilog 版本（Icarus Verilog 12.0 下 28/28）結果一致——時間戳記也幾乎
完全對得上，代表翻譯過程沒有改變任何時序行為。

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

### 系統層級時又遇到的三個真實問題

寫 master wrapper/arbiter/記憶體 BFM 這幾個新模組時，又踩到幾個跟上面兩個不一樣、純粹是這次
新增的狀態機/BFM 設計沒想清楚的 bug（不是翻譯問題），都是先跑過才發現的：

1. **arbiter 允許 CPU 在 DMA burst 中途把匯流排搶走。** 第一版 `GRANT_DMA → GRANT_CPU` 的條件
   只檢查 `HBUSREQ0='1' and HREADY='1'`，沒檢查 DMA 自己的 `HBUSREQ1` 是不是已經放掉——這跟
   AHB 規則（grant 只能在傳輸邊界切換）不符，也跟我自己寫在檔頭註解裡「self-release」的設計
   意圖矛盾。修法是兩個方向都要求「正在拿 grant 的那個 master 自己先放掉 HBUSREQ」才能換人。
2. **master wrapper 的輸出比狀態晚了一拍。** 第一版把「要送出的位址/HTRANS」寫在狀態轉移的
   同一段程式碼裡（例如進入 `S_NONSEQ` 時才去設下一輪要用的 `haddr`），結果變成這個位址要到
   *下一個* state 才會真的出現在匯流排上——跟 slave wrapper 那種「輸出完全是目前 state 的
   組合邏輯函式」的寫法不一樣，混進了一個不小心多出來的暫存器級。改成跟 slave wrapper 同款的
   兩段式（組合邏輯輸出 process + 時序 bookkeeping process）就修好了，只有 `HWDATA`（故意要晚
   `HADDR`/`HTRANS` 一拍，符合 AHB 寫入資料相位本來就落後位址相位一個 cycle 的規則）才保留
   明確的暫存管線。
3. **記憶體 BFM 的寫入沒有「只做一次」的保護，讀取卻多了一個不必要的延遲。** 第一版用
   `addr_q`/`write_q` 記住上次的交易，但沒有一個「這筆交易還有效」的旗標，於是匯流排上換成
   別的、不相關的交易之後，`write_q='1'` 還是繼續每個 cycle 重寫同一個位址，拿當下匯流排上
   剛好出現的（跟這個 BFM 完全無關的）`HWDATA` 當資料，把前一次 burst 寫好的最後一個字覆蓋掉。
   補上一個「只在剛鎖定位址的下一個 cycle 才生效」的 one-shot `pending` 旗標治好了寫入，但這
   個旗標如果同時套用在讀取路徑上，又會讓 `HRDATA` 比 slave wrapper 的時序晚一拍，跟 CPU 讀取
   procedure 預期的「資料跟 `HREADYOUT=1` 同一個 cycle 就位」兜不起來。最後拆成兩條路：寫入
   維持 `pending` 保護，讀取改成直接用目前的 `addr_q` 組合邏輯算 `HRDATA`（讀到舊位址不會造成
   資料損毀，不需要這層保護）。

### 後來補 IRQ port 時又遇到的一個真實問題

回頭比對 MSC chart 跟實際 RTL 後，發現圖上畫的「SIP 發出中斷」這一步在電路裡從缺——兩個系統
testbench 原本是直接等一個內部訊號（`dma_consume`/`dma_done_set` 之間的握手線）才知道 DMA 做
完，不是真的被中斷喚醒。補上 `irq_o`（純組合邏輯接到內部 `dma_done`，CPU 讀 STATUS 清掉
`dma_done` 後 `irq_o` 也跟著降下來）之後，AXI 版的 `irq_o` 卻卡在 `'1'` 永遠不降——查下去發現
`axi_lite_uart_slave_wrapper.vhd` 裡原本就有的 `commit_read` 訊號，定義其實是「只在讀 RXDATA
時才算數」（`commit_read <= '1' when (... and araddr_q(3 downto 0) = ADDR_RXDATA) else '0';`，
拿來清 `rx_ready` 用的），不是「任何一次成功的讀取」。我幫 `dma_done` 加清除邏輯時沿用了 AHB
版的寫法（`commit_read='1' and addr=ADDR_STATUS`），卻沒注意到這個 `commit_read` 在 AHB、AXI
兩個檔案裡的定義範圍根本不一樣——AHB 版的 `commit_read` 本來就是「任何位址都算」，AXI 版卻早就
被限定成 RXDATA-only，兩者同名但語意不同。`commit_read='1' and addr=ADDR_STATUS` 這個條件因此
永遠不會成立。修法是另外加一個 `read_ok`（不限位址、純粹「這次讀取成功了」）給 `dma_done` 的
清除邏輯用，`commit_read` 維持原本 RXDATA-only 的語意給 `rx_ready` 用，兩個訊號分開、不要混用。

### 再檢查一輪：FSM 圖（不只 MSC chart）跟 RTL 有沒有對上

補完 IRQ 之後又被問了一次「現在完全符合了嗎」，這次除了 MSC chart 本身的文字標籤，連
`ahb_master_fsm.drawio`、`ahb_arbiter_fsm.drawio`、`axi_master_fsm.drawio`、`axi_slave_fsm.drawio`
這些更早、在 RTL 寫出來**之前**就畫好的狀態機圖，也重新對照了一次實際的 VHDL：

- `ahb_arbiter_fsm.drawio` 的 e4（CPU→DMA）明確寫了 `!HBUSREQ0`，但 e7（DMA→CPU）卻只寫「到達
  burst 邊界」，沒有對稱地寫出 `!HBUSREQ1`——跟目前 RTL 實際要求的「正在拿 grant 的那個 master
  自己放掉 busreq 才換手」不完全對得上文字，容易誤讀成可以搶占。補上明確的 `!HBUSREQ1`，兩個
  方向的寫法對稱。
- `axi_master_fsm.drawio` 落差最大：圖上畫的是**真正的 AXI4 burst**（一次 `AWVALID`+`AWLEN`+
  `AWBURST=INCR`，多拍 `W` 用 `WLAST` 收尾，一個 `BVALID` 結束整個傳輸）外加完整的 read-DMA
  （TX 方向）路徑，但原本的 `axi_uart_master_wrapper.vhd` 是 AXI4-Lite、write-only、用
  `BURST_LEN` 次各自獨立的單拍 transaction 代表 burst——跟圖完全是兩套設計。選擇「改電路配合
  圖」：把 `axi_uart_master_wrapper.vhd` 重寫成圖上畫的 `IDLE→AW→W{WLAST 前自迴圈}→BWAIT→IDLE`，
  `axi_mem_slave_bfm.vhd` 的 write 側也跟著升級成能收 `WLAST` 結尾的真 burst（內部位址自動遞增，
  不用每拍收一次 `AWADDR`）。read 路徑（TX 方向）維持概念設計，圖上的標題文字改成清楚標示
  「概念設計，未刻成 RTL／未在 testbench 驗證」，而不是悄悄留著讓人誤以為兩條路徑都做了。
  改完後重新 46/46 全過，而且因為是真的 burst（位址只送一次），完成時間比之前快了將近 70 ns。
- `ahb_master_fsm.drawio`、`axi_slave_fsm.drawio` 也有類似但較小的落差（前者把 RTL 的
  `S_LAST`/`S_DONE` 兩個收尾 cycle 併成一條邊；後者畫出 `WADDR`/`RADDR`/`READ_WAIT` 這些實際
  VHDL 裡沒有獨立存在的狀態，`READ_WAIT` 對應的「RX FIFO 空要 block」行為也早就簡化成
  non-blocking，這點在暫存器表格已經寫過）——這兩個屬於圖比 RTL 更細的正常抽象層次落差，不是
  邏輯錯誤，先不動。
