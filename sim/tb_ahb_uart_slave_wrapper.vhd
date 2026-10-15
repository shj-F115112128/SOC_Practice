-- Self-checking testbench for rtl/ahb_uart_slave_wrapper.vhd
-- Exercises every state in docs/01-ahb-wrapper-fsm.md's slave wrapper FSM:
--   IDLE -> NONSEQ -> OKAY -> IDLE            (plain R/W)
--   IDLE -> NONSEQ -> NONSEQ -> ... -> IDLE   (back-to-back pipelined xfers)
--   IDLE -> NONSEQ -> WAIT* -> OKAY -> IDLE   (TXDATA write while tx_busy)
--   IDLE -> NONSEQ -> ERR1 -> ERR2 -> IDLE    (bad address)
--
-- Written for GHDL; not yet run on this machine (no VHDL simulator installed
-- here) -- see docs/05-rtl-simulation.md for status.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ahb_uart_slave_wrapper is
end entity tb_ahb_uart_slave_wrapper;

architecture sim of tb_ahb_uart_slave_wrapper is

    constant HTRANS_IDLE   : std_logic_vector(1 downto 0) := "00";
    constant HTRANS_NONSEQ : std_logic_vector(1 downto 0) := "10";
    constant RESP_OKAY     : std_logic_vector(1 downto 0) := "00";
    constant RESP_ERROR    : std_logic_vector(1 downto 0) := "01";

    constant ADDR_CTRL   : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATUS : std_logic_vector(31 downto 0) := x"00000004";
    constant ADDR_TXDATA : std_logic_vector(31 downto 0) := x"00000008";
    constant ADDR_RXDATA : std_logic_vector(31 downto 0) := x"0000000C";
    constant ADDR_BAD    : std_logic_vector(31 downto 0) := x"00000010";

    signal hclk    : std_logic := '0';
    signal hresetn : std_logic := '0';
    signal hsel    : std_logic := '0';
    signal haddr   : std_logic_vector(31 downto 0) := (others => '0');
    signal htrans  : std_logic_vector(1 downto 0) := HTRANS_IDLE;
    signal hwrite  : std_logic := '0';
    signal hwdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal hreadyout : std_logic;
    signal hresp      : std_logic_vector(1 downto 0);
    signal hrdata      : std_logic_vector(31 downto 0);
    signal rx_byte_valid : std_logic := '0';
    signal rx_byte_data  : std_logic_vector(7 downto 0) := (others => '0');

    shared variable pass_count : integer := 0;
    shared variable fail_count : integer := 0;

    procedure check(cond : boolean; msg : string) is
    begin
        if cond then
            pass_count := pass_count + 1;
            report "[PASS] " & msg;
        else
            fail_count := fail_count + 1;
            report "[FAIL] " & msg severity error;
        end if;
    end procedure;

    procedure ahb_write(addr : std_logic_vector(31 downto 0);
                         data : std_logic_vector(31 downto 0);
                         variable resp : out std_logic_vector(1 downto 0)) is
    begin
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '1'; haddr <= addr; htrans <= HTRANS_NONSEQ; hwrite <= '1';
        wait until rising_edge(hclk); wait for 1 ns;
        htrans <= HTRANS_IDLE; hwdata <= data;
        while hreadyout /= '1' loop
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;
        resp := hresp;
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '0';
    end procedure;

    procedure ahb_read(addr : std_logic_vector(31 downto 0);
                        variable data : out std_logic_vector(31 downto 0);
                        variable resp : out std_logic_vector(1 downto 0)) is
    begin
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '1'; haddr <= addr; htrans <= HTRANS_NONSEQ; hwrite <= '0';
        wait until rising_edge(hclk); wait for 1 ns;
        htrans <= HTRANS_IDLE;
        while hreadyout /= '1' loop
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;
        data := hrdata;
        resp := hresp;
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '0';
    end procedure;

begin

    dut : entity work.ahb_uart_slave_wrapper
        port map (
            hclk      => hclk,
            hresetn   => hresetn,
            hsel      => hsel,
            haddr     => haddr,
            htrans    => htrans,
            hwrite    => hwrite,
            hwdata    => hwdata,
            hready    => hreadyout, -- single-slave system: hready == this slave's hreadyout
            hreadyout => hreadyout,
            hresp     => hresp,
            hrdata    => hrdata,
            rx_byte_valid => rx_byte_valid,
            rx_byte_data  => rx_byte_data
        );

    -- 100 MHz clock
    clk_gen : process
    begin
        hclk <= '0';
        wait for 5 ns;
        hclk <= '1';
        wait for 5 ns;
    end process;

    stim : process
        variable v_resp  : std_logic_vector(1 downto 0);
        variable v_rdata : std_logic_vector(31 downto 0);
    begin
        hresetn <= '0'; hsel <= '0'; haddr <= (others => '0'); htrans <= HTRANS_IDLE;
        hwrite <= '0'; hwdata <= (others => '0');
        rx_byte_valid <= '0'; rx_byte_data <= (others => '0');
        wait until rising_edge(hclk);
        wait until rising_edge(hclk);
        wait until rising_edge(hclk);
        hresetn <= '1';
        wait until rising_edge(hclk);

        -- 1. plain register write + read-back (IDLE->NONSEQ->OKAY->IDLE)
        ahb_write(ADDR_CTRL, x"00000001", v_resp);
        check(v_resp = RESP_OKAY, "CTRL write returns OKAY");
        ahb_read(ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "CTRL read-back == 1");

        -- 2. back-to-back pipelined transfers (NONSEQ immediately followed by NONSEQ)
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '1'; haddr <= ADDR_STATUS; htrans <= HTRANS_NONSEQ; hwrite <= '0';
        wait until rising_edge(hclk); wait for 1 ns;
        -- still inside data phase of xfer1 (STATUS read); pipeline xfer2's address phase now
        haddr <= ADDR_CTRL; htrans <= HTRANS_NONSEQ; hwrite <= '0';
        check(hreadyout = '1', "xfer1 (STATUS) completes same cycle xfer2 address phase issued");
        check(hresp = RESP_OKAY, "xfer1 STATUS resp OKAY");
        wait until rising_edge(hclk); wait for 1 ns;
        htrans <= HTRANS_IDLE;
        while hreadyout /= '1' loop
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;
        check(hrdata = x"00000001", "pipelined xfer2 (CTRL) read-back == 1");
        wait until rising_edge(hclk); wait for 1 ns;
        hsel <= '0';

        -- 3. TXDATA write that collides with tx_busy -> AHB WAIT states
        ahb_write(ADDR_TXDATA, x"00000055", v_resp);
        check(v_resp = RESP_OKAY, "first TXDATA write OKAY, tx_busy now set");
        ahb_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(0) = '1', "STATUS.tx_busy == 1 right after TXDATA write");

        ahb_write(ADDR_TXDATA, x"00000066", v_resp);
        check(v_resp = RESP_OKAY, "second TXDATA write (into WAIT) eventually OKAY");
        ahb_read(ADDR_TXDATA, v_rdata, v_resp);
        check(v_rdata = x"00000066", "TXDATA committed only after wait states cleared");
        ahb_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(0) = '0', "STATUS.tx_busy == 0 after TX finished");

        -- 4. RX byte arrival + read, non-blocking status model
        wait until rising_edge(hclk); wait for 1 ns;
        rx_byte_valid <= '1'; rx_byte_data <= x"A5";
        wait until rising_edge(hclk); wait for 1 ns;
        rx_byte_valid <= '0';
        ahb_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '1', "STATUS.rx_ready == 1 after byte arrival");
        ahb_read(ADDR_RXDATA, v_rdata, v_resp);
        check(v_rdata = x"000000A5", "RXDATA read == 0xA5");
        ahb_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '0', "STATUS.rx_ready == 0 after RXDATA read (cleared)");

        -- 5. bad address -> 2-cycle ERROR response (ERR1 -> ERR2)
        ahb_read(ADDR_BAD, v_rdata, v_resp);
        check(v_resp = RESP_ERROR, "out-of-range address returns HRESP=ERROR");

        -- post-error access must work normally again
        ahb_read(ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "FSM recovers to normal OKAY access after ERROR");

        report "==== AHB UART slave wrapper: " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed ====";
        assert fail_count = 0 report "simulation FAILED" severity failure;
        wait;
    end process;

end architecture sim;
