# SoC Practice — AMBA AHB/AXI Wrapper FSM + MSC

Reference solution for the AMBA SoC course assignment (due 10/15):

1. Draw the **AXI and AHB Master/Slave wrapper finite-state machines** for a freely-chosen SIP (here: a
   UART, in the style of the cores on [opencores.org](https://opencores.org/)), supporting multiple
   masters and multiple slaves.
2. Draw the **Message Sequence Chart (MSC)** for `CPU (Master)` / `Mem Controller (Slave)` /
   `SIP (Master+Slave, with internal DMA)`, for both AHB and AXI.

> Bonus (RTL code + simulation for part 1) is out of scope for this pass — see
> [Possible next steps](#possible-next-steps).

## Contents

| Doc | Covers |
|---|---|
| [docs/01-ahb-wrapper-fsm.md](docs/01-ahb-wrapper-fsm.md) | AHB slave wrapper FSM (UART regs), AHB master wrapper FSM (DMA), arbiter FSM for multi-master |
| [docs/02-axi-wrapper-fsm.md](docs/02-axi-wrapper-fsm.md) | AXI slave wrapper FSMs (write/read channel), AXI master wrapper FSMs (DMA write/read), multi-master/slave interconnect note |
| [docs/03-msc-ahb.md](docs/03-msc-ahb.md) | MSC: CPU configures UART → UART DMA bursts RX data to memory → CPU reads status + data, over AHB |
| [docs/04-msc-axi.md](docs/04-msc-axi.md) | Same scenario over AXI's 5 channels, highlighting outstanding/concurrent transactions |

All diagrams are [Mermaid](https://mermaid.js.org/) (`stateDiagram-v2` / `sequenceDiagram`) embedded in
Markdown — they render natively on GitHub, no external tooling needed.

## Design choices

- **SIP = UART** with an internal DMA engine, matching the whiteboard example (`ex. UART`) and the
  assignment's `SIP(M+S, 內有DMA)` requirement.
- State names in the AHB FSMs (`IDLE/NONSEQ/SEQ/BUSY/WAIT/ERR1/ERR2`) follow the generic AHB
  Manager/Subordinate FSM convention from the AHB protocol spec (`IHI0033C`) covered earlier in the
  course, specialized here to an actual peripheral wrapper rather than the abstract protocol.
- AXI wrapper FSMs are split per channel (write: AW/W/B, read: AR/R) since those channels are
  independent — this is also why the AXI MSC can overlap the CPU's status read with the DMA's write burst,
  while the AHB MSC cannot (single shared bus, one arbiter grant at a time).

## References

- AMBA AHB protocol spec — `IHI0033C_amba_ahb_protocol_spec.pdf` (course materials, parent folder)
- AMBA AXI protocol spec — `IHI0022L_amba_axi_protocol_spec.pdf` / `AMBAaxi.pdf` (course materials, parent folder)
- [opencores.org](https://opencores.org/) — open-source IP cores, incl. UART wrappers for AHB/AXI/Zynq-style buses

## Possible next steps

- Bonus: implement the AHB UART slave wrapper (part 1) in Verilog/RTL and simulate it against a simple
  testbench (e.g. Icarus Verilog + cocotb or a plain self-checking testbench) to verify the FSM transitions
  above.
