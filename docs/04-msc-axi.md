# Message Sequence Chart — AXI

與 [03-msc-ahb.md](03-msc-ahb.md) 相同的情境與參與者 — **CPU (M)**、**Mem Controller (S)**、
**SIP = UART (M+S，含 DMA)** — 改用 AXI 的 5 個 channel（AW/W/B 寫入、AR/R 讀取）重畫。跟 AHB
最大的行為差異：write 與 read channel 彼此獨立，所以 CPU 的狀態/資料讀取（步驟 4–5）**不需要**
等 SIP-DMA 的 write burst（步驟 2）完全結束 — 兩者可以同時 outstanding，靠 `AWID`/`ARID` 標記
區分。

```mermaid
sequenceDiagram
    participant CPU as CPU (M)
    participant XBAR as Interconnect
    participant SIP as SIP / UART (M+S)
    participant MEM as Mem Controller (S)

    Note over CPU,SIP: 1. CPU 設定 UART（CPU=M, SIP=S）
    CPU->>SIP: AWVALID, AWADDR=CTRL_REG
    SIP-->>CPU: AWREADY
    CPU->>SIP: WVALID, WDATA=enable|dma_thresh, WSTRB
    SIP-->>CPU: WREADY
    SIP-->>CPU: BVALID, BRESP=OKAY
    CPU->>SIP: BREADY

    Note over SIP: UART 收到序列資料，RX FIFO 填到門檻值
    Note over SIP,MEM: 2. SIP-DMA 把 RX 資料 burst 寫入記憶體（SIP=M, MEM=S），AWID=1
    SIP->>XBAR: AWVALID, AWADDR=buf_ptr, AWLEN=3, AWBURST=INCR, AWID=1
    XBAR->>MEM: 轉發 AW
    MEM-->>SIP: AWREADY
    loop 4 拍
        SIP->>MEM: WVALID, WDATA=rx_byte[n], WLAST(第 4 拍時)
        MEM-->>SIP: WREADY
    end
    MEM-->>SIP: BVALID, BRESP=OKAY, BID=1
    SIP->>MEM: BREADY

    Note over SIP,CPU: 3. SIP 發出中斷（IRQ，非 AXI 訊號，屬於帶外）
    SIP-)CPU: uart_irq = 1

    par 可與步驟 2 的 B response 同時進行
        Note over CPU,SIP: 4. CPU 讀取狀態（CPU=M, SIP=S），ARID=0
        CPU->>SIP: ARVALID, ARADDR=STATUS_REG, ARID=0
        SIP-->>CPU: ARREADY
        SIP-->>CPU: RVALID, RDATA=dma_done|rx_count, RLAST=1, RID=0
        CPU->>SIP: RREADY
    end

    Note over CPU,MEM: 5. CPU 讀取收到的資料（CPU=M, MEM=S），ARID=0
    CPU->>XBAR: ARVALID, ARADDR=buf_ptr, ARLEN=3, ARBURST=INCR
    XBAR->>MEM: 轉發 AR
    MEM-->>CPU: ARREADY
    loop 4 拍
        MEM-->>CPU: RVALID, RDATA=rx_byte[n], RLAST(第 4 拍時)
        CPU->>MEM: RREADY
    end
```

## 補充說明

步驟 4 放進 `par` 區塊是故意的 — 想表示它跑在 AR/R channel，跟步驟 2 的 write burst（還在
AW/W/B 上）其實是同時進行的，AHB 版做不到這件事。

靠的是 `AWID`/`ARID`：Mem Controller 跟 interconnect 用這個 ID 把回應導回正確的 master，所以
CPU 跟 SIP 的交易可以一起 outstanding（細節在 [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md)）。

TX 路徑一樣沒另外畫，概念上跟步驟 2 一樣，只是換成 SIP 的 read-DMA FSM 去讀記憶體。
