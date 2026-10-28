// HW2 S6 按鈕同步 + 防彈跳
// btn_in 接 P16（按下 = 1），btn_out 接 axi_gpio_btn 的 gpio_io_i
// 50 MHz 下 20ms = 1000000 clk

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
