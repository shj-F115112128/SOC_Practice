# AXI Master / Slave Wrapper FSM — UART SIP

Same UART SIP as the AHB version (see [01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md)), now wrapped onto
AXI. Unlike AHB's single shared address/data bus, AXI has 5 independent channels (AW, W, B, AR, R), so the
wrapper is naturally split into an independent **write FSM** and **read FSM** on both the master and slave
side — they can run concurrently.

## System topology

```mermaid
flowchart LR
    CPU["CPU (Master 0)"] --> XBAR
    DMA["SIP-DMA (Master 1)\ninside UART wrapper"] --> XBAR
    XBAR["AXI Interconnect\n(per-channel arbitration, ID-tagged)"] --> MEM["Mem Controller (Slave 0)"]
    XBAR --> UARTREG["UART Reg File (Slave 1)"]
```

## 1. AXI Slave Wrapper FSM (UART register file)

### Write path (AW + W + B)

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> WADDR: AWVALID\n(assert AWREADY, latch AWADDR)
    WADDR --> WDATA: AWREADY&AWVALID handshake done
    WDATA --> WDATA: WVALID & !reg_ready\n(WREADY=0, e.g. TX FIFO full)
    WDATA --> WRITE_REG: WVALID & reg_ready\n(WREADY=1, apply WSTRB byte lanes, write reg)
    WRITE_REG --> RESP: latch BRESP=OKAY (or SLVERR if addr/WSTRB illegal)
    RESP --> IDLE: BVALID & BREADY handshake
```

### Read path (AR + R)

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> RADDR: ARVALID\n(assert ARREADY, latch ARADDR)
    RADDR --> READ_WAIT: ARREADY&ARVALID handshake done
    READ_WAIT --> READ_WAIT: !reg_ready (RX FIFO empty)
    READ_WAIT --> RDATA: reg_ready\n(drive RDATA, RRESP=OKAY, RVALID=1)
    RDATA --> IDLE: RVALID & RREADY handshake (RLAST=1, single-beat register read)
```

## 2. AXI Master Wrapper FSM (UART-internal DMA)

Write and read DMA paths are independent state machines — the DMA engine can have a read burst (TX
refill) and a write burst (RX flush) outstanding at the same time, something the AHB master wrapper
cannot do.

### Write path (RX FIFO → memory)

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> AW: RX threshold hit\n(assert AWVALID, AWADDR, AWLEN=burst-1, AWBURST=INCR)
    AW --> W: AWVALID&AWREADY handshake
    W --> W: WVALID&WREADY & !WLAST (more beats)
    W --> BWAIT: WVALID&WREADY & WLAST
    BWAIT --> IDLE: BVALID&BREADY\n(BRESP=OKAY: clear RX flag; SLVERR: set error status)
```

### Read path (memory → TX FIFO)

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> AR: TX FIFO below threshold\n(assert ARVALID, ARADDR, ARLEN=burst-1, ARBURST=INCR)
    AR --> R: ARVALID&ARREADY handshake
    R --> R: RVALID&RREADY & !RLAST (more beats, push into TX FIFO)
    R --> IDLE: RVALID&RREADY & RLAST\n(RRESP checked per beat; SLVERR aborts remaining push)
```

## Multi-master / multi-slave note

AXI has no single central arbiter FSM like AHB's `HGRANT` logic. Each slave's **AW** and **AR** channels
independently arbitrate between requesting masters at the interconnect (ID-tagged so responses route back
to the correct master, and so multiple masters/slaves can have transactions outstanding concurrently). The
slave-side FSMs above are per-slave-port and are reused for the memory controller's AXI slave as well,
just with no register-busy wait states.
