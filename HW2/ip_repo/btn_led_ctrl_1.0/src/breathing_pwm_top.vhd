library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- HW2 LED0 呼吸燈（btn_led_ctrl IP 版）：mode = 0 恆亮，mode = 1 呼吸
-- 跟 vivado/rtl/breathing_pwm_top.vhd 的差別：除頻值 DIV_N 從 generic 改成 div_n 輸入，
-- CPU 寫 SPEED 暫存器就能即時改呼吸速度。
-- 全部邏輯都跑在 FCLK_CLK0（50 MHz），用每 div_n 個 clk 一次的 tick_4096 當 clock enable。
-- div_n = 12207：50 MHz / 12207 ≈ 4096.0 Hz；PWM 一個週期 31 tick（約 132 Hz），每 8 個 PWM 週期 duty 加/減 1，
-- 0 -> 31 -> 0 共 62 階，呼吸一次約 3.75 秒；div_n 減半，週期也減半。
entity breathing_pwm_top is
    port (
        clk     : in  std_logic;                       -- FCLK_CLK0，50 MHz
        resetn  : in  std_logic;                       -- S_AXI_ARESETN
        mode    : in  std_logic_vector(0 downto 0);    -- CTRL bit0
        div_n   : in  std_logic_vector(15 downto 0);   -- 除頻值，12207 = 3.75 秒
        led_out : out std_logic                        -- LED0（T22）
    );
end entity;

architecture Behavioral of breathing_pwm_top is

    component configurable_counter is
        port (
            clk   : in  std_logic;
            rst   : in  std_logic;
            ce    : in  std_logic;
            en    : in  std_logic;
            limit : in  integer range 0 to 31;
            done  : out std_logic
        );
    end component;

    type state_type is (ST_HIGH, ST_LOW);
    signal current_state, next_state : state_type;

    signal duty_reg     : integer range 0 to 31 := 0;
    signal my_direction : std_logic := '1';
    signal cnt_8_cycles : integer range 0 to 7 := 0;

    signal en_high, done_high : std_logic;
    signal en_low,  done_low  : std_logic;
    signal limit_high, limit_low : integer range 0 to 31;

    signal rst : std_logic;
    signal clr : std_logic;    -- reset 或恆亮模式：呼吸電路全部停在初始狀態

    -- ===== 50 MHz -> 約 4096 Hz 的 clock enable =====
    signal div_cnt   : integer range 0 to 65535 := 0;
    signal div_max   : integer range 0 to 65535;
    signal tick_4096 : std_logic;

begin

    rst <= not resetn;
    clr <= rst or not mode(0);

    div_max <= to_integer(unsigned(div_n)) - 1 when unsigned(div_n) /= 0 else 0;

    -- 用 >= 而不是 =：CPU 把 div_n 改小時，div_cnt 已經超過新上限也能馬上歸零
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or div_cnt >= div_max then
                div_cnt <= 0;
            else
                div_cnt <= div_cnt + 1;
            end if;
        end if;
    end process;

    tick_4096 <= '1' when div_cnt >= div_max else '0';

    -- 動態分配上限
    limit_high <= duty_reg;
    limit_low  <= 31 - duty_reg;

    u_counter_HIGH : configurable_counter
        port map (
            clk   => clk,
            rst   => clr,
            ce    => tick_4096,
            en    => en_high,
            limit => limit_high,
            done  => done_high
        );

    u_counter_LOW : configurable_counter
        port map (
            clk   => clk,
            rst   => clr,
            ce    => tick_4096,
            en    => en_low,
            limit => limit_low,
            done  => done_low
        );

    -- FSM 狀態暫存器
    process(clk)
    begin
        if rising_edge(clk) then
            if clr = '1' then
                current_state <= ST_HIGH;
            elsif tick_4096 = '1' then
                current_state <= next_state;
            end if;
        end if;
    end process;

    process(current_state, done_high, done_low, limit_high, limit_low)
    begin
        next_state <= current_state;
        en_high    <= '0';
        en_low     <= '0';

        case current_state is
            when ST_HIGH =>
                en_high <= '1';
                if done_high = '1' then
                    if limit_low = 0 then
                        next_state <= ST_HIGH;
                    else
                        next_state <= ST_LOW;
                    end if;
                end if;

            when ST_LOW =>
                en_low  <= '1';
                if done_low = '1' then
                    if limit_high = 0 then
                        next_state <= ST_LOW;
                    else
                        next_state <= ST_HIGH;
                    end if;
                end if;
        end case;
    end process;

    -- mode = 0 恆亮；mode = 1 高狀態輸出 1，低狀態輸出 0
    led_out <= '1' when (mode(0) = '0' or current_state = ST_HIGH) else '0';

    -- 亮度調變步進控制；恆亮模式時歸零，下次進呼吸模式從暗開始漸亮
    process(clk)
    begin
        if rising_edge(clk) then
            if clr = '1' then
                duty_reg     <= 0;
                my_direction <= '1';
                cnt_8_cycles <= 0;
            elsif tick_4096 = '1' then

                if (current_state = ST_LOW and done_low = '1') or
                   (current_state = ST_HIGH and done_high = '1' and limit_low = 0) then

                    if cnt_8_cycles = 7 then
                        cnt_8_cycles <= 0;

                        if my_direction = '1' then
                            if duty_reg = 31 then
                                my_direction <= '0';
                                duty_reg     <= 30;
                            else
                                duty_reg     <= duty_reg + 1;
                            end if;
                        else
                            if duty_reg = 0 then
                                my_direction <= '1';
                                duty_reg     <= 1;
                            else
                                duty_reg     <= duty_reg - 1;
                            end if;
                        end if;
                    else
                        cnt_8_cycles <= cnt_8_cycles + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture;
