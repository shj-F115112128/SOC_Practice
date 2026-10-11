#!/usr/bin/env bash
# Compile and run both slave-wrapper testbenches with Icarus Verilog.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== AHB UART slave wrapper =="
iverilog -g2005 -o sim/ahb_tb.vvp rtl/ahb_uart_slave_wrapper.v sim/tb_ahb_uart_slave_wrapper.v
vvp sim/ahb_tb.vvp

echo
echo "== AXI-Lite UART slave wrapper =="
iverilog -g2005 -o sim/axi_tb.vvp rtl/axi_lite_uart_slave_wrapper.v sim/tb_axi_lite_uart_slave_wrapper.v
vvp sim/axi_tb.vvp
