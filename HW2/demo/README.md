# HW2 Demo

S6（BTNC）按鈕經過 PL → 中斷 → GIC（IRQ ID 61）→ ISR 切換 LED0：恆亮 ⇄ 約 3.75 秒呼吸燈。
兩個版本：`demo.bat` = 版本一（AXI GPIO + 自寫 RTL），`demo_ip.bat` = 版本二（自製 IP `btn_led_ctrl`）。

## 上板

1. EGO-XZ7：SW8 全部撥 **ON**（JTAG 開機）、JP1（VADJ）在 **3.3V**、接 JTAG 線、開電源
2. 雙擊 **`demo.bat`** 或 **`demo_ip.bat`**（燒 bitstream → ps7_init → 下載 ELF → 執行）
3. LED0 恆亮 → 按 S6 變呼吸燈 → 再按回恆亮
4. 另外跳出的 JTAG UART 視窗會印 `IRQ 61 #n: S6 pressed/released, mode = ...`

## 檔案

| 檔案 | 用途 |
|---|---|
| `demo.bat` / `demo_ip.bat` / `run_on_board.tcl` | 一鍵上板（`demo_ip.bat` 讀 `ip/` 裡的檔案） |
| `system_wrapper.bit` | PL bitstream（btn_debounce + AXI GPIO ×2 + breathing_pwm_top） |
| `ps7_init.tcl` | PS 初始化（DDR、時脈、MIO） |
| `hw2_led_isr.elf` | `sdk/src/main.c` 編出來的程式 |
| `build_elf.bat` | 改完 `sdk/src/main.c` 後重新編譯 ELF，再跑 `demo.bat` |
| `open_vivado.bat` | 開 Vivado 專案看 block design |
| `ip/` | 版本二的 `system_wrapper.bit`（PS + `btn_led_ctrl`）、`ps7_init.tcl`、`hw2_ip_wrapper.elf`（`sdk/src_ip/main.c` 編出來的） |

## 原始檔位置

| 內容 | 路徑 |
|---|---|
| C 程式 | [`../sdk/src/main.c`](../sdk/src/main.c)（版本一）、[`../sdk/src_ip/main.c`](../sdk/src_ip/main.c)（版本二） |
| PL RTL | [`../vivado/rtl/`](../vivado/rtl/)（`btn_debounce.v`、`breathing_pwm_top.vhd`、`configurable_counter.vhd` + testbench） |
| 自製 IP | [`../ip_repo/btn_led_ctrl_1.0/`](../ip_repo/btn_led_ctrl_1.0/) |
| Block design 腳本 | [`../vivado/create_bd.tcl`](../vivado/create_bd.tcl)（版本一）、[`../vivado/create_bd_ip.tcl`](../vivado/create_bd_ip.tcl)（版本二） |
| 腳位約束 | [`../vivado/constraints/hw2.xdc`](../vivado/constraints/hw2.xdc) |
| Vivado 專案 | `../vivado/build/plbtn/`（由 `create_bd.tcl` 產生，不進 git） |
