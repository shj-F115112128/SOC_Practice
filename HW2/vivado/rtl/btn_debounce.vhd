library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- HW2 S6 按鈕同步 + 防彈跳
-- btn_in 接 P16（按下 = 1），btn_out 接 axi_gpio_btn 的 gpio_io_i
-- 50 MHz 下 20ms = 1000000 clk
entity btn_debounce is
    generic (
        CLK_HZ      : integer := 50_000_000;
        DEBOUNCE_MS : integer := 20
    );
    port (
        clk     : in  std_logic;
        resetn  : in  std_logic;
        btn_in  : in  std_logic;
        btn_out : out std_logic_vector(0 downto 0)
    );
end entity;

architecture Behavioral of btn_debounce is

    constant DEBOUNCE_CLKS : integer := CLK_HZ / 1000 * DEBOUNCE_MS;

    -- 2 級同步器：btn_in 是非同步外部訊號
    signal sync_0, sync_1 : std_logic;
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync_0 : signal is "TRUE";
    attribute ASYNC_REG of sync_1 : signal is "TRUE";

    signal cnt       : integer range 0 to DEBOUNCE_CLKS;
    signal btn_state : std_logic;

begin

    btn_out(0) <= btn_state;

    process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                sync_0 <= '0';
                sync_1 <= '0';
            else
                sync_0 <= btn_in;
                sync_1 <= sync_0;
            end if;
        end if;
    end process;

    -- 防彈跳：跟目前輸出不同的電位要連續維持 DEBOUNCE_CLKS 才採用
    process (clk)
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                cnt       <= 0;
                btn_state <= '0';
            elsif sync_1 = btn_state then
                cnt <= 0;
            elsif cnt = DEBOUNCE_CLKS - 1 then
                cnt       <= 0;
                btn_state <= sync_1;
            else
                cnt <= cnt + 1;
            end if;
        end if;
    end process;

end Behavioral;
