#!/usr/bin/env bash
# Compile and run all four testbenches with Vivado's xsim (this is the
# simulator used in lab -- Vivado 2018.2 on an EGO-XZ7 board).
# Needs xvhdl/xelab/xsim on PATH (Vivado's settings64.sh / add-on to PATH).
set -euo pipefail
cd "$(dirname "$0")/.."

work=sim/xsim_work
rm -rf "$work"
mkdir -p "$work"
cd "$work"

echo "== AHB UART slave wrapper (register-access only) =="
xvhdl --2008 ../../rtl/ahb_uart_slave_wrapper.vhd ../tb_ahb_uart_slave_wrapper.vhd
xelab tb_ahb_uart_slave_wrapper -s ahb_sim
xsim ahb_sim -R

echo
echo "== AXI-Lite UART slave wrapper (register-access only) =="
xvhdl --2008 ../../rtl/axi_lite_uart_slave_wrapper.vhd ../tb_axi_lite_uart_slave_wrapper.vhd
xelab tb_axi_lite_uart_slave_wrapper -s axi_sim
xsim axi_sim -R

echo
echo "== AHB system MSC (arbiter + slave + master/DMA + mem BFM, phases A-D) =="
xvhdl --2008 ../../rtl/ahb_arbiter.vhd ../../rtl/ahb_mem_slave_bfm.vhd \
             ../../rtl/ahb_uart_slave_wrapper.vhd ../../rtl/ahb_uart_master_wrapper.vhd \
             ../tb_ahb_system_msc.vhd
xelab tb_ahb_system_msc -s ahb_sys_sim
xsim ahb_sys_sim -R

echo
echo "== AXI system MSC (slave + master/DMA + mem BFM, phases A-D) =="
xvhdl --2008 ../../rtl/axi_mem_slave_bfm.vhd ../../rtl/axi_uart_master_wrapper.vhd \
             ../../rtl/axi_lite_uart_slave_wrapper.vhd ../tb_axi_system_msc.vhd
xelab tb_axi_system_msc -s axi_sys_sim
xsim axi_sys_sim -R
