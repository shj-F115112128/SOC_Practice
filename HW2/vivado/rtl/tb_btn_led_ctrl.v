// btn_led_ctrl 自我檢查 testbench（IP：ip_repo/btn_led_ctrl_1.0）
// 用 AXI4-Lite 讀寫暫存器、模擬按鈕彈跳，檢查：
//   五種中斷（按下 / 放開 / 單擊 / 雙擊 / 長按）、各自的 INT_ENABLE、W1C、
//   中斷時 IP 準備給 CPU 的 DATA_OUT / EVENT_CNT / HOLD_MS、SPEED 呼吸速度、BRIGHT 恆亮亮度
// 用 defparam 把時間縮小：防彈跳 20 clk、1 ms = 10 clk、長按 100 ms、雙擊間隔 30 ms、亮度 PWM 一格 2 clk
`timescale 1ns/1ps
module tb_btn_led_ctrl;
    localparam CTRL = 6'h00, STATUS = 6'h04, INT_STATUS = 6'h08, INT_ENABLE = 6'h0C,
               DATA_IN = 6'h10, DATA_OUT = 6'h14, EVENT_CNT = 6'h18, HOLD_MS = 6'h1C,
               SPEED = 6'h20, BRIGHT = 6'h24;
    localparam EV_PRESS = 1, EV_RELEASE = 2, EV_CLICK = 4, EV_DOUBLE = 8, EV_LONG = 16;
    localparam MS = 10;     // 1 ms = 10 clk

    reg clk = 0, resetn = 0, btn = 0;
    wire led0, irq;

    reg  [5:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    integer errors = 0, i, toggles, ones;
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
    defparam dut.btn_led_ctrl_v1_0_S00_AXI_inst.MS_CLKS   = MS;
    defparam dut.btn_led_ctrl_v1_0_S00_AXI_inst.LONG_MS   = 100;
    defparam dut.btn_led_ctrl_v1_0_S00_AXI_inst.DOUBLE_MS = 30;
    defparam dut.btn_led_ctrl_v1_0_S00_AXI_inst.FX_DIV    = 2;

    always #10 clk = ~clk;

    task axi_write(input [5:0] addr, input [31:0] data, input [3:0] strb);
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

    task axi_read(input [5:0] addr, output [31:0] data);
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

    task expect_reg(input [5:0] addr, input [31:0] exp, input [8*16-1:0] what);
        begin
            axi_read(addr, rd);
            if (rd !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s: read %0d (0x%h), expect %0d (0x%h)", what, rd, rd, exp, exp);
            end
        end
    endtask

    task expect_range(input [5:0] addr, input [31:0] lo, input [31:0] hi, input [8*16-1:0] what);
        begin
            axi_read(addr, rd);
            if (rd < lo || rd > hi) begin
                errors = errors + 1;
                $display("FAIL %0s: read %0d, expect %0d..%0d", what, rd, lo, hi);
            end
        end
    endtask

    task check_irq(input exp, input [8*16-1:0] what);
        begin
            if (irq !== exp) begin errors = errors + 1; $display("FAIL %0s: irq = %b", what, irq); end
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

    task wait_ms(input integer n);
        begin
            repeat (n * MS) @(posedge clk);
        end
    endtask

    task click(input integer hold);   // 按住 hold ms 後放開
        begin
            bouncy(1);
            wait_ms(hold);
            bouncy(0);
        end
    endtask

    task count_led(input integer n);   // n 個 clk 內 led0 的翻轉次數、亮的 clk 數
        begin
            toggles = 0; ones = 0; led_prev = led0;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk); #1;
                if (led0 !== led_prev) toggles = toggles + 1;
                if (led0 === 1'b1) ones = ones + 1;
                led_prev = led0;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        resetn = 1;
        repeat (2) @(posedge clk);

        // 1. reset 後：恆亮全亮、中斷全關、資料暫存器歸零
        expect_reg(CTRL, 0, "reset CTRL");
        expect_reg(INT_ENABLE, 0, "reset INT_EN");
        expect_reg(DATA_IN, 0, "reset DATA_IN");
        expect_reg(DATA_OUT, 0, "reset DATA_OUT");
        expect_reg(EVENT_CNT, 0, "reset EVENT_CNT");
        expect_reg(HOLD_MS, 0, "reset HOLD_MS");
        expect_reg(SPEED, 0, "reset SPEED");
        expect_reg(BRIGHT, 31, "reset BRIGHT");
        count_led(200);
        if (ones != 200) begin errors = errors + 1; $display("FAIL fixed full: ones = %0d", ones); end

        // 2. 中斷全關時單擊：按下、放開、單擊三個 bit 都會 pending，但 irq 不動
        click(20);
        wait_ms(40);
        check_irq(0, "masked click");
        expect_reg(INT_STATUS, EV_PRESS | EV_RELEASE | EV_CLICK, "single click");
        expect_reg(EVENT_CNT, 3, "cnt single");
        expect_reg(DATA_OUT, 3, "out 0+3");
        expect_range(HOLD_MS, 20, 32, "hold single");
        axi_write(INT_STATUS, 5'h1F, 4'h1);
        expect_reg(INT_STATUS, 0, "W1C all");

        // 3. CPU 寫 DATA_IN、開全部中斷；雙擊：放開後 30 ms 內再按，只有雙擊沒有單擊
        axi_write(DATA_IN, 1000, 4'hF);
        expect_reg(DATA_IN, 1000, "DATA_IN rw");
        expect_reg(DATA_OUT, 3, "out held");
        axi_write(DATA_OUT, 32'h1234, 4'hF);
        expect_reg(DATA_OUT, 3, "out ro");
        axi_write(INT_ENABLE, 5'h1F, 4'h1);
        click(5);
        check_irq(1, "press irq");
        click(5);
        wait_ms(40);
        expect_reg(INT_STATUS, EV_PRESS | EV_RELEASE | EV_DOUBLE, "double click");
        expect_reg(EVENT_CNT, 7, "cnt double");    // 3 + 按下、放開、按下、（放開 + 雙擊同一拍）
        expect_reg(DATA_OUT, 1007, "out 1000+7");
        // W1C 只清寫 1 的 bit；寫 0 不清
        axi_write(INT_STATUS, EV_PRESS, 4'h1);
        expect_reg(INT_STATUS, EV_RELEASE | EV_DOUBLE, "W1C bit0");
        check_irq(1, "irq still");
        axi_write(INT_STATUS, 0, 4'h1);
        expect_reg(INT_STATUS, EV_RELEASE | EV_DOUBLE, "write 0 keeps");
        axi_write(INT_STATUS, 5'h1F, 4'h1);
        check_irq(0, "W1C irq");

        // 4. 長按：按住超過 100 ms 時就發長按中斷（還沒放開），放開後沒有單擊
        bouncy(1);
        wait_ms(120);
        expect_reg(INT_STATUS, EV_PRESS | EV_LONG, "long held");
        expect_reg(STATUS, 1, "STATUS held");
        check_irq(1, "long irq");
        bouncy(0);
        wait_ms(40);
        expect_reg(INT_STATUS, EV_PRESS | EV_LONG | EV_RELEASE, "long released");
        expect_range(HOLD_MS, 120, 135, "hold long");
        expect_reg(EVENT_CNT, 10, "cnt long");
        expect_reg(DATA_OUT, 1010, "out 1000+10");
        axi_write(INT_STATUS, 5'h1F, 4'h1);

        // 5. INT_ENABLE 分開控制：只開單擊，按下、放開不會拉 irq，等到單擊判定才拉
        axi_write(INT_ENABLE, EV_CLICK, 4'h1);
        click(5);
        check_irq(0, "click masked press");
        wait_ms(40);
        check_irq(1, "click only irq");
        axi_write(INT_STATUS, 5'h1F, 4'h1);
        check_irq(0, "click W1C");

        // 6. CTRL = 1 呼吸；SPEED = 3（除頻 1525）約 0.38M clk 就走到 duty 1 開始翻轉
        axi_write(CTRL, 1, 4'h0);
        expect_reg(CTRL, 0, "wstrb0 ignored");
        axi_write(CTRL, 1, 4'h1);
        axi_write(SPEED, 3, 4'h1);
        expect_reg(SPEED, 3, "SPEED rw");
        count_led(450_000);
        if (toggles < 2) begin errors = errors + 1; $display("FAIL breath fast: toggles = %0d", toggles); end

        // 7. CTRL = 0 恆亮；BRIGHT 改亮度：一個 PWM 週期 31 格 x 2 clk = 62 clk
        axi_write(CTRL, 0, 4'h1);
        axi_write(BRIGHT, 8, 4'h1);
        repeat (62) @(posedge clk);
        count_led(620);
        if (ones < 158 || ones > 162) begin errors = errors + 1; $display("FAIL bright 8: ones = %0d", ones); end
        axi_write(BRIGHT, 0, 4'h1);
        repeat (62) @(posedge clk);
        count_led(620);
        if (ones != 0) begin errors = errors + 1; $display("FAIL bright 0: ones = %0d", ones); end
        axi_write(BRIGHT, 31, 4'h1);
        repeat (62) @(posedge clk);
        count_led(620);
        if (ones != 620) begin errors = errors + 1; $display("FAIL bright 31: ones = %0d", ones); end

        if (errors == 0) $display("TB PASS");
        else             $display("TB FAIL: %0d errors", errors);
        $finish;
    end
endmodule
