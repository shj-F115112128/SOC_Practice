# Bonus: RTL + Simulation (Part 1 — Slave Wrapper FSMs)

Implements and simulates the **AHB and AXI-Lite slave wrapper FSMs** from
[01-ahb-wrapper-fsm.md](01-ahb-wrapper-fsm.md) and [02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md) for the
UART SIP's register file (CTRL/STATUS/TXDATA/RXDATA), using [Icarus Verilog](http://iverilog.icarus.com/).

## Scope

In scope (implemented + simulated):
- `rtl/ahb_uart_slave_wrapper.v` — AHB-Lite slave wrapper FSM: `IDLE → NONSEQ → {WAIT* →} OKAY → IDLE` and
  `IDLE → NONSEQ → ERR1 → ERR2 → IDLE`, including pipelined back-to-back transfers.
- `rtl/axi_lite_uart_slave_wrapper.v` — AXI4-Lite slave wrapper: independent write (`IDLE → WADDR → WDATA{wait*} → RESP → IDLE`)
  and read (`IDLE → RADDR → RDATA → IDLE`) channel FSMs.

Out of scope (left as the conceptual Mermaid FSMs in docs 01/02, not implemented in RTL): the **master/DMA
wrapper FSMs** and the **AHB arbiter FSM** for multi-master arbitration — those need a second bus-functional
model acting as the memory-side slave to simulate meaningfully, which is a larger undertaking than this
bonus pass covers. The two register-file slave wrappers are the part that's actually testable in isolation
and are the most direct RTL expression of "the wrapper FSM", so they were prioritized.

Both wrappers share one simplified UART register model so their behavior is directly comparable:

| Offset | Reg | Access | Behavior |
|---|---|---|---|
| `0x0` | CTRL | R/W | bit0 = enable |
| `0x4` | STATUS | RO | bit0 = tx_busy, bit1 = rx_ready |
| `0x8` | TXDATA | R/W | write starts a simulated transmission (busy for 4 cycles); a write while busy is back-pressured (AHB: `WAIT`; AXI: `WREADY=0`) |
| `0xC` | RXDATA | RO | reading clears `rx_ready`; a `rx_byte_valid`/`rx_byte_data` testbench backdoor emulates a received byte (RX-FIFO-empty blocking read was simplified to non-blocking — see comments in the RTL) |
| `≥0x10` | — | — | AHB: 2-cycle `HRESP=ERROR`; AXI: `BRESP`/`RRESP = SLVERR` |

## Running it

Requires Icarus Verilog (`winget install Icarus.Verilog`, or `apt install iverilog` on Linux):

```sh
sim/run_sims.sh
```

or manually:

```sh
iverilog -g2005 -o sim/ahb_tb.vvp rtl/ahb_uart_slave_wrapper.v sim/tb_ahb_uart_slave_wrapper.v
vvp sim/ahb_tb.vvp

iverilog -g2005 -o sim/axi_tb.vvp rtl/axi_lite_uart_slave_wrapper.v sim/tb_axi_lite_uart_slave_wrapper.v
vvp sim/axi_tb.vvp
```

Each testbench is self-checking (`$display [PASS]/[FAIL]` per check, `$fatal` on any failure) and dumps a
`.vcd` waveform for viewing in GTKWave if you want to inspect the FSM transitions directly.

## Results

### AHB UART slave wrapper — `sim/tb_ahb_uart_slave_wrapper.v`

Covers: plain OKAY read/write, back-to-back pipelined transfers (`NONSEQ→NONSEQ`), `WAIT` insertion when a
TXDATA write collides with `tx_busy`, the RX-arrival/read path, and the 2-cycle `ERROR` response for an
out-of-range address followed by normal recovery.

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

Covers the same scenarios on AXI, plus the protocol difference the MSC docs call out: an independent
`STATUS` read on the read channel completes **without waiting** for a TXDATA write that's back-pressured on
the write channel (`fork`/`join` issuing both concurrently) — not possible on AHB's single shared bus.

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

Both suites pass (28/28 checks) under Icarus Verilog 12.0.
