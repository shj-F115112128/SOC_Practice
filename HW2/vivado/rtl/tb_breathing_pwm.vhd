library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use std.env.all;

-- breathing_pwm_top 自我檢查 testbench：DIV_N 縮小成 2（每 2 clk 一個 tick_4096），
-- 一次完整呼吸 62 階 * 8 個 PWM 週期 * 31 tick * 2 clk ≈ 30752 clk，不用跑真實的 3.75 秒。
-- 每一階（duty_reg 不變的期間）統計 led_out 的亮燈 clk 數，核對 = duty/31。
entity tb_breathing_pwm is
end tb_breathing_pwm;

architecture sim of tb_breathing_pwm is

    constant DIV_N_TB   : integer := 2;
    constant CLK_PERIOD : time    := 20 ns;    -- 50 MHz，跟 FCLK_CLK0 一樣
    constant PERIOD_CLK : integer := 31 * DIV_N_TB;
    constant STEP_CLK   : integer := 8 * PERIOD_CLK;

    signal clk     : std_logic := '0';
    signal resetn  : std_logic := '0';
    signal mode    : std_logic_vector(0 downto 0) := "0";
    signal led_out : std_logic;

begin

    dut : entity work.breathing_pwm_top
        generic map (DIV_N => DIV_N_TB)
        port map (clk => clk, resetn => resetn, mode => mode, led_out => led_out);

    clk <= not clk after CLK_PERIOD / 2;

    stim : process
        alias duty_reg is <<signal .tb_breathing_pwm.dut.duty_reg : integer range 0 to 31>>;
        variable errors     : integer := 0;
        variable duty, prev : integer;
        variable on_cnt     : integer;
        variable all_cnt    : integer;
        variable going_up   : boolean := true;
        variable steps      : integer := 0;
        variable lost       : integer;
    begin
        for i in 1 to 3 loop wait until rising_edge(clk); end loop;
        resetn <= '1';

        -- 恆亮模式：連續 100 clk 都要亮
        for i in 1 to 100 loop
            wait until rising_edge(clk);
            if led_out /= '1' then errors := errors + 1; end if;
        end loop;

        -- 切到呼吸模式，逐階統計，走完 0 -> 31 -> 0 一整輪
        wait until falling_edge(clk);
        mode <= "1";
        wait until rising_edge(clk);
        prev := duty_reg;
        on_cnt := 0; all_cnt := 0;
        while steps < 62 loop
            wait until falling_edge(clk);
            duty := duty_reg;
            if duty /= prev then
                -- 一階結束：檢查亮燈比例和階長
                -- duty 0 -> 1 那一下 FSM 還用舊的 limit_high = 0 判斷，多停在 ST_LOW，
                -- 這一階少 1 個 tick（硬體上約 0.24 ms）
                if going_up and prev = 1 then
                    lost := DIV_N_TB;
                else
                    lost := 0;
                end if;
                if prev >= 1 and prev <= 30 then
                    if on_cnt /= 8 * prev * DIV_N_TB - lost or all_cnt /= STEP_CLK - lost then
                        report "duty " & integer'image(prev) & ": on=" & integer'image(on_cnt) &
                               " all=" & integer'image(all_cnt) severity error;
                        errors := errors + 1;
                    end if;
                end if;
                report "duty " & integer'image(prev) & ": on=" & integer'image(on_cnt) &
                       " / " & integer'image(all_cnt) & " clk";
                -- 方向：一路加到 31 再一路減到 0
                if going_up then
                    if duty /= prev + 1 then errors := errors + 1; end if;
                    if duty = 31 then going_up := false; end if;
                else
                    if duty /= prev - 1 then errors := errors + 1; end if;
                end if;
                steps := steps + 1;
                prev := duty;
                on_cnt := 0; all_cnt := 0;
            end if;
            if led_out = '1' then on_cnt := on_cnt + 1; end if;
            all_cnt := all_cnt + 1;
        end loop;
        if duty_reg /= 0 then errors := errors + 1; end if;

        -- 呼吸到一半切回恆亮：下一拍就要亮，duty 歸零
        for i in 1 to 10 * STEP_CLK loop wait until rising_edge(clk); end loop;
        wait until falling_edge(clk);
        mode <= "0";
        wait until rising_edge(clk);
        wait until falling_edge(clk);
        if led_out /= '1' or duty_reg /= 0 then
            report "BACK TO FIXED failed" severity error;
            errors := errors + 1;
        end if;

        if errors = 0 then
            report "TB PASS (one breath = 62 steps)";
        else
            report "TB FAIL: " & integer'image(errors) & " errors" severity error;
        end if;
        finish;
    end process;

end architecture;
