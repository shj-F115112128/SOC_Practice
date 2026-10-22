// btn_debounce 自我檢查 testbench：CLK_HZ=1000、DEBOUNCE_MS=8 -> DEBOUNCE_CLKS = 8，
// 模擬按下 / 放開時的彈跳，檢查 btn_out 每次按壓只變化一次、且在穩定後才變。
`timescale 1ns/1ps
module tb_btn_debounce;
    localparam DB = 8;                 // DEBOUNCE_CLKS

    reg clk = 0, resetn = 0, btn_in = 0;
    wire [0:0] btn_out;
    integer errors = 0, edges = 0, i;
    reg prev = 0;

    btn_debounce #(.CLK_HZ(1000), .DEBOUNCE_MS(DB)) dut
        (.clk(clk), .resetn(resetn), .btn_in(btn_in), .btn_out(btn_out));

    always #5 clk = ~clk;

    // 統計 btn_out 的變化次數（reset 前 btn_out 是 X，不算）
    always @(posedge clk) begin
        if (resetn && btn_out[0] !== prev) edges = edges + 1;
        prev <= resetn ? btn_out[0] : 1'b0;
    end

    // 彈跳：每次維持不到 DB clk 就翻轉
    task bounce;
        integer k;
        begin
            for (k = 0; k < 5; k = k + 1) begin
                btn_in = ~btn_in;
                repeat (2 + k % 3) @(posedge clk);
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1;
        repeat (5) @(posedge clk);

        // 按下：彈跳 5 次後停在 1（5 次翻轉 = 奇數，最後是 1）
        @(negedge clk); bounce;
        if (btn_out !== 1'b0) begin errors = errors + 1; $display("PRESS: changed during bounce"); end
        // 同步器 2 clk + 防彈跳 DB clk 之後才可以變 1
        for (i = 0; i < DB + 4; i = i + 1) @(posedge clk);
        #1;
        if (btn_out !== 1'b1) begin errors = errors + 1; $display("PRESS: btn_out=%b, expect 1", btn_out); end

        repeat (20) @(posedge clk);

        // 放開：彈跳後停在 0
        @(negedge clk); bounce;
        if (btn_out !== 1'b1) begin errors = errors + 1; $display("RELEASE: changed during bounce"); end
        for (i = 0; i < DB + 4; i = i + 1) @(posedge clk);
        #1;
        if (btn_out !== 1'b0) begin errors = errors + 1; $display("RELEASE: btn_out=%b, expect 0", btn_out); end

        repeat (5) @(posedge clk);
        // 一次按下 + 一次放開 = btn_out 剛好變化 2 次
        if (edges != 2) begin errors = errors + 1; $display("edges=%0d, expect 2", edges); end

        if (errors == 0) $display("TB PASS (btn_out edges = %0d)", edges);
        else             $display("TB FAIL: %0d errors", errors);
        $finish;
    end
endmodule
