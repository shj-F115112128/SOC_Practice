# Message Sequence Chart — AHB

依作業要求的參與者：**CPU (Master)**、**Mem Controller (Slave)**、**SIP = UART (Master + Slave，
內含 DMA 引擎)**。情境：CPU 設定 UART，收到完整一筆 RX 資料後由 DMA 搬到記憶體，最後 CPU 讀回
狀態與資料。

```mermaid
sequenceDiagram
    participant CPU as CPU (M)
    participant ARB as Arbiter
    participant SIP as SIP / UART (M+S)
    participant MEM as Mem Controller (S)

    Note over CPU,SIP: 1. CPU 設定 UART（CPU=M, SIP=S）
    CPU->>SIP: HTRANS=NONSEQ, HADDR=CTRL_REG, HWRITE=1, HWDATA=enable|dma_thresh
    SIP-->>CPU: HREADYOUT=1, HRESP=OKAY

    Note over SIP: UART 收到序列資料，RX FIFO 填到門檻值
    SIP->>ARB: HBUSREQ1（SIP 以 Master 身份請求匯流排）
    ARB-->>SIP: HGRANT1=1

    Note over SIP,MEM: 2. SIP-DMA 把 RX 資料 burst 寫入記憶體（SIP=M, MEM=S）
    SIP->>MEM: HTRANS=NONSEQ, HADDR=buf_ptr, HWRITE=1, HBURST=INCR4
    loop 還有 3 拍
        SIP->>MEM: HTRANS=SEQ, HADDR=buf_ptr+N, HWDATA=rx_byte[n]
        MEM-->>SIP: HREADYOUT=1, HRESP=OKAY
    end
    SIP->>ARB: 解除 HBUSREQ1（burst 完成）

    Note over SIP,CPU: 3. SIP 發出中斷（IRQ，非 AHB 訊號，屬於帶外）
    SIP-)CPU: uart_irq = 1

    Note over CPU,SIP: 4. CPU 輪詢/讀取狀態（CPU=M, SIP=S）
    CPU->>SIP: HTRANS=NONSEQ, HADDR=STATUS_REG, HWRITE=0
    SIP-->>CPU: HREADYOUT=1, HRDATA=dma_done|rx_count

    Note over CPU,MEM: 5. CPU 讀取收到的資料（CPU=M, MEM=S）
    CPU->>MEM: HTRANS=NONSEQ, HADDR=buf_ptr, HWRITE=0
    MEM-->>CPU: HREADYOUT=1, HRDATA=rx_byte[0]
    loop 還有 3 拍
        CPU->>MEM: HTRANS=SEQ, HADDR=buf_ptr+N
        MEM-->>CPU: HRDATA=rx_byte[n]
    end
```

## 補充說明

步驟 2 的時候 SIP 自己變成 master 在搬資料，這時候匯流排是它的，CPU 要等（arbiter 見
[01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md)），所以步驟 4/5 得排在 burst 結束後面。

TX 方向沒有另外畫一張圖，因為形狀幾乎一樣，只是 DMA burst 變成讀記憶體（`HWRITE=0`）再丟進
TX FIFO，其他步驟照搬就好。
