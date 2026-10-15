-- Self-checking testbench for rtl/axi_lite_uart_slave_wrapper.vhd
-- Exercises docs/02-axi-wrapper-fsm.md's slave write/read channel FSMs, plus
-- the key AXI-vs-AHB difference: an independent read can complete while a
-- write is still back-pressured (not possible on the single shared AHB bus).
-- That overlap is modeled with two concurrent processes (write_thread /
-- read_thread) released together by the start_overlap pulse, mirroring the
-- Verilog testbench's fork/join block.
--
-- Written for GHDL; not yet run on this machine (no VHDL simulator installed
-- here) -- see docs/05-rtl-simulation.md for status.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_lite_uart_slave_wrapper is
end entity tb_axi_lite_uart_slave_wrapper;

architecture sim of tb_axi_lite_uart_slave_wrapper is

    constant RESP_OKAY  : std_logic_vector(1 downto 0) := "00";
    constant RESP_ERROR : std_logic_vector(1 downto 0) := "10";

    constant ADDR_CTRL   : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATUS : std_logic_vector(31 downto 0) := x"00000004";
    constant ADDR_TXDATA : std_logic_vector(31 downto 0) := x"00000008";
    constant ADDR_RXDATA : std_logic_vector(31 downto 0) := x"0000000C";
    constant ADDR_BAD    : std_logic_vector(31 downto 0) := x"00000010";

    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';

    signal awvalid : std_logic := '0';
    signal awaddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal awready : std_logic;
    signal wvalid  : std_logic := '0';
    signal wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal wstrb   : std_logic_vector(3 downto 0) := (others => '0');
    signal wready  : std_logic;
    signal bvalid  : std_logic;
    signal bresp   : std_logic_vector(1 downto 0);
    signal bready  : std_logic := '0';

    signal arvalid : std_logic := '0';
    signal araddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal arready : std_logic;
    signal rvalid  : std_logic;
    signal rdata   : std_logic_vector(31 downto 0);
    signal rresp   : std_logic_vector(1 downto 0);
    signal rready  : std_logic := '0';

    signal rx_byte_valid : std_logic := '0';
    signal rx_byte_data  : std_logic_vector(7 downto 0) := (others => '0');

    -- fork/join for test 3 (overlapped write + read)
    signal start_overlap : std_logic := '0';
    signal write3_done, read3_done : std_logic := '0';
    signal resp3_write, resp3_read : std_logic_vector(1 downto 0);

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

    -- awvalid/wvalid/bready (or arvalid/rready) held high until handshake --
    -- a valid, if simplistic, AXI master behavior for a single outstanding xfer.
    procedure axi_write(addr : std_logic_vector(31 downto 0);
                         data : std_logic_vector(31 downto 0);
                         variable resp : out std_logic_vector(1 downto 0)) is
    begin
        wait until rising_edge(aclk); wait for 1 ns;
        awvalid <= '1'; awaddr <= addr;
        wvalid  <= '1'; wdata  <= data; wstrb <= "1111";
        bready  <= '1';
        while bvalid /= '1' loop
            wait until rising_edge(aclk); wait for 1 ns;
        end loop;
        resp := bresp;
        wait until rising_edge(aclk); wait for 1 ns;
        awvalid <= '0'; wvalid <= '0'; bready <= '0';
    end procedure;

    procedure axi_read(addr : std_logic_vector(31 downto 0);
                        variable data : out std_logic_vector(31 downto 0);
                        variable resp : out std_logic_vector(1 downto 0)) is
    begin
        wait until rising_edge(aclk); wait for 1 ns;
        arvalid <= '1'; araddr <= addr; rready <= '1';
        while rvalid /= '1' loop
            wait until rising_edge(aclk); wait for 1 ns;
        end loop;
        data := rdata;
        resp := rresp;
        wait until rising_edge(aclk); wait for 1 ns;
        arvalid <= '0'; rready <= '0';
    end procedure;

begin

    dut : entity work.axi_lite_uart_slave_wrapper
        port map (
            aclk => aclk, aresetn => aresetn,
            awvalid => awvalid, awaddr => awaddr, awready => awready,
            wvalid => wvalid, wdata => wdata, wstrb => wstrb, wready => wready,
            bvalid => bvalid, bresp => bresp, bready => bready,
            arvalid => arvalid, araddr => araddr, arready => arready,
            rvalid => rvalid, rdata => rdata, rresp => rresp, rready => rready,
            rx_byte_valid => rx_byte_valid, rx_byte_data => rx_byte_data
        );

    clk_gen : process
    begin
        aclk <= '0';
        wait for 5 ns;
        aclk <= '1';
        wait for 5 ns;
    end process;

    -- test 3's write side: runs once, released by start_overlap
    write_thread : process
        variable v_resp : std_logic_vector(1 downto 0);
    begin
        wait until start_overlap = '1';
        axi_write(ADDR_TXDATA, x"00000066", v_resp);
        resp3_write <= v_resp;
        write3_done <= '1';
        wait;
    end process;

    -- test 3's read side: starts ~2ns after the write asserts AWVALID/WVALID,
    -- while the write is still back-pressured by tx_busy
    read_thread : process
        variable v_resp  : std_logic_vector(1 downto 0);
        variable v_rdata : std_logic_vector(31 downto 0);
    begin
        wait until start_overlap = '1';
        wait for 2 ns;
        axi_read(ADDR_STATUS, v_rdata, v_resp);
        resp3_read <= v_resp;
        read3_done <= '1';
        wait;
    end process;

    stim : process
        variable v_resp  : std_logic_vector(1 downto 0);
        variable v_rdata : std_logic_vector(31 downto 0);
    begin
        aresetn <= '0';
        awvalid <= '0'; awaddr <= (others => '0');
        wvalid <= '0'; wdata <= (others => '0'); wstrb <= (others => '0'); bready <= '0';
        arvalid <= '0'; araddr <= (others => '0'); rready <= '0';
        rx_byte_valid <= '0'; rx_byte_data <= (others => '0');
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- 1. plain register write + read-back
        axi_write(ADDR_CTRL, x"00000001", v_resp);
        check(v_resp = RESP_OKAY, "CTRL write returns OKAY");
        axi_read(ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "CTRL read-back == 1");

        -- 2. TXDATA write that collides with tx_busy -> WREADY back-pressure
        axi_write(ADDR_TXDATA, x"00000055", v_resp);
        check(v_resp = RESP_OKAY, "first TXDATA write OKAY, tx_busy now set");
        axi_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(0) = '1', "STATUS.tx_busy == 1 right after TXDATA write");

        -- 3. second TXDATA write overlapped with an independent STATUS read:
        --    the read channel is NOT blocked by the write channel's wait,
        --    unlike the AHB version where only one transfer can be in flight.
        write3_done <= '0'; read3_done <= '0';
        start_overlap <= '1';
        wait for 1 ns;
        start_overlap <= '0';
        wait until write3_done = '1' and read3_done = '1';
        check(resp3_read = RESP_OKAY, "STATUS read (read channel) completes independently");
        check(resp3_write = RESP_OKAY, "second TXDATA write eventually OKAY once tx_busy clears");
        axi_read(ADDR_TXDATA, v_rdata, v_resp);
        check(v_rdata = x"00000066", "TXDATA committed only after back-pressure cleared");

        -- 4. RX byte arrival + read, non-blocking status model
        wait until rising_edge(aclk); wait for 1 ns;
        rx_byte_valid <= '1'; rx_byte_data <= x"A5";
        wait until rising_edge(aclk); wait for 1 ns;
        rx_byte_valid <= '0';
        axi_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '1', "STATUS.rx_ready == 1 after byte arrival");
        axi_read(ADDR_RXDATA, v_rdata, v_resp);
        check(v_rdata = x"000000A5", "RXDATA read == 0xA5");
        axi_read(ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '0', "STATUS.rx_ready == 0 after RXDATA read (cleared)");

        -- 5. bad address -> SLVERR on both channels
        axi_read(ADDR_BAD, v_rdata, v_resp);
        check(v_resp = RESP_ERROR, "out-of-range read returns RRESP=SLVERR");
        axi_write(ADDR_BAD, x"0000DEAD", v_resp);
        check(v_resp = RESP_ERROR, "out-of-range write returns BRESP=SLVERR");

        -- post-error access must work normally again
        axi_read(ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "FSM recovers to normal OKAY access after SLVERR");

        report "==== AXI-Lite UART slave wrapper: " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed ====";
        assert fail_count = 0 report "simulation FAILED" severity failure;
        wait;
    end process;

end architecture sim;
