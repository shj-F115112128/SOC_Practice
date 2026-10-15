-- Minimal AHB-Lite memory slave used only as the DMA burst's target /
-- CPU's optional read-back target for the system-level MSC testbenches
-- (sim-only BFM, not meant to represent a real synthesizable memory
-- controller -- see docs/01-ahb-wrapper-fsm.md "多 Slave 補充說明").
--
-- Zero-wait-state, OKAY-only, word-addressed. Address is latched on the
-- cycle the transfer is requested; HRDATA is driven combinationally from
-- that latched address the following cycle (same effective one-cycle
-- data-phase delay as ahb_uart_slave_wrapper, but as a plain read -- no
-- harm in it tracking a stale address when idle). Writes commit through a
-- one-shot `pending` gate instead: unlike a read, re-committing a write
-- against whatever unrelated HWDATA is on the shared bus after the real
-- transfer has ended would silently corrupt memory, so that path must not
-- fire on a stale latch.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ahb_mem_slave_bfm is
    generic (
        ADDR_BITS : natural := 10  -- 1K words
    );
    port (
        hclk    : in  std_logic;
        hresetn : in  std_logic;

        hsel    : in  std_logic;
        haddr   : in  std_logic_vector(31 downto 0);
        htrans  : in  std_logic_vector(1 downto 0);
        hwrite  : in  std_logic;
        hwdata  : in  std_logic_vector(31 downto 0);
        hready  : in  std_logic;

        hreadyout : out std_logic;
        hresp     : out std_logic_vector(1 downto 0);
        hrdata    : out std_logic_vector(31 downto 0)
    );
end entity ahb_mem_slave_bfm;

architecture bfm of ahb_mem_slave_bfm is

    constant HTRANS_NONSEQ : std_logic_vector(1 downto 0) := "10";
    constant HTRANS_SEQ    : std_logic_vector(1 downto 0) := "11";
    constant RESP_OKAY     : std_logic_vector(1 downto 0) := "00";

    type ram_t is array (0 to 2**ADDR_BITS - 1) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    signal addr_q    : std_logic_vector(31 downto 0);
    signal write_q   : std_logic;
    signal pending   : std_logic := '0';
    signal xfer_requested : std_logic;

begin

    xfer_requested <= '1' when (hsel = '1' and hready = '1' and
                                 (htrans = HTRANS_NONSEQ or htrans = HTRANS_SEQ))
                       else '0';

    hreadyout <= '1';
    hresp     <= RESP_OKAY;
    hrdata    <= ram(to_integer(unsigned(addr_q(ADDR_BITS + 1 downto 2))));

    process (hclk, hresetn)
        variable widx : natural range 0 to 2**ADDR_BITS - 1;
    begin
        if hresetn = '0' then
            addr_q  <= (others => '0');
            write_q <= '0';
            pending <= '0';
        elsif rising_edge(hclk) then
            if pending = '1' and write_q = '1' then
                widx := to_integer(unsigned(addr_q(ADDR_BITS + 1 downto 2)));
                ram(widx) <= hwdata;
            end if;
            pending <= xfer_requested;

            if xfer_requested = '1' then
                addr_q  <= haddr;
                write_q <= hwrite;
            end if;
        end if;
    end process;

end architecture bfm;
