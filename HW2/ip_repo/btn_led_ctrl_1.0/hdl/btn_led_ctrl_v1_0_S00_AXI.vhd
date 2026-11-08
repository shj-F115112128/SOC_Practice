library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity btn_led_ctrl_v1_0_S00_AXI is
    generic (
        -- Users to add parameters here
        MS_CLKS         : integer := 50000;       -- 50 MHz 下 1 ms 的 clk 數
        LONG_MS         : integer := 1000;        -- 按住超過這個時間算長按
        DOUBLE_MS       : integer := 300;         -- 放開後這段時間內再按一次算雙擊
        FX_DIV          : integer := 12207;       -- 恆亮模式亮度 PWM 的除頻值（約 132 Hz）
        DEBOUNCE_CLK_HZ : integer := 50_000_000;  -- btn_debounce 的 CLK_HZ
        -- User parameters ends

        -- Width of S_AXI data bus
        C_S_AXI_DATA_WIDTH : integer := 32;
        -- Width of S_AXI address bus
        C_S_AXI_ADDR_WIDTH : integer := 6
    );
    port (
        -- Users to add ports here
        btn  : in  std_logic;    -- S6，按下 = 1
        led0 : out std_logic;    -- LED0
        irq  : out std_logic;    -- 接 IRQ_F2P[0]，level high
        -- User ports ends

        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN : in  std_logic;
        S_AXI_AWADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic;
        S_AXI_ARADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;
        S_AXI_RDATA   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic
    );
end entity;

architecture arch_imp of btn_led_ctrl_v1_0_S00_AXI is

    component btn_debounce is
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
    end component;

    component breathing_pwm_top is
        port (
            clk     : in  std_logic;
            resetn  : in  std_logic;
            mode    : in  std_logic_vector(0 downto 0);
            div_n   : in  std_logic_vector(15 downto 0);
            led_out : out std_logic
        );
    end component;

    subtype data_t is std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);

    -- AXI4LITE signals
    signal axi_awaddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_awready : std_logic;
    signal axi_wready  : std_logic;
    signal axi_bresp   : std_logic_vector(1 downto 0);
    signal axi_bvalid  : std_logic;
    signal axi_araddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    signal axi_arready : std_logic;
    signal axi_rdata   : data_t;
    signal axi_rresp   : std_logic_vector(1 downto 0);
    signal axi_rvalid  : std_logic;

    -- ADDR_LSB = 2 for 32 bits (n downto 2)，ADDR_LSB = 3 for 64 bits (n downto 3)
    constant ADDR_LSB          : integer := (C_S_AXI_DATA_WIDTH/32) + 1;
    constant OPT_MEM_ADDR_BITS : integer := 3;

    -- Number of Slave Registers 16（0x00～0x3C，用到 0x24）
    signal slv_reg0, slv_reg1, slv_reg2, slv_reg3, slv_reg4, slv_reg8, slv_reg9 : data_t;
    signal slv_reg_rden : std_logic;
    signal slv_reg_wren : std_logic;
    signal reg_data_out : data_t;
    signal aw_en        : std_logic;
    signal aw_sel       : std_logic_vector(OPT_MEM_ADDR_BITS downto 0);
    signal ar_sel       : std_logic_vector(OPT_MEM_ADDR_BITS downto 0);

    -- 暫存器（只列有用到的）：
    --   0x00 CTRL       slv_reg0  RW  bit0 mode：0 恆亮、1 呼吸
    --   0x04 STATUS               RO  bit0 防彈跳後的按鈕電位
    --   0x08 INT_STATUS           W1C bit0 按下、bit1 放開、bit2 單擊、bit3 雙擊、bit4 長按
    --   0x0C INT_ENABLE slv_reg3  RW  bit[4:0] 對應 INT_STATUS 每一種中斷的開關
    --   0x10 DATA_IN    slv_reg4  RW  CPU 寫給 IP 的資料
    --   0x14 DATA_OUT             RO  中斷發生時鎖住 DATA_IN + EVENT_CNT
    --   0x18 EVENT_CNT            RO  中斷事件次數
    --   0x1C HOLD_MS              RO  放開時鎖住：這次按住幾 ms
    --   0x20 SPEED      slv_reg8  RW  bit[1:0] 呼吸速度：0 = 3.75 s、1 = 1.9 s、2 = 0.94 s、3 = 0.47 s
    --   0x24 BRIGHT     slv_reg9  RW  bit[4:0] 恆亮模式亮度 0～31，重置值 31
    constant EV_PRESS   : integer := 0;
    constant EV_RELEASE : integer := 1;
    constant EV_CLICK   : integer := 2;
    constant EV_DOUBLE  : integer := 3;
    constant EV_LONG    : integer := 4;

    constant CNT_MAX : integer := 65535;

    signal btn_db     : std_logic_vector(0 downto 0);   -- 防彈跳後的按鈕
    signal btn_d      : std_logic;                      -- 前一拍，用來偵測變化
    signal int_status : std_logic_vector(4 downto 0);   -- INT_STATUS
    signal ev         : std_logic_vector(4 downto 0);   -- 這一拍發生的事件
    signal event_cnt  : data_t;                         -- 中斷事件次數
    signal data_out   : data_t;                         -- 中斷發生時鎖住 DATA_IN + EVENT_CNT
    signal hold_ms    : unsigned(15 downto 0);          -- 最近一次按住的 ms 數

    -- 1 ms 時基
    signal ms_div  : unsigned(15 downto 0);
    signal ms_tick : std_logic;

    -- 手勢判斷
    -- S_IDLE   --按下--> S_PRESS1 --放開--> S_WAIT2 --DOUBLE_MS 內沒再按--> 單擊
    --                      |                   |
    --                  按住 LONG_MS         再按一次
    --                      v                   v
    --                   S_LONG  <--按住 LONG_MS-- S_PRESS2 --放開--> 雙擊
    type gesture_state_t is (S_IDLE, S_PRESS1, S_WAIT2, S_PRESS2, S_LONG);
    signal g_state  : gesture_state_t;
    signal hold_cnt : unsigned(15 downto 0);    -- 按住的 ms 數
    signal gap_cnt  : unsigned(15 downto 0);    -- 放開後的 ms 數
    signal rise     : std_logic;
    signal fall     : std_logic;

    signal wr_int_clr : std_logic_vector(4 downto 0);

    -- LED
    signal fx_div_cnt : unsigned(15 downto 0);
    signal fx_cnt     : unsigned(4 downto 0);
    signal led_breath : std_logic;
    signal led_fixed  : std_logic;
    signal div_n      : std_logic_vector(15 downto 0);

    -- 依 WSTRB 逐 byte 更新暫存器
    function apply_wstrb(cur, wdata, wstrb : std_logic_vector) return std_logic_vector is
        variable result : std_logic_vector(cur'range) := cur;
    begin
        for i in 0 to wstrb'length - 1 loop
            if wstrb(i) = '1' then
                result(i*8+7 downto i*8) := wdata(i*8+7 downto i*8);
            end if;
        end loop;
        return result;
    end function;

begin

    -- I/O Connections assignments
    S_AXI_AWREADY <= axi_awready;
    S_AXI_WREADY  <= axi_wready;
    S_AXI_BRESP   <= axi_bresp;
    S_AXI_BVALID  <= axi_bvalid;
    S_AXI_ARREADY <= axi_arready;
    S_AXI_RDATA   <= axi_rdata;
    S_AXI_RRESP   <= axi_rresp;
    S_AXI_RVALID  <= axi_rvalid;

    aw_sel <= axi_awaddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);
    ar_sel <= axi_araddr(ADDR_LSB + OPT_MEM_ADDR_BITS downto ADDR_LSB);

    -- axi_awready 在 AWVALID、WVALID 都成立時拉高一拍
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_awready <= '0';
                aw_en       <= '1';
            elsif axi_awready = '0' and S_AXI_AWVALID = '1' and S_AXI_WVALID = '1' and aw_en = '1' then
                axi_awready <= '1';
                aw_en       <= '0';
            elsif S_AXI_BREADY = '1' and axi_bvalid = '1' then
                aw_en       <= '1';
                axi_awready <= '0';
            else
                axi_awready <= '0';
            end if;
        end if;
    end process;

    -- AWVALID、WVALID 都成立時鎖住寫入位址
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_awaddr <= (others => '0');
            elsif axi_awready = '0' and S_AXI_AWVALID = '1' and S_AXI_WVALID = '1' and aw_en = '1' then
                axi_awaddr <= S_AXI_AWADDR;
            end if;
        end if;
    end process;

    -- axi_wready 在 AWVALID、WVALID 都成立時拉高一拍
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_wready <= '0';
            elsif axi_wready = '0' and S_AXI_WVALID = '1' and S_AXI_AWVALID = '1' and aw_en = '1' then
                axi_wready <= '1';
            else
                axi_wready <= '0';
            end if;
        end if;
    end process;

    -- 暫存器寫入：位址、資料都被接受時，依 WSTRB 更新
    slv_reg_wren <= axi_wready and S_AXI_WVALID and axi_awready and S_AXI_AWVALID;

    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                slv_reg0 <= (others => '0');
                slv_reg1 <= (others => '0');
                slv_reg2 <= (others => '0');
                slv_reg3 <= (others => '0');
                slv_reg4 <= (others => '0');
                slv_reg8 <= (others => '0');
                slv_reg9 <= std_logic_vector(to_unsigned(31, C_S_AXI_DATA_WIDTH));
            elsif slv_reg_wren = '1' then
                case aw_sel is
                    when x"0"   => slv_reg0 <= apply_wstrb(slv_reg0, S_AXI_WDATA, S_AXI_WSTRB);
                    when x"1"   => slv_reg1 <= apply_wstrb(slv_reg1, S_AXI_WDATA, S_AXI_WSTRB);
                    when x"2"   => slv_reg2 <= apply_wstrb(slv_reg2, S_AXI_WDATA, S_AXI_WSTRB);
                    when x"3"   => slv_reg3 <= apply_wstrb(slv_reg3, S_AXI_WDATA, S_AXI_WSTRB);
                    when x"4"   => slv_reg4 <= apply_wstrb(slv_reg4, S_AXI_WDATA, S_AXI_WSTRB);  -- DATA_IN
                    when x"8"   => slv_reg8 <= apply_wstrb(slv_reg8, S_AXI_WDATA, S_AXI_WSTRB);  -- SPEED
                    when x"9"   => slv_reg9 <= apply_wstrb(slv_reg9, S_AXI_WDATA, S_AXI_WSTRB);  -- BRIGHT
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- 寫入回應
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_bvalid <= '0';
                axi_bresp  <= "00";
            elsif axi_awready = '1' and S_AXI_AWVALID = '1' and axi_bvalid = '0'
                  and axi_wready = '1' and S_AXI_WVALID = '1' then
                axi_bvalid <= '1';
                axi_bresp  <= "00";     -- OKAY
            elsif S_AXI_BREADY = '1' and axi_bvalid = '1' then
                axi_bvalid <= '0';
            end if;
        end if;
    end process;

    -- axi_arready 拉高一拍，同時鎖住讀取位址
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_arready <= '0';
                axi_araddr  <= (others => '0');
            elsif axi_arready = '0' and S_AXI_ARVALID = '1' then
                axi_arready <= '1';
                axi_araddr  <= S_AXI_ARADDR;
            else
                axi_arready <= '0';
            end if;
        end if;
    end process;

    -- 讀取回應
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_rvalid <= '0';
                axi_rresp  <= "00";
            elsif axi_arready = '1' and S_AXI_ARVALID = '1' and axi_rvalid = '0' then
                axi_rvalid <= '1';
                axi_rresp  <= "00";     -- OKAY
            elsif axi_rvalid = '1' and S_AXI_RREADY = '1' then
                axi_rvalid <= '0';
            end if;
        end if;
    end process;

    -- 暫存器讀取位址解碼
    slv_reg_rden <= axi_arready and S_AXI_ARVALID and (not axi_rvalid);

    process (ar_sel, slv_reg0, slv_reg3, slv_reg4, slv_reg8, slv_reg9,
             btn_db, int_status, data_out, event_cnt, hold_ms)
    begin
        case ar_sel is
            when x"0"   => reg_data_out <= slv_reg0;                                                      -- CTRL
            when x"1"   => reg_data_out <= std_logic_vector(resize(unsigned(btn_db), C_S_AXI_DATA_WIDTH));     -- STATUS
            when x"2"   => reg_data_out <= std_logic_vector(resize(unsigned(int_status), C_S_AXI_DATA_WIDTH)); -- INT_STATUS
            when x"3"   => reg_data_out <= slv_reg3;                                                      -- INT_ENABLE
            when x"4"   => reg_data_out <= slv_reg4;                                                      -- DATA_IN
            when x"5"   => reg_data_out <= data_out;                                                      -- DATA_OUT
            when x"6"   => reg_data_out <= event_cnt;                                                     -- EVENT_CNT
            when x"7"   => reg_data_out <= std_logic_vector(resize(hold_ms, C_S_AXI_DATA_WIDTH));         -- HOLD_MS
            when x"8"   => reg_data_out <= slv_reg8;                                                      -- SPEED
            when x"9"   => reg_data_out <= slv_reg9;                                                      -- BRIGHT
            when others => reg_data_out <= (others => '0');
        end case;
    end process;

    -- 讀取資料輸出暫存器
    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                axi_rdata <= (others => '0');
            elsif slv_reg_rden = '1' then
                axi_rdata <= reg_data_out;
            end if;
        end if;
    end process;

    -- ---------------- 1 ms 時基 ----------------
    ms_tick <= '1' when ms_div = MS_CLKS - 1 else '0';

    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' or ms_tick = '1' then
                ms_div <= (others => '0');
            else
                ms_div <= ms_div + 1;
            end if;
        end if;
    end process;

    -- ---------------- 手勢判斷 ----------------
    rise <= btn_db(0) and (not btn_d);
    fall <= (not btn_db(0)) and btn_d;

    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                btn_d    <= '0';
                g_state  <= S_IDLE;
                hold_cnt <= (others => '0');
                gap_cnt  <= (others => '0');
                hold_ms  <= (others => '0');
                ev       <= (others => '0');
            else
                btn_d <= btn_db(0);
                ev    <= (EV_PRESS => rise, EV_RELEASE => fall, others => '0');

                if btn_db(0) = '1' and ms_tick = '1' and hold_cnt /= CNT_MAX then
                    hold_cnt <= hold_cnt + 1;
                end if;
                if btn_db(0) = '0' and ms_tick = '1' and gap_cnt /= CNT_MAX then
                    gap_cnt <= gap_cnt + 1;
                end if;
                if rise = '1' then
                    hold_cnt <= (others => '0');
                end if;
                if fall = '1' then
                    gap_cnt <= (others => '0');
                    hold_ms <= hold_cnt;
                end if;

                case g_state is
                    when S_IDLE =>
                        if rise = '1' then
                            g_state <= S_PRESS1;
                        end if;
                    when S_PRESS1 =>
                        if fall = '1' then
                            g_state <= S_WAIT2;
                        elsif hold_cnt >= LONG_MS then
                            g_state     <= S_LONG;
                            ev(EV_LONG) <= '1';
                        end if;
                    when S_WAIT2 =>
                        if rise = '1' then
                            g_state <= S_PRESS2;
                        elsif gap_cnt >= DOUBLE_MS then
                            g_state      <= S_IDLE;
                            ev(EV_CLICK) <= '1';
                        end if;
                    when S_PRESS2 =>
                        if fall = '1' then
                            g_state       <= S_IDLE;
                            ev(EV_DOUBLE) <= '1';
                        elsif hold_cnt >= LONG_MS then
                            g_state     <= S_LONG;
                            ev(EV_LONG) <= '1';
                        end if;
                    when S_LONG =>
                        if fall = '1' then
                            g_state <= S_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- ---------------- 中斷 ----------------
    -- 事件發生就設對應的 bit；CPU 對 0x08 寫 1 清除（W1C，可一次清多個 bit），同一拍兩者都發生時以設定為準
    wr_int_clr <= S_AXI_WDATA(4 downto 0)
                  when slv_reg_wren = '1' and aw_sel = x"2" and S_AXI_WSTRB(0) = '1'
                  else (others => '0');

    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                int_status <= (others => '0');
                event_cnt  <= (others => '0');
                data_out   <= (others => '0');
            else
                int_status <= (int_status and (not wr_int_clr)) or ev;
                if ev /= "00000" then
                    -- 中斷發生的同一拍準備好要給 CPU 的資料，ISR 再經 AXI 讀 DATA_OUT
                    event_cnt <= std_logic_vector(unsigned(event_cnt) + 1);
                    data_out  <= std_logic_vector(unsigned(slv_reg4) + unsigned(event_cnt) + 1);
                end if;
            end if;
        end if;
    end process;

    -- 有任何一種開著的中斷就送給 CPU；INT_STATUS 清掉前一直是 High
    irq <= '0' when (int_status and slv_reg3(4 downto 0)) = "00000" else '1';

    -- ---------------- LED ----------------
    -- 恆亮模式的亮度 PWM：一個週期 31 格，前 BRIGHT 格亮；BRIGHT = 31 就是全亮
    led_fixed <= '1' when fx_cnt < unsigned(slv_reg9(4 downto 0)) else '0';

    process (S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                fx_div_cnt <= (others => '0');
                fx_cnt <= (others => '0');
            elsif fx_div_cnt = FX_DIV - 1 then
                fx_div_cnt <= (others => '0');
                if fx_cnt = 30 then
                    fx_cnt <= (others => '0');
                else
                    fx_cnt <= fx_cnt + 1;
                end if;
            else
                fx_div_cnt <= fx_div_cnt + 1;
            end if;
        end if;
    end process;

    led0 <= led_breath when slv_reg0(0) = '1' else led_fixed;

    u_btn_debounce : btn_debounce
        generic map (
            CLK_HZ      => DEBOUNCE_CLK_HZ,
            DEBOUNCE_MS => 20
        )
        port map (
            clk     => S_AXI_ACLK,
            resetn  => S_AXI_ARESETN,
            btn_in  => btn,
            btn_out => btn_db
        );

    -- SPEED 0～3：除頻值 12207 右移 SPEED 位，呼吸週期 3.75 s / 1.9 s / 0.94 s / 0.47 s
    div_n <= std_logic_vector(shift_right(to_unsigned(12207, 16), to_integer(unsigned(slv_reg8(1 downto 0)))));

    u_breathing_pwm : breathing_pwm_top
        port map (
            clk     => S_AXI_ACLK,
            resetn  => S_AXI_ARESETN,
            mode    => slv_reg0(0 downto 0),    -- CTRL bit0
            div_n   => div_n,
            led_out => led_breath
        );

end arch_imp;
