# Message Sequence Chart — AXI

與 [03-msc-ahb.md](03-msc-ahb.md) 相同的情境與參與者 — **CPU (M)**、**Mem Controller (S)**、
**SIP = UART (M+S，含 DMA)** — 改用 AXI channel 重畫。因為 write（AW/W/B）跟 read（AR/R）channel
彼此獨立，AXI 版不需要像 AHB 版那樣畫一個獨立的仲裁角色，也不用等 write burst 完全結束才能讀
狀態。

![MSC - AXI](../Upload/image/axi_msc.drawio.png)
🔍 [看大圖](https://raw.githubusercontent.com/shj-F115112128/SOC_Practice/main/Upload/image/axi_msc.drawio.png) ／
原始檔：[Upload/axi_msc.drawio](../Upload/axi_msc.drawio)

## 四個階段

- **A. CPU 設定 SIP**：CPU 透過 AW/W 寫入封包起始/結束位址與 CSR 啟動位元，SIP 以 `BRESP=OKAY`
  回應。
- **B. SIP-DMA 寫入記憶體**：收到資料後，SIP 以 `AWID=1` 發出 write burst，把資料搬進記憶體的
  收 buffer。
- **C. 中斷＋CPU 讀狀態**：SIP 發出中斷，CPU 用 `ARID=0` 的 read channel 讀 STATUS — 這一步可以
  跟階段 B 還在進行的 write channel **同時發生**，靠 `AWID`/`ARID` 區分讀寫回應，這是 AHB 單一
  共享匯流排做不到的。
- **D. CPU 讀取資料**：CPU 再用 read channel 把記憶體裡的資料 burst 讀回。

對稱的 TX 路徑（CPU 寫資料進記憶體，SIP-DMA 再用它的 read-DMA FSM 把資料讀出送出）跟階段 B 形狀
相同，只是方向相反，這裡沒有另外畫一張圖。channel FSM 細節見
[02-axi-wrapper-fsm.md](02-axi-wrapper-fsm.md)。
