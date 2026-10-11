# Message Sequence Chart — AHB

Participants per the assignment: **CPU (Master)**, **Mem Controller (Slave)**, **SIP = UART (Master + Slave,
contains an internal DMA engine)**. Scenario: CPU configures the UART, a full RX word arrives and is
DMA'd to memory, then the CPU reads back the status and data.

```mermaid
sequenceDiagram
    participant CPU as CPU (M)
    participant ARB as Arbiter
    participant SIP as SIP / UART (M+S)
    participant MEM as Mem Controller (S)

    Note over CPU,SIP: 1. CPU configures UART (CPU=M, SIP=S)
    CPU->>SIP: HTRANS=NONSEQ, HADDR=CTRL_REG, HWRITE=1, HWDATA=enable|dma_thresh
    SIP-->>CPU: HREADYOUT=1, HRESP=OKAY

    Note over SIP: UART receives serial bytes, RX FIFO fills to threshold
    SIP->>ARB: HBUSREQ1 (SIP requests bus as Master)
    ARB-->>SIP: HGRANT1=1

    Note over SIP,MEM: 2. SIP-DMA bursts RX data to memory (SIP=M, MEM=S)
    SIP->>MEM: HTRANS=NONSEQ, HADDR=buf_ptr, HWRITE=1, HBURST=INCR4
    loop 3 more beats
        SIP->>MEM: HTRANS=SEQ, HADDR=buf_ptr+N, HWDATA=rx_byte[n]
        MEM-->>SIP: HREADYOUT=1, HRESP=OKAY
    end
    SIP->>ARB: deassert HBUSREQ1 (burst done)

    Note over SIP,CPU: 3. SIP raises IRQ (out-of-band, not on AHB)
    SIP-)CPU: uart_irq = 1

    Note over CPU,SIP: 4. CPU polls/reads status (CPU=M, SIP=S)
    CPU->>SIP: HTRANS=NONSEQ, HADDR=STATUS_REG, HWRITE=0
    SIP-->>CPU: HREADYOUT=1, HRDATA=dma_done|rx_count

    Note over CPU,MEM: 5. CPU reads the received data (CPU=M, MEM=S)
    CPU->>MEM: HTRANS=NONSEQ, HADDR=buf_ptr, HWRITE=0
    MEM-->>CPU: HREADYOUT=1, HRDATA=rx_byte[0]
    loop 3 more beats
        CPU->>MEM: HTRANS=SEQ, HADDR=buf_ptr+N
        MEM-->>CPU: HRDATA=rx_byte[n]
    end
```

## Notes

- Steps 1, 4 and 5 are ordinary single/burst AHB transfers with the CPU as Master; step 2 is the SIP's
  internal DMA acting as Master — only one of CPU/SIP can own the bus at a time (see the arbiter FSM in
  [01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md)), so step 4/5 cannot start until step 2's burst finishes.
- The symmetric TX path (CPU writes bytes to memory, SIP-DMA later bursts them out of memory into the TX
  FIFO, UART serializes them) follows the same shape with the HWRITE direction on the DMA burst flipped to
  a read (SIP=M issuing `HWRITE=0` against the Mem Controller).
