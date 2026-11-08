library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use std.env.all;

-- btn_led_ctrl 自我檢查 testbench（IP：ip_repo/btn_led_ctrl_1.0）
-- 用 AXI4-Lite 讀寫暫存器、模擬按鈕彈跳，檢查：
--   五種中斷（按下 / 放開 / 單擊 / 雙擊 / 長按）、各自的 INT_ENABLE、W1C、
--   中斷時 IP 準備給 CPU 的 DATA_OUT / EVENT_CNT / HOLD_MS、SPEED 呼吸速度、BRIGHT 恆亮亮度
-- 直接接 btn_led_ctrl_v1_0_S00_AXI，用 generic 把時間縮小：
--   防彈跳 20 clk、1 ms = 10 clk、長按 100 ms、雙擊間隔 30 ms、亮度 PWM 一格 2 clk
entity tb_btn_led_ctrl is
end tb_btn_led_ctrl;

architecture sim of tb_btn_led_ctrl is

    constant CTRL       : integer := 16#00#;
    constant STATUS     : integer := 16#04#;
    constant INT_STATUS : integer := 16#08#;
    constant INT_ENABLE : integer := 16#0C#;
    constant DATA_IN    : integer := 16#10#;
    constant DATA_OUT   : integer := 16#14#;
    constant EVENT_CNT  : integer := 16#18#;
    constant HOLD_MS    : integer := 16#1C#;
    constant SPEED      : integer := 16#20#;
    constant BRIGHT     : integer := 16#24#;

    constant EV_PRESS   : integer := 1;
    constant EV_RELEASE : integer := 2;
    constant EV_CLICK   : integer := 4;
    constant EV_DOUBLE  : integer := 8;
    constant EV_LONG    : integer := 16;
    constant EV_ALL     : integer := 16#1F#;

    constant MS : integer := 10;    -- 1 ms = 10 clk

    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal btn    : std_logic := '0';
    signal led0   : std_logic;
    signal irq    : std_logic;

    signal awaddr  : std_logic_vector(5 downto 0)  := (others => '0');
    signal araddr  : std_logic_vector(5 downto 0)  := (others => '0');
    signal awvalid : std_logic := '0';
    signal wvalid  : std_logic := '0';
    signal bready  : std_logic := '0';
    signal arvalid : std_logic := '0';
    signal rready  : std_logic := '0';
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0)  := (others => '0');
    signal awready, wready, bvalid, arready, rvalid : std_logic;
    signal bresp, rresp : std_logic_vector(1 downto 0);
    signal rdata : std_logic_vector(31 downto 0);

begin

    dut : entity work.btn_led_ctrl_v1_0_S00_AXI
        generic map (
            MS_CLKS         => MS,
            LONG_MS         => 100,
            DOUBLE_MS       => 30,
            FX_DIV          => 2,
            DEBOUNCE_CLK_HZ => 1000
        )
        port map (
            btn => btn, led0 => led0, irq => irq,
            S_AXI_ACLK => clk, S_AXI_ARESETN => resetn,
            S_AXI_AWADDR => awaddr, S_AXI_AWPROT => "000", S_AXI_AWVALID => awvalid, S_AXI_AWREADY => awready,
            S_AXI_WDATA => wdata, S_AXI_WSTRB => wstrb, S_AXI_WVALID => wvalid, S_AXI_WREADY => wready,
            S_AXI_BRESP => bresp, S_AXI_BVALID => bvalid, S_AXI_BREADY => bready,
            S_AXI_ARADDR => araddr, S_AXI_ARPROT => "000", S_AXI_ARVALID => arvalid, S_AXI_ARREADY => arready,
            S_AXI_RDATA => rdata, S_AXI_RRESP => rresp, S_AXI_RVALID => rvalid, S_AXI_RREADY => rready
        );

    clk <= not clk after 10 ns;

    stim : process
        variable errors  : integer := 0;
        variable toggles : integer := 0;
        variable ones    : integer := 0;
        variable rd      : std_logic_vector(31 downto 0);

        procedure wait_clks(n : integer) is
        begin
            for k in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        procedure fail(msg : string) is
        begin
            errors := errors + 1;
            report "FAIL " & msg;
        end procedure;

        procedure axi_write(addr : integer; data : integer; strb : std_logic_vector(3 downto 0)) is
            variable aw_done : boolean := false;
            variable w_done  : boolean := false;
        begin
            wait until falling_edge(clk);
            awaddr  <= std_logic_vector(to_unsigned(addr, 6));
            awvalid <= '1';
            wdata   <= std_logic_vector(to_unsigned(data, 32));
            wstrb   <= strb;
            wvalid  <= '1';
            bready  <= '1';
            while not (aw_done and w_done) loop
                wait until rising_edge(clk);
                if awready = '1' and awvalid = '1' then aw_done := true; end if;
                if wready = '1' and wvalid = '1' then w_done := true; end if;
                wait for 1 ns;
                if aw_done then awvalid <= '0'; end if;
                if w_done then wvalid <= '0'; end if;
            end loop;
            while bvalid /= '1' loop
                wait until rising_edge(clk);
            end loop;
            wait until rising_edge(clk);
            wait for 1 ns;
            bready <= '0';
            if bresp /= "00" then
                fail("BRESP error @" & integer'image(addr));
            end if;
        end procedure;

        procedure axi_read(addr : integer) is
        begin
            wait until falling_edge(clk);
            araddr  <= std_logic_vector(to_unsigned(addr, 6));
            arvalid <= '1';
            rready  <= '1';
            wait until rising_edge(clk);
            while arready /= '1' loop
                wait until rising_edge(clk);
            end loop;
            wait for 1 ns;
            arvalid <= '0';
            while rvalid /= '1' loop
                wait until rising_edge(clk);
            end loop;
            rd := rdata;
            wait until rising_edge(clk);
            wait for 1 ns;
            rready <= '0';
        end procedure;

        procedure expect_reg(addr : integer; exp : integer; what : string) is
        begin
            axi_read(addr);
            if rd /= std_logic_vector(to_unsigned(exp, 32)) then
                fail(what & ": read 0x" & to_hstring(rd) & ", expect " & integer'image(exp));
            end if;
        end procedure;

        procedure expect_range(addr : integer; lo : integer; hi : integer; what : string) is
        begin
            axi_read(addr);
            if is_x(rd) or unsigned(rd) < lo or unsigned(rd) > hi then
                fail(what & ": read 0x" & to_hstring(rd) & ", expect "
                     & integer'image(lo) & ".." & integer'image(hi));
            end if;
        end procedure;

        procedure check_irq(exp : std_logic; what : string) is
        begin
            if irq /= exp then
                fail(what & ": irq = " & std_logic'image(irq));
            end if;
        end procedure;

        -- 彈跳 5 次後穩定在 level
        procedure bouncy(level : std_logic) is
        begin
            for k in 0 to 4 loop
                btn <= level;
                wait_clks(3);
                btn <= not level;
                wait_clks(2);
            end loop;
            btn <= level;
            wait_clks(40);      -- 超過 20 clk 防彈跳 + 同步器
        end procedure;

        procedure wait_ms(n : integer) is
        begin
            wait_clks(n * MS);
        end procedure;

        -- 按住 hold ms 後放開
        procedure click(hold : integer) is
        begin
            bouncy('1');
            wait_ms(hold);
            bouncy('0');
        end procedure;

        -- n 個 clk 內 led0 的翻轉次數、亮的 clk 數
        procedure count_led(n : integer) is
            variable led_prev : std_logic;
        begin
            toggles  := 0;
            ones     := 0;
            led_prev := led0;
            for k in 1 to n loop
                wait until rising_edge(clk);
                wait for 1 ns;
                if led0 /= led_prev then toggles := toggles + 1; end if;
                if led0 = '1' then ones := ones + 1; end if;
                led_prev := led0;
            end loop;
        end procedure;

    begin
        wait_clks(3);
        resetn <= '1';
        wait_clks(2);

        -- 1. reset 後：恆亮全亮、中斷全關、資料暫存器歸零
        expect_reg(CTRL, 0, "reset CTRL");
        expect_reg(INT_ENABLE, 0, "reset INT_EN");
        expect_reg(DATA_IN, 0, "reset DATA_IN");
        expect_reg(DATA_OUT, 0, "reset DATA_OUT");
        expect_reg(EVENT_CNT, 0, "reset EVENT_CNT");
        expect_reg(HOLD_MS, 0, "reset HOLD_MS");
        expect_reg(SPEED, 0, "reset SPEED");
        expect_reg(BRIGHT, 31, "reset BRIGHT");
        count_led(200);
        if ones /= 200 then fail("fixed full: ones = " & integer'image(ones)); end if;

        -- 2. 中斷全關時單擊：按下、放開、單擊三個 bit 都會 pending，但 irq 不動
        click(20);
        wait_ms(40);
        check_irq('0', "masked click");
        expect_reg(INT_STATUS, EV_PRESS + EV_RELEASE + EV_CLICK, "single click");
        expect_reg(EVENT_CNT, 3, "cnt single");
        expect_reg(DATA_OUT, 3, "out 0+3");
        expect_range(HOLD_MS, 20, 32, "hold single");
        axi_write(INT_STATUS, EV_ALL, "0001");
        expect_reg(INT_STATUS, 0, "W1C all");

        -- 3. CPU 寫 DATA_IN、開全部中斷；雙擊：放開後 30 ms 內再按，只有雙擊沒有單擊
        axi_write(DATA_IN, 1000, "1111");
        expect_reg(DATA_IN, 1000, "DATA_IN rw");
        expect_reg(DATA_OUT, 3, "out held");
        axi_write(DATA_OUT, 16#1234#, "1111");
        expect_reg(DATA_OUT, 3, "out ro");
        axi_write(INT_ENABLE, EV_ALL, "0001");
        click(5);
        check_irq('1', "press irq");
        click(5);
        wait_ms(40);
        expect_reg(INT_STATUS, EV_PRESS + EV_RELEASE + EV_DOUBLE, "double click");
        expect_reg(EVENT_CNT, 7, "cnt double");     -- 3 + 按下、放開、按下、（放開 + 雙擊同一拍）
        expect_reg(DATA_OUT, 1007, "out 1000+7");
        -- W1C 只清寫 1 的 bit；寫 0 不清
        axi_write(INT_STATUS, EV_PRESS, "0001");
        expect_reg(INT_STATUS, EV_RELEASE + EV_DOUBLE, "W1C bit0");
        check_irq('1', "irq still");
        axi_write(INT_STATUS, 0, "0001");
        expect_reg(INT_STATUS, EV_RELEASE + EV_DOUBLE, "write 0 keeps");
        axi_write(INT_STATUS, EV_ALL, "0001");
        check_irq('0', "W1C irq");

        -- 4. 長按：按住超過 100 ms 時就發長按中斷（還沒放開），放開後沒有單擊
        bouncy('1');
        wait_ms(120);
        expect_reg(INT_STATUS, EV_PRESS + EV_LONG, "long held");
        expect_reg(STATUS, 1, "STATUS held");
        check_irq('1', "long irq");
        bouncy('0');
        wait_ms(40);
        expect_reg(INT_STATUS, EV_PRESS + EV_LONG + EV_RELEASE, "long released");
        expect_range(HOLD_MS, 120, 135, "hold long");
        expect_reg(EVENT_CNT, 10, "cnt long");
        expect_reg(DATA_OUT, 1010, "out 1000+10");
        axi_write(INT_STATUS, EV_ALL, "0001");

        -- 5. INT_ENABLE 分開控制：只開單擊，按下、放開不會拉 irq，等到單擊判定才拉
        axi_write(INT_ENABLE, EV_CLICK, "0001");
        click(5);
        check_irq('0', "click masked press");
        wait_ms(40);
        check_irq('1', "click only irq");
        axi_write(INT_STATUS, EV_ALL, "0001");
        check_irq('0', "click W1C");

        -- 6. CTRL = 1 呼吸；SPEED = 3（除頻 1525）約 0.38M clk 就走到 duty 1 開始翻轉
        axi_write(CTRL, 1, "0000");
        expect_reg(CTRL, 0, "wstrb0 ignored");
        axi_write(CTRL, 1, "0001");
        axi_write(SPEED, 3, "0001");
        expect_reg(SPEED, 3, "SPEED rw");
        count_led(450_000);
        if toggles < 2 then fail("breath fast: toggles = " & integer'image(toggles)); end if;

        -- 7. CTRL = 0 恆亮；BRIGHT 改亮度：一個 PWM 週期 31 格 x 2 clk = 62 clk
        axi_write(CTRL, 0, "0001");
        axi_write(BRIGHT, 8, "0001");
        wait_clks(62);
        count_led(620);
        if ones < 158 or ones > 162 then fail("bright 8: ones = " & integer'image(ones)); end if;
        axi_write(BRIGHT, 0, "0001");
        wait_clks(62);
        count_led(620);
        if ones /= 0 then fail("bright 0: ones = " & integer'image(ones)); end if;
        axi_write(BRIGHT, 31, "0001");
        wait_clks(62);
        count_led(620);
        if ones /= 620 then fail("bright 31: ones = " & integer'image(ones)); end if;

        if errors = 0 then
            report "TB PASS";
        else
            report "TB FAIL: " & integer'image(errors) & " errors" severity error;
        end if;
        finish;
    end process;

end sim;
