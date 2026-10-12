# AXI Master / Slave Wrapper FSM — UART SIP

跟 AHB 版本相同的 UART SIP（見 [01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md)），這次改包裝在
AXI 上。跟 AHB 單一共享的位址/資料匯流排不同，AXI 有 5 個獨立的 channel（AW、W、B、AR、R），
所以 wrapper 自然會拆成 master 端與 slave 端各自獨立的 **write FSM** 和 **read FSM** — 它們可以
並行運作。

## 系統拓樸

```mermaid
flowchart LR
    CPU["CPU (Master 0)"] --> XBAR
    DMA["SIP-DMA (Master 1)\n位於 UART wrapper 內"] --> XBAR
    XBAR["AXI Interconnect\n（逐 channel 仲裁，以 ID 標記）"] --> MEM["Mem Controller (Slave 0)"]
    XBAR --> UARTREG["UART Reg File (Slave 1)"]
```

## 1. AXI Slave Wrapper FSM（UART 暫存器檔）

### Write 路徑（AW + W + B）

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> WADDR: AWVALID\n（assert AWREADY，鎖存 AWADDR）
    WADDR --> WDATA: AWREADY&AWVALID 握手完成
    WDATA --> WDATA: WVALID & !reg_ready\n（WREADY=0，例如 TX FIFO 滿）
    WDATA --> WRITE_REG: WVALID & reg_ready\n（WREADY=1，套用 WSTRB byte lane，寫入暫存器）
    WRITE_REG --> RESP: 鎖存 BRESP=OKAY（若位址/WSTRB 非法則為 SLVERR）
    RESP --> IDLE: BVALID & BREADY 握手
```

### Read 路徑（AR + R）

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> RADDR: ARVALID\n（assert ARREADY，鎖存 ARADDR）
    RADDR --> READ_WAIT: ARREADY&ARVALID 握手完成
    READ_WAIT --> READ_WAIT: !reg_ready（RX FIFO 空）
    READ_WAIT --> RDATA: reg_ready\n（驅動 RDATA、RRESP=OKAY、RVALID=1）
    RDATA --> IDLE: RVALID & RREADY 握手（RLAST=1，單拍暫存器讀取）
```

## 2. AXI Master Wrapper FSM（UART 內部 DMA）

Write 與 read 兩條 DMA 路徑是各自獨立的狀態機 — DMA 引擎可以同時有一個 read burst（補 TX 資料）
跟一個 write burst（清空 RX）在進行中，這是 AHB master wrapper 做不到的。

### Write 路徑（RX FIFO → 記憶體）

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> AW: 觸發 RX 門檻\n（assert AWVALID、AWADDR、AWLEN=burst-1、AWBURST=INCR）
    AW --> W: AWVALID&AWREADY 握手
    W --> W: WVALID&WREADY & !WLAST（還有更多拍）
    W --> BWAIT: WVALID&WREADY & WLAST
    BWAIT --> IDLE: BVALID&BREADY\n（BRESP=OKAY：清除 RX 旗標；SLVERR：設定錯誤狀態）
```

### Read 路徑（記憶體 → TX FIFO）

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> AR: TX FIFO 低於門檻\n（assert ARVALID、ARADDR、ARLEN=burst-1、ARBURST=INCR）
    AR --> R: ARVALID&ARREADY 握手
    R --> R: RVALID&RREADY & !RLAST（還有更多拍，推入 TX FIFO）
    R --> IDLE: RVALID&RREADY & RLAST\n（每拍檢查 RRESP；SLVERR 會中止剩餘的推入動作）
```

## 多 Master / 多 Slave 補充說明

AXI 沒有像 AHB `HGRANT` 那樣單一的中央 arbiter FSM。每個 slave 的 **AW** 與 **AR** channel 會在
interconnect 上各自獨立對提出請求的多個 master 做仲裁（並以 ID 標記，讓回應可以路由回正確的
master，也讓多組 master/slave 交易可以同時 outstanding）。上面這些 slave 端 FSM 是以每個
slave port 為單位，記憶體控制器的 AXI slave 也會重複使用同一套邏輯，只是沒有暫存器忙碌造成的
wait 狀態。
