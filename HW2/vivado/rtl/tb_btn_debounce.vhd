library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use std.env.all;

-- btn_debounce 自我檢查 testbench：CLK_HZ=1000、DEBOUNCE_MS=8 -> DEBOUNCE_CLKS = 8，
-- 模擬按下 / 放開時的彈跳，檢查 btn_out 每次按壓只變化一次、且在穩定後才變。
entity tb_btn_debounce is
end tb_btn_debounce;

architecture sim of tb_btn_debounce is

    constant DB : integer := 8;     -- DEBOUNCE_CLKS

    signal clk     : std_logic := '0';
    signal resetn  : std_logic := '0';
    signal btn_in  : std_logic := '0';
    signal btn_out : std_logic_vector(0 downto 0);
    signal prev    : std_logic := '0';
    signal edges   : integer := 0;

begin

    dut : entity work.btn_debounce
        generic map (CLK_HZ => 1000, DEBOUNCE_MS => DB)
        port map (clk => clk, resetn => resetn, btn_in => btn_in, btn_out => btn_out);

    clk <= not clk after 5 ns;

    -- 統計 btn_out 的變化次數（reset 前 btn_out 還沒有值，不算）
    process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '1' then
                if btn_out(0) /= prev then
                    edges <= edges + 1;
                end if;
                prev <= btn_out(0);
            else
                prev <= '0';
            end if;
        end if;
    end process;

    stim : process
        variable errors : integer := 0;

        procedure wait_clks(n : integer) is
        begin
            for k in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;

        -- 彈跳：每次維持不到 DB clk 就翻轉
        procedure bounce is
        begin
            for k in 0 to 4 loop
                btn_in <= not btn_in;
                wait_clks(2 + k mod 3);
            end loop;
        end procedure;

        procedure check(exp : std_logic; what : string) is
        begin
            if btn_out(0) /= exp then
                errors := errors + 1;
                report what & ": btn_out=" & std_logic'image(btn_out(0)) & ", expect " & std_logic'image(exp);
            end if;
        end procedure;
    begin
        wait_clks(3);
        resetn <= '1';
        wait_clks(5);

        -- 按下：彈跳 5 次後停在 1（5 次翻轉 = 奇數，最後是 1）
        wait until falling_edge(clk);
        bounce;
        check('0', "PRESS during bounce");
        -- 同步器 2 clk + 防彈跳 DB clk 之後才可以變 1
        wait_clks(DB + 4);
        wait for 1 ns;
        check('1', "PRESS");

        wait_clks(20);

        -- 放開：彈跳後停在 0
        wait until falling_edge(clk);
        bounce;
        check('1', "RELEASE during bounce");
        wait_clks(DB + 4);
        wait for 1 ns;
        check('0', "RELEASE");

        wait_clks(5);
        -- 一次按下 + 一次放開 = btn_out 剛好變化 2 次
        if edges /= 2 then
            errors := errors + 1;
            report "edges=" & integer'image(edges) & ", expect 2";
        end if;

        if errors = 0 then
            report "TB PASS (btn_out edges = " & integer'image(edges) & ")";
        else
            report "TB FAIL: " & integer'image(errors) & " errors" severity error;
        end if;
        finish;
    end process;

end sim;
