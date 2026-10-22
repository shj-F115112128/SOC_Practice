# HW2 Demo

S6（BTNC）按鈕經過 PL → AXI GPIO 中斷 → GIC（IRQ ID 61）→ ISR 切換 LED0：恆亮 ⇄ 2 秒呼吸燈。

## 上板

1. EGO-XZ7：SW8 全部撥 **ON**（JTAG 開機）、JP1（VADJ）在 **3.3V**、接 JTAG 線、開電源
2. 雙擊 **`demo.bat`**（燒 bitstream → ps7_init → 下載 ELF → 執行）
3. LED0 恆亮 → 按 S6 變呼吸燈 → 再按回恆亮

## 檔案

| 檔案 | 用途 |
|---|---|
| `demo.bat` / `run_on_board.tcl` | 一鍵上板 |
| `system_wrapper.bit` | PL bitstream（btn_debounce + AXI GPIO ×2 + pwm_breath） |
| `ps7_init.tcl` | PS 初始化（DDR、時脈、MIO） |
| `hw2_led_isr.elf` | `sdk/src/main.c` 編出來的程式 |
| `build_elf.bat` | 改完 `sdk/src/main.c` 後重新編譯 ELF，再跑 `demo.bat` |
| `open_vivado.bat` | 開 Vivado 專案看 block design |

## 原始檔位置

| 內容 | 路徑 |
|---|---|
| C 程式 | [`../sdk/src/main.c`](../sdk/src/main.c) |
| PL RTL | [`../vivado/rtl/`](../vivado/rtl/)（`btn_debounce.v`、`pwm_breath.v` + testbench） |
| Block design 腳本 | [`../vivado/create_bd.tcl`](../vivado/create_bd.tcl) |
| 腳位約束 | [`../vivado/constraints/hw2.xdc`](../vivado/constraints/hw2.xdc) |
| Vivado 專案 | `../vivado/build/plbtn/`（由 `create_bd.tcl` 產生，不進 git） |
