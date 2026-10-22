// pwm_breath 自我檢查 testbench：參數縮小（PWM_RES=4、CLK_PER_TICK=2、STEP_PWM_CYCLES=2）
// 讓一個呼吸週期只要 2*4 階 * 2 個 PWM 週期 * 4 tick * 2 clk = 128 clk，方便逐週期核對。
`timescale 1ns/1ps
module tb_pwm_breath;
    localparam RES = 4, CPT = 2, SPC = 2;
    localparam PWM_PERIOD = RES * CPT;            // 8 clk
    localparam STEP_CLK   = PWM_PERIOD * SPC;     // 16 clk
    localparam BREATH_CLK = 2 * RES * STEP_CLK;   // 128 clk

    reg clk = 0, resetn = 0;
    reg [0:0] mode = 0;
    wire led;
    integer errors = 0, i, s, on_cnt, expect_on;

    pwm_breath #(.CLK_HZ(1), .PWM_RES(RES), .CLK_PER_TICK(CPT), .STEP_PWM_CYCLES(SPC))
        dut (.clk(clk), .resetn(resetn), .mode(mode), .led(led));

    always #5 clk = ~clk;

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1;

        // 恆亮模式：連續 50 clk 都要亮
        repeat (2) @(posedge clk);
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk); #1;
            if (led !== 1'b1) begin errors = errors + 1; $display("FIXED: led=%b at %0t", led, $time); end
        end

        // 切到呼吸模式，對齊到 PWM 週期起點後，逐階統計每個 step 的亮燈 clk 數
        @(negedge clk); mode = 1;
        wait (dut.step == 0 && dut.pwm_cnt == 0 && dut.tick_div == 0 && dut.step_div == 0);
        @(posedge clk); #1;  // led 是暫存器輸出，晚一拍
        for (s = 0; s < 2*RES; s = s + 1) begin
            on_cnt = 0;
            for (i = 0; i < STEP_CLK; i = i + 1) begin
                if (led) on_cnt = on_cnt + 1;
                @(posedge clk); #1;
            end
            expect_on = ((s < RES) ? s : (2*RES - 1 - s)) * CPT * SPC;
            $display("step %0d: on=%0d expect=%0d", s, on_cnt, expect_on);
            if (on_cnt != expect_on) errors = errors + 1;
        end

        // 切回恆亮：一拍後要立刻亮
        @(negedge clk); mode = 0;
        @(posedge clk); @(posedge clk); #1;
        if (led !== 1'b1) begin errors = errors + 1; $display("BACK TO FIXED failed"); end

        if (errors == 0) $display("TB PASS (breath period = %0d clk)", BREATH_CLK);
        else             $display("TB FAIL: %0d errors", errors);
        $finish;
    end
endmodule
