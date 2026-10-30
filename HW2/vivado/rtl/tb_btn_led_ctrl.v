// btn_led_ctrl 自我檢查 testbench（IP：ip_repo/btn_led_ctrl_1.0）
// 用 AXI4-Lite 讀寫暫存器、模擬按鈕彈跳，檢查 irq / W1C / mode
// 防彈跳用 defparam 縮成 CLK_HZ = 1000、DEBOUNCE_MS = 20 -> 20 clk；呼吸燈維持 DIV_N = 12207，
// 從 duty 0 走到 duty 1 約 3.03M clk，所以第 5 步會跑比較久
`timescale 1ns/1ps
module tb_btn_led_ctrl;
    localparam CTRL = 4'h0, STATUS = 4'h4, INT_STATUS = 4'h8, INT_ENABLE = 4'hC;

    reg clk = 0, resetn = 0, btn = 0;
    wire led0, irq;

    reg  [3:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    integer errors = 0, i, toggles;
    reg [31:0] rd;
    reg led_prev;

    btn_led_ctrl_v1_0 dut (
        .btn(btn), .led0(led0), .irq(irq),
        .s00_axi_aclk(clk), .s00_axi_aresetn(resetn),
        .s00_axi_awaddr(awaddr), .s00_axi_awprot(3'b000), .s00_axi_awvalid(awvalid), .s00_axi_awready(awready),
        .s00_axi_wdata(wdata), .s00_axi_wstrb(wstrb), .s00_axi_wvalid(wvalid), .s00_axi_wready(wready),
        .s00_axi_bresp(bresp), .s00_axi_bvalid(bvalid), .s00_axi_bready(bready),
        .s00_axi_araddr(araddr), .s00_axi_arprot(3'b000), .s00_axi_arvalid(arvalid), .s00_axi_arready(arready),
        .s00_axi_rdata(rdata), .s00_axi_rresp(rresp), .s00_axi_rvalid(rvalid), .s00_axi_rready(rready)
    );
    defparam dut.btn_led_ctrl_v1_0_S00_AXI_inst.u_btn_debounce.CLK_HZ = 1000;

    always #10 clk = ~clk;

    task axi_write(input [3:0] addr, input [31:0] data, input [3:0] strb);
        reg aw_done, w_done;
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1; wdata = data; wstrb = strb; wvalid = 1; bready = 1;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (awready && awvalid) aw_done = 1;
                if (wready && wvalid)   w_done  = 1;
                #1;
                if (aw_done) awvalid = 0;
                if (w_done)  wvalid  = 0;
            end
            while (!bvalid) @(posedge clk);
            @(posedge clk); #1;
            bready = 0;
            if (bresp !== 2'b00) begin errors = errors + 1; $display("BRESP error @%h", addr); end
        end
    endtask

    task axi_read(input [3:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1; rready = 1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            #1 arvalid = 0;
            while (!rvalid) @(posedge clk);
            data = rdata;
            @(posedge clk); #1;
            rready = 0;
        end
    endtask

    task expect_reg(input [3:0] addr, input [31:0] exp, input [8*16-1:0] what);
        begin
            axi_read(addr, rd);
            if (rd !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: read %h, expect %h", what, rd, exp);
            end
        end
    endtask

    task bouncy(input level);   // 彈跳 5 次後穩定在 level
        integer k;
        begin
            for (k = 0; k < 5; k = k + 1) begin
                btn = level; repeat (3) @(posedge clk);
                btn = ~level; repeat (2) @(posedge clk);
            end
            btn = level;
            repeat (40) @(posedge clk);   // 超過 20 clk 防彈跳 + 同步器
        end
    endtask

    task check_irq(input exp, input [8*16-1:0] what);
        begin
            if (irq !== exp) begin errors = errors + 1; $display("FAIL %0s: irq = %b", what, irq); end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

        // 1. reset 後：mode = 0 恆亮、中斷全關
        expect_reg(CTRL, 0, "reset CTRL");
        expect_reg(INT_ENABLE, 0, "reset INT_EN");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk); #1;
            if (led0 !== 1'b1) begin errors = errors + 1; $display("FAIL fixed: led0 = %b", led0); end
        end

        // 2. 中斷沒開：按下只設 INT_STATUS，irq 不動
        bouncy(1);
        check_irq(0, "masked press");
        expect_reg(STATUS, 1, "STATUS pressed");
        expect_reg(INT_STATUS, 1, "masked pending");
        axi_write(INT_STATUS, 1, 4'h1);
        expect_reg(INT_STATUS, 0, "W1C clear");
        bouncy(0);
        axi_write(INT_STATUS, 1, 4'h1);

        // 3. 開中斷：按下 -> irq = 1，W1C 後 irq = 0；彈跳只算一次
        axi_write(INT_ENABLE, 1, 4'h1);
        expect_reg(INT_ENABLE, 1, "INT_EN set");
        bouncy(1);
        check_irq(1, "press irq");
        expect_reg(STATUS, 1, "STATUS pressed2");
        axi_write(INT_STATUS, 0, 4'h1);   // 寫 0 不清
        check_irq(1, "write 0 keeps");
        axi_write(INT_STATUS, 1, 4'h1);
        check_irq(0, "W1C irq");
        repeat (30) @(posedge clk);
        check_irq(0, "no re-trigger");

        // 4. 放開也會中斷
        bouncy(0);
        check_irq(1, "release irq");
        expect_reg(STATUS, 0, "STATUS released");
        axi_write(INT_STATUS, 1, 4'h1);
        check_irq(0, "W1C release");

        // 5. CPU 寫 CTRL = 1 -> 呼吸：第一個 tick 後 led0 變 0（duty 0），約 3.03M clk 後 duty = 1 開始翻轉
        //    wstrb = 0 的寫入不生效
        axi_write(CTRL, 1, 4'h0);
        expect_reg(CTRL, 0, "wstrb0 ignored");
        axi_write(CTRL, 1, 4'h1);
        expect_reg(CTRL, 1, "CTRL breath");
        toggles = 0; led_prev = led0;
        for (i = 0; i < 3_500_000; i = i + 1) begin
            @(posedge clk); #1;
            if (led0 !== led_prev) toggles = toggles + 1;
            led_prev = led0;
        end
        if (toggles < 2) begin errors = errors + 1; $display("FAIL breath: toggles = %0d", toggles); end

        // 6. 寫回 CTRL = 0 -> 恆亮
        axi_write(CTRL, 0, 4'h1);
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk); #1;
            if (led0 !== 1'b1) begin errors = errors + 1; $display("FAIL back fixed"); i = 50; end
        end

        if (errors == 0) $display("TB PASS (breath toggles = %0d)", toggles);
        else             $display("TB FAIL: %0d errors", errors);
        $finish;
    end
endmodule
