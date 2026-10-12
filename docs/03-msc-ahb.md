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

- 步驟 1、4、5 都是 CPU 以 Master 身份發出的一般單次/burst AHB 傳輸；步驟 2 則是 SIP 內部 DMA
  以 Master 身份動作 — 同一時間只有 CPU 或 SIP 其中一個能擁有匯流排（見
  [01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) 的 arbiter FSM），所以步驟 4/5 要等步驟 2 的
  burst 結束才能開始。
- 對稱的 TX 路徑（CPU 把資料寫進記憶體，之後 SIP-DMA 再把資料 burst 讀出放進 TX FIFO，UART
  再序列化送出）形狀相同，只是 DMA burst 的 HWRITE 方向改成讀取（SIP=M 對 Mem Controller 發出
  `HWRITE=0`）。
