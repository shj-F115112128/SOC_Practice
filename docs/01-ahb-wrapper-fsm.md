# AHB Master / Slave Wrapper FSM — UART SIP

Selected IP (SIP): a UART core (e.g. [opencores.org `uart16550`](https://opencores.org/projects/uart16550) /
similar FIFO-based UART), wrapped to sit on an AHB bus. The UART has:

- A **register file** (control, status, baud divisor, TX data, RX data) → accessed as an **AHB slave**.
- An internal **DMA engine** that bursts received bytes out to memory, and fetches bytes to transmit,
  without CPU intervention → acts as an **AHB master** when it owns the bus.

Because the system has multiple masters (CPU + the UART's DMA) and multiple slaves (memory controller +
UART register slave, at minimum), a central **arbiter** and **address decoder** sit between them, per the
AHB spec's multi-layer/shared-bus topology.

## System topology

```mermaid
flowchart LR
    CPU["CPU (Master 0)"] --> ARB
    DMA["SIP-DMA (Master 1)\ninside UART wrapper"] --> ARB
    ARB["Arbiter + Address Mux\n(HMASTER select)"] --> BUS["AHB Bus"]
    BUS --> DEC["Address Decoder"]
    DEC --> MEM["Mem Controller (Slave 0)"]
    DEC --> UARTREG["UART Reg File (Slave 1)"]
```

## 1. AHB Slave Wrapper FSM (UART register file)

Controls `HREADYOUT`/`HRESP` while exposing the UART's control/status/TX/RX registers. State names follow
the same convention used for the generic AHB Subordinate FSM (see `project-ahb-fsm-design`): address phase
is `NONSEQ`/`SEQ`, data phase inserts `WAIT` while the register isn't ready (e.g. RX FIFO empty on a read,
or TX FIFO full on a write), and bad accesses get a two-cycle `ERROR`.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> NONSEQ: HSEL & HREADY & HTRANS=NONSEQ
    NONSEQ --> NONSEQ: HSEL & HREADY & HTRANS=NONSEQ (back-to-back single xfers)
    NONSEQ --> OKAY: addr valid & reg ready\n(HREADYOUT=1, drive HRDATA / latch HWDATA)
    NONSEQ --> WAIT: addr valid & reg busy\n(HREADYOUT=0)
    NONSEQ --> ERR1: addr invalid or illegal write\n(HREADYOUT=0,HRESP=ERROR)
    WAIT --> WAIT: reg still busy (RX FIFO empty / TX FIFO full)
    WAIT --> OKAY: reg ready (HREADYOUT=1,HRESP=OKAY)
    WAIT --> ERR1: timeout / illegal
    OKAY --> IDLE: HTRANS=IDLE next
    OKAY --> NONSEQ: next transfer pipelined
    ERR1 --> ERR2: HREADYOUT=0,HRESP=ERROR (2nd cycle)
    ERR2 --> IDLE: HREADYOUT=1
```

## 2. AHB Master Wrapper FSM (UART-internal DMA)

Triggered by the UART's FIFO thresholds (RX half-full → write burst to memory; TX below threshold → read
burst from memory). Must request the bus from the arbiter before driving any address phase.

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> REQ: RX threshold hit / TX needs refill\n(assert HBUSREQx)
    REQ --> REQ: HGRANTx=0 (still arbitrating)
    REQ --> NONSEQ: HGRANTx=1 & HREADY\n(drive HADDR, HTRANS=NONSEQ, HBURST=INCRx)
    NONSEQ --> SEQ: HREADY=1 (first beat accepted)
    SEQ --> SEQ: HREADY=1 & beats remaining\n(HTRANS=SEQ)
    SEQ --> BUSY: HREADY=1 but DMA FIFO not ready for next beat\n(HTRANS=BUSY, holds address)
    BUSY --> SEQ: FIFO ready again
    SEQ --> DONE: HREADY=1 & last beat
    SEQ --> ERR1: HRESP=ERROR\n(abort burst)
    ERR1 --> ERR2: 2nd error cycle
    ERR2 --> IDLE: set UART error status bit, release HBUSREQx
    DONE --> IDLE: release HBUSREQx, set UART done/IRQ status bit
```

## 3. Arbiter FSM (multi-master support)

Minimal fixed-priority arbiter (CPU > DMA); round-robin is a drop-in variant. Per AHB rules, the grant can
only change at a transfer boundary (`HREADY=1` and not mid-`SEQ` burst, i.e. `HBURST`/`HTRANS` indicate the
last beat or master deasserts request).

```mermaid
stateDiagram-v2
    [*] --> GRANT_NONE
    GRANT_NONE --> GRANT_CPU: HBUSREQ0 & HREADY
    GRANT_NONE --> GRANT_DMA: !HBUSREQ0 & HBUSREQ1 & HREADY
    GRANT_CPU --> GRANT_CPU: HBUSREQ0 (holds, even if DMA also requests — higher priority)
    GRANT_CPU --> GRANT_DMA: !HBUSREQ0 & HBUSREQ1 & HREADY & burst boundary
    GRANT_CPU --> GRANT_NONE: !HBUSREQ0 & !HBUSREQ1 & HREADY
    GRANT_DMA --> GRANT_DMA: HBUSREQ1 & mid-burst (HBURST != SINGLE, not last beat)
    GRANT_DMA --> GRANT_CPU: HBUSREQ0 & HREADY & burst boundary\n(DMA preempted at next safe point)
    GRANT_DMA --> GRANT_NONE: !HBUSREQ0 & !HBUSREQ1 & HREADY
```

## Multi-slave note

The decoder maps `HADDR` ranges to `HSELx`; only the module above (the UART slave wrapper) changes per
SIP — the memory controller slave and decoder/mux-back logic are standard AHB infrastructure and are not
redrawn here.
