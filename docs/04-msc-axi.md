# Message Sequence Chart — AXI

Same scenario and participants as [03-msc-ahb.md](03-msc-ahb.md) — **CPU (M)**, **Mem Controller (S)**,
**SIP = UART (M+S, w/ DMA)** — redrawn over AXI's 5 channels (AW/W/B write, AR/R read). The key behavioral
difference from AHB: write and read channels are independent, so the CPU's status/data read (steps 4–5)
does **not** have to wait for the SIP-DMA's write burst (step 2) to fully retire — both can be outstanding
at once, tagged by `AWID`/`ARID`.

```mermaid
sequenceDiagram
    participant CPU as CPU (M)
    participant XBAR as Interconnect
    participant SIP as SIP / UART (M+S)
    participant MEM as Mem Controller (S)

    Note over CPU,SIP: 1. CPU configures UART (CPU=M, SIP=S)
    CPU->>SIP: AWVALID, AWADDR=CTRL_REG
    SIP-->>CPU: AWREADY
    CPU->>SIP: WVALID, WDATA=enable|dma_thresh, WSTRB
    SIP-->>CPU: WREADY
    SIP-->>CPU: BVALID, BRESP=OKAY
    CPU->>SIP: BREADY

    Note over SIP: UART receives serial bytes, RX FIFO fills to threshold
    Note over SIP,MEM: 2. SIP-DMA bursts RX data to memory (SIP=M, MEM=S), AWID=1
    SIP->>XBAR: AWVALID, AWADDR=buf_ptr, AWLEN=3, AWBURST=INCR, AWID=1
    XBAR->>MEM: forward AW
    MEM-->>SIP: AWREADY
    loop 4 beats
        SIP->>MEM: WVALID, WDATA=rx_byte[n], WLAST(on beat 4)
        MEM-->>SIP: WREADY
    end
    MEM-->>SIP: BVALID, BRESP=OKAY, BID=1
    SIP->>MEM: BREADY

    Note over SIP,CPU: 3. SIP raises IRQ (out-of-band, not on AXI)
    SIP-)CPU: uart_irq = 1

    par can overlap with step 2's B response
        Note over CPU,SIP: 4. CPU reads status (CPU=M, SIP=S), ARID=0
        CPU->>SIP: ARVALID, ARADDR=STATUS_REG, ARID=0
        SIP-->>CPU: ARREADY
        SIP-->>CPU: RVALID, RDATA=dma_done|rx_count, RLAST=1, RID=0
        CPU->>SIP: RREADY
    end

    Note over CPU,MEM: 5. CPU reads received data (CPU=M, MEM=S), ARID=0
    CPU->>XBAR: ARVALID, ARADDR=buf_ptr, ARLEN=3, ARBURST=INCR
    XBAR->>MEM: forward AR
    MEM-->>CPU: ARREADY
    loop 4 beats
        MEM-->>CPU: RVALID, RDATA=rx_byte[n], RLAST(on beat 4)
        CPU->>MEM: RREADY
    end
```

## Notes

- Step 4 is drawn in a `par` block to highlight that it can be issued on the AR/R channel while step 2's
  write burst is still finishing on AW/W/B — not possible on the single shared AHB bus.
- `AWID`/`ARID` tagging lets the Mem Controller and interconnect route responses back to the right master
  even if multiple bursts from CPU and SIP are outstanding simultaneously; see the per-channel FSMs in
  [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md).
- The symmetric TX path (CPU writes bytes to memory, SIP-DMA bursts them from memory into the TX FIFO via
  its AR/R master path, UART serializes them out) mirrors step 2 using the SIP's read-DMA FSM instead.
