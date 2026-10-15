-- Minimal AXI4-Lite memory slave used as the DMA write-burst's target /
-- CPU's read-back target for the system-level AXI MSC testbench (sim-only
-- BFM, same role as rtl/ahb_mem_slave_bfm.vhd -- see docs/02-axi-wrapper-fsm.md
-- "多 Master / 多 Slave 補充說明"). Write/read FSMs mirror
-- axi_lite_uart_slave_wrapper's channel FSMs exactly, minus the register
-- busy/wait-state behavior (always ready), and OKAY-only response.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_mem_slave_bfm is
    generic (
        ADDR_BITS : natural := 10  -- 1K words
    );
    port (
        aclk    : in std_logic;
        aresetn : in std_logic;

        awvalid : in  std_logic;
        awaddr  : in  std_logic_vector(31 downto 0);
        awready : out std_logic;
        wvalid  : in  std_logic;
        wdata   : in  std_logic_vector(31 downto 0);
        wready  : out std_logic;
        bvalid  : out std_logic;
        bresp   : out std_logic_vector(1 downto 0);
        bready  : in  std_logic;

        arvalid : in  std_logic;
        araddr  : in  std_logic_vector(31 downto 0);
        arready : out std_logic;
        rvalid  : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        rresp   : out std_logic_vector(1 downto 0);
        rready  : in  std_logic
    );
end entity axi_mem_slave_bfm;

architecture bfm of axi_mem_slave_bfm is

    constant RESP_OKAY : std_logic_vector(1 downto 0) := "00";

    type wstate_t is (WS_IDLE, WS_WDATA, WS_RESP);
    type rstate_t is (RS_IDLE, RS_DATA);
    signal wstate, wnext : wstate_t;
    signal rstate, rnext : rstate_t;

    signal awaddr_q : std_logic_vector(31 downto 0);
    signal araddr_q : std_logic_vector(31 downto 0);

    signal awready_i, wready_i, bvalid_i : std_logic;
    signal arready_i, rvalid_i           : std_logic;

    type ram_t is array (0 to 2**ADDR_BITS - 1) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));

begin

    -- ---------------- write address + data + response ----------------
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            wstate   <= WS_IDLE;
            awaddr_q <= (others => '0');
        elsif rising_edge(aclk) then
            wstate <= wnext;
            if wstate = WS_IDLE and awvalid = '1' and awready_i = '1' then
                awaddr_q <= awaddr;
            end if;
            if wstate = WS_WDATA and wvalid = '1' and wready_i = '1' then
                ram(to_integer(unsigned(awaddr_q(ADDR_BITS + 1 downto 2)))) <= wdata;
            end if;
        end if;
    end process;

    process (wstate, awvalid, wvalid, bready)
    begin
        wnext     <= wstate;
        awready_i <= '0';
        wready_i  <= '0';
        bvalid_i  <= '0';
        case wstate is
            when WS_IDLE =>
                awready_i <= '1';
                if awvalid = '1' then
                    wnext <= WS_WDATA;
                end if;
            when WS_WDATA =>
                wready_i <= '1';
                if wvalid = '1' then
                    wnext <= WS_RESP;
                end if;
            when WS_RESP =>
                bvalid_i <= '1';
                if bready = '1' then
                    wnext <= WS_IDLE;
                end if;
        end case;
    end process;

    awready <= awready_i;
    wready  <= wready_i;
    bvalid  <= bvalid_i;
    bresp   <= RESP_OKAY;

    -- ---------------- read address + data ----------------
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            rstate   <= RS_IDLE;
            araddr_q <= (others => '0');
        elsif rising_edge(aclk) then
            rstate <= rnext;
            if rstate = RS_IDLE and arvalid = '1' and arready_i = '1' then
                araddr_q <= araddr;
            end if;
        end if;
    end process;

    process (rstate, arvalid, rready)
    begin
        rnext     <= rstate;
        arready_i <= '0';
        rvalid_i  <= '0';
        case rstate is
            when RS_IDLE =>
                arready_i <= '1';
                if arvalid = '1' then
                    rnext <= RS_DATA;
                end if;
            when RS_DATA =>
                rvalid_i <= '1';
                if rready = '1' then
                    rnext <= RS_IDLE;
                end if;
        end case;
    end process;

    arready <= arready_i;
    rvalid  <= rvalid_i;
    rresp   <= RESP_OKAY;
    rdata   <= ram(to_integer(unsigned(araddr_q(ADDR_BITS + 1 downto 2))));

end architecture bfm;
