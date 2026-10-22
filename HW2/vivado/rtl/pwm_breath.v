// HW2 - LED0 呼吸燈 PWM（PL 端硬體）
//
// mode = 0：LED 恆亮
// mode = 1：2 秒週期呼吸燈（100 階亮度，三角波：1 秒漸亮 + 1 秒漸暗）
//
// mode 由 PS 透過 AXI GPIO 寫入（S6 按鈕中斷的 ISR 負責切換），跟 AXI GPIO 同一個 FCLK_CLK0
// 時脈域，不需要跨時脈同步。
//
// 預設參數以 CLK_HZ = 50 MHz 計算：
//   PWM 週期   = PWM_RES * CLK_PER_TICK = 100 * 500 clk = 50000 clk = 1 ms（1 kHz，不閃爍）
//   每一階     = 1 個 PWM 週期 * STEP_PWM_CYCLES = 10 ms
//   呼吸週期   = 2 * PWM_RES 階 * 10 ms = 2000 ms

`timescale 1ns/1ps
module pwm_breath #(
    parameter integer CLK_HZ          = 50_000_000,
    parameter integer PWM_RES         = 100,     // 亮度階數
    parameter integer CLK_PER_TICK    = 500,     // 一個 PWM tick 幾個 clk
    parameter integer STEP_PWM_CYCLES = 10       // 每幾個 PWM 週期換下一階亮度
) (
    input  wire       clk,
    input  wire       resetn,
    input  wire [0:0] mode,
    output reg        led
);

    // ---- PWM tick 分頻 ----
    reg [$clog2(CLK_PER_TICK)-1:0] tick_div;
    wire tick = (tick_div == CLK_PER_TICK - 1);

    always @(posedge clk) begin
        if (!resetn || tick) tick_div <= 0;
        else                 tick_div <= tick_div + 1'b1;
    end

    // ---- PWM 計數器：0 .. PWM_RES-1 ----
    reg [$clog2(PWM_RES)-1:0] pwm_cnt;
    wire pwm_wrap = tick && (pwm_cnt == PWM_RES - 1);

    always @(posedge clk) begin
        if (!resetn)       pwm_cnt <= 0;
        else if (pwm_wrap) pwm_cnt <= 0;
        else if (tick)     pwm_cnt <= pwm_cnt + 1'b1;
    end

    // ---- 呼吸進度：每 STEP_PWM_CYCLES 個 PWM 週期走一階，共 2*PWM_RES 階 ----
    reg [$clog2(STEP_PWM_CYCLES)-1:0] step_div;
    reg [$clog2(2*PWM_RES)-1:0]       step;
    wire step_adv = pwm_wrap && (step_div == STEP_PWM_CYCLES - 1);

    always @(posedge clk) begin
        if (!resetn || !mode[0]) begin
            // 恆亮模式時歸零，下次進呼吸模式從暗開始漸亮
            step_div <= 0;
            step     <= 0;
        end else if (pwm_wrap) begin
            if (step_div == STEP_PWM_CYCLES - 1) step_div <= 0;
            else                                 step_div <= step_div + 1'b1;

            if (step_adv) step <= (step == 2*PWM_RES - 1) ? 0 : step + 1'b1;
        end
    end

    // 三角波：0..PWM_RES-1 漸亮，PWM_RES..2*PWM_RES-1 漸暗
    wire [$clog2(2*PWM_RES)-1:0] brightness =
        (step < PWM_RES) ? step : (2*PWM_RES - 1 - step);

    always @(posedge clk) begin
        if (!resetn)       led <= 1'b0;
        else if (!mode[0]) led <= 1'b1;
        else               led <= (pwm_cnt < brightness);
    end

endmodule
