#!/usr/bin/env bash
# Compile and run both slave-wrapper testbenches with GHDL.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== AHB UART slave wrapper =="
ghdl -a --std=08 rtl/ahb_uart_slave_wrapper.vhd sim/tb_ahb_uart_slave_wrapper.vhd
ghdl -e --std=08 tb_ahb_uart_slave_wrapper
ghdl -r --std=08 tb_ahb_uart_slave_wrapper --vcd=sim/ahb_uart_slave_wrapper.vcd

echo
echo "== AXI-Lite UART slave wrapper =="
ghdl -a --std=08 rtl/axi_lite_uart_slave_wrapper.vhd sim/tb_axi_lite_uart_slave_wrapper.vhd
ghdl -e --std=08 tb_axi_lite_uart_slave_wrapper
ghdl -r --std=08 tb_axi_lite_uart_slave_wrapper --vcd=sim/axi_lite_uart_slave_wrapper.vcd
