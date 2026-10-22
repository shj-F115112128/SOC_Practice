// HW2 - S6 (BTNC) 按鈕同步 + 防彈跳（PL 端硬體）
//
// btn_in  ：板上 PL 按鈕（P16），按下 = 1（EGO-XZ7 PL 按鈕為 active-high）
// btn_out ：防彈跳後的穩定電位，接 AXI GPIO (axi_gpio_btn) 的 gpio_io_i
//
// AXI GPIO 開了 interrupt 之後，輸入只要「變化」就會在 IPISR 記一筆、拉 ip2intc_irpt，
// 所以按下、放開各會產生一次中斷；這裡負責把機械彈跳濾掉，確保一次按壓只有一次乾淨的
// 0->1、一次乾淨的 1->0，CPU 端 ISR 不用再自己做軟體防彈跳。
//
// 預設參數以 CLK_HZ = 50 MHz（FCLK_CLK0）計算：
//   DEBOUNCE_MS = 20 -> 輸入要連續 1,000,000 clk 維持同一電位才採用

`timescale 1ns/1ps
module btn_debounce #(
    parameter integer CLK_HZ      = 50_000_000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire       btn_in,
    output reg  [0:0] btn_out
);

    localparam integer DEBOUNCE_CLKS = CLK_HZ / 1000 * DEBOUNCE_MS;

    // ---- 2 級同步器：btn_in 是非同步外部訊號 ----
    (* ASYNC_REG = "TRUE" *) reg sync_0, sync_1;

    always @(posedge clk) begin
        if (!resetn) begin
            sync_0 <= 1'b0;
            sync_1 <= 1'b0;
        end else begin
            sync_0 <= btn_in;
            sync_1 <= sync_0;
        end
    end

    // ---- 防彈跳：跟目前輸出不同的電位要連續維持 DEBOUNCE_CLKS 才採用 ----
    reg [$clog2(DEBOUNCE_CLKS+1)-1:0] cnt;

    always @(posedge clk) begin
        if (!resetn) begin
            cnt     <= 0;
            btn_out <= 1'b0;
        end else if (sync_1 == btn_out[0]) begin
            cnt <= 0;
        end else if (cnt == DEBOUNCE_CLKS - 1) begin
            cnt     <= 0;
            btn_out <= sync_1;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

endmodule
