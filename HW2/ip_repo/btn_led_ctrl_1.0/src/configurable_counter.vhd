library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 呼吸燈的高/低電位計數器：en = 1 時每個 ce 加一，數到 limit 送出 done
entity configurable_counter is
    port (
        clk   : in  std_logic;
        rst   : in  std_logic;
        ce    : in  std_logic;                -- clock enable，約 4096 Hz 的單一 clk 脈衝
        en    : in  std_logic;
        limit : in  integer range 0 to 31;    -- 上限最大為 31
        done  : out std_logic
    );
end entity;

architecture Behavioral of configurable_counter is
    signal count : integer range 0 to 31 := 0;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                count <= 0;
            elsif ce = '1' then
                if en = '1' then
                    if limit = 0 or count >= limit - 1 then
                        count <= 0;
                    else
                        count <= count + 1;
                    end if;
                else
                    count <= 0;
                end if;
            end if;
        end if;
    end process;

    done <= '1' when (en = '1' and (limit = 0 or count = limit - 1)) else '0';
end architecture;
