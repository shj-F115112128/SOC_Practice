-- Self-checking testbench for rtl/axi_lite_uart_slave_wrapper.vhd
-- Exercises docs/02-axi-wrapper-fsm.md's slave write/read channel FSMs, plus
-- the key AXI-vs-AHB difference: an independent read can complete while a
-- write is still back-pressured (not possible on the single shared AHB bus).
--
-- Structure: two permanent "driver" processes each own one channel's worth
-- of signals for the entire simulation (write_driver drives AW/W/B, read_
-- driver drives AR/R) and serve simple req/done handshakes. `stim` never
-- touches AXI signals directly -- it only pulses wr_req/rd_req -- so each
-- AXI signal has exactly one process assigning it. (An earlier version had
-- `stim` and two one-shot "thread" processes both calling into procedures
-- that drove the same signals; VHDL gives each driving process its own
-- driver on a resolved signal, so whichever process wasn't "active" still
-- held its idle value, and conflicting 0/1 drivers resolved to 'X' the
-- moment the second process went live -- hanging the simulation. Routing
-- all AXI-channel traffic through one process per channel avoids that.)
-- The same req/done processes naturally run concurrently, so test 3's
-- overlapped write+read falls out for free, no separate fork/join needed.
--
-- Run with Vivado xsim 2018.2 (see docs/05-rtl-simulation.md).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all; -- for finish(), so xsim exits instead of free-running clk_gen forever

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

    -- req/done handshake into write_driver / read_driver (see header comment)
    signal wr_addr, wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_req, wr_done  : std_logic := '0';
    signal wr_resp          : std_logic_vector(1 downto 0);

    signal rd_addr          : std_logic_vector(31 downto 0) := (others => '0');
    signal rd_req, rd_done  : std_logic := '0';
    signal rd_data          : std_logic_vector(31 downto 0);
    signal rd_resp          : std_logic_vector(1 downto 0);

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

    -- these only drive the req/done handshake signals, which `stim` is the
    -- sole writer of, so no multi-driver issue here.
    procedure axi_write(signal wr_req  : out std_logic;
                         signal wr_addr: out std_logic_vector(31 downto 0);
                         signal wr_data: out std_logic_vector(31 downto 0);
                         signal wr_done: in  std_logic;
                         signal wr_resp: in  std_logic_vector(1 downto 0);
                         addr : std_logic_vector(31 downto 0);
                         data : std_logic_vector(31 downto 0);
                         variable resp : out std_logic_vector(1 downto 0)) is
    begin
        wr_addr <= addr; wr_data <= data;
        wr_req <= '1';
        wait until wr_done = '1';
        resp := wr_resp;
        wr_req <= '0';
        wait until wr_done = '0';
    end procedure;

    procedure axi_read(signal rd_req  : out std_logic;
                        signal rd_addr: out std_logic_vector(31 downto 0);
                        signal rd_done: in  std_logic;
                        signal rd_data: in  std_logic_vector(31 downto 0);
                        signal rd_resp: in  std_logic_vector(1 downto 0);
                        addr : std_logic_vector(31 downto 0);
                        variable data : out std_logic_vector(31 downto 0);
                        variable resp : out std_logic_vector(1 downto 0)) is
    begin
        rd_addr <= addr;
        rd_req <= '1';
        wait until rd_done = '1';
        data := rd_data;
        resp := rd_resp;
        rd_req <= '0';
        wait until rd_done = '0';
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

    -- sole driver of the AW/W/B channel signals, for the whole simulation
    write_driver : process
    begin
        loop
            wait until wr_req = '1';
            wait until rising_edge(aclk); wait for 1 ns;
            awvalid <= '1'; awaddr <= wr_addr;
            wvalid  <= '1'; wdata  <= wr_data; wstrb <= "1111";
            bready  <= '1';
            while bvalid /= '1' loop
                wait until rising_edge(aclk); wait for 1 ns;
            end loop;
            wr_resp <= bresp;
            wait until rising_edge(aclk); wait for 1 ns;
            awvalid <= '0'; wvalid <= '0'; bready <= '0';
            wr_done <= '1';
            wait until wr_req = '0';
            wr_done <= '0';
        end loop;
    end process;

    -- sole driver of the AR/R channel signals, for the whole simulation
    read_driver : process
    begin
        loop
            wait until rd_req = '1';
            wait until rising_edge(aclk); wait for 1 ns;
            arvalid <= '1'; araddr <= rd_addr; rready <= '1';
            while rvalid /= '1' loop
                wait until rising_edge(aclk); wait for 1 ns;
            end loop;
            rd_data <= rdata; rd_resp <= rresp;
            wait until rising_edge(aclk); wait for 1 ns;
            arvalid <= '0'; rready <= '0';
            rd_done <= '1';
            wait until rd_req = '0';
            rd_done <= '0';
        end loop;
    end process;

    stim : process
        variable v_resp  : std_logic_vector(1 downto 0);
        variable v_rdata : std_logic_vector(31 downto 0);
    begin
        aresetn <= '0';
        rx_byte_valid <= '0'; rx_byte_data <= (others => '0');
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- 1. plain register write + read-back
        axi_write(wr_req, wr_addr, wr_data, wr_done, wr_resp, ADDR_CTRL, x"00000001", v_resp);
        check(v_resp = RESP_OKAY, "CTRL write returns OKAY");
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "CTRL read-back == 1");

        -- 2. TXDATA write that collides with tx_busy -> WREADY back-pressure
        axi_write(wr_req, wr_addr, wr_data, wr_done, wr_resp, ADDR_TXDATA, x"00000055", v_resp);
        check(v_resp = RESP_OKAY, "first TXDATA write OKAY, tx_busy now set");
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(0) = '1', "STATUS.tx_busy == 1 right after TXDATA write");

        -- 3. second TXDATA write overlapped with an independent STATUS read:
        --    the read channel is NOT blocked by the write channel's wait,
        --    unlike the AHB version where only one transfer can be in flight.
        --    write_driver/read_driver are independent processes, so just
        --    kicking both requests a couple ns apart gives genuine overlap.
        wr_addr <= ADDR_TXDATA; wr_data <= x"00000066";
        wr_req <= '1';
        wait for 2 ns;
        rd_addr <= ADDR_STATUS;
        rd_req <= '1';
        wait until wr_done = '1' and rd_done = '1';
        check(rd_resp = RESP_OKAY, "STATUS read (read channel) completes independently");
        check(wr_resp = RESP_OKAY, "second TXDATA write eventually OKAY once tx_busy clears");
        wr_req <= '0'; rd_req <= '0';
        wait until wr_done = '0' and rd_done = '0';
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_TXDATA, v_rdata, v_resp);
        check(v_rdata = x"00000066", "TXDATA committed only after back-pressure cleared");

        -- 4. RX byte arrival + read, non-blocking status model
        wait until rising_edge(aclk); wait for 1 ns;
        rx_byte_valid <= '1'; rx_byte_data <= x"A5";
        wait until rising_edge(aclk); wait for 1 ns;
        rx_byte_valid <= '0';
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '1', "STATUS.rx_ready == 1 after byte arrival");
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_RXDATA, v_rdata, v_resp);
        check(v_rdata = x"000000A5", "RXDATA read == 0xA5");
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_STATUS, v_rdata, v_resp);
        check(v_rdata(1) = '0', "STATUS.rx_ready == 0 after RXDATA read (cleared)");

        -- 5. bad address -> SLVERR on both channels
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_BAD, v_rdata, v_resp);
        check(v_resp = RESP_ERROR, "out-of-range read returns RRESP=SLVERR");
        axi_write(wr_req, wr_addr, wr_data, wr_done, wr_resp, ADDR_BAD, x"0000DEAD", v_resp);
        check(v_resp = RESP_ERROR, "out-of-range write returns BRESP=SLVERR");

        -- post-error access must work normally again
        axi_read(rd_req, rd_addr, rd_done, rd_data, rd_resp, ADDR_CTRL, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata = x"00000001", "FSM recovers to normal OKAY access after SLVERR");

        report "==== AXI-Lite UART slave wrapper: " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed ====";
        assert fail_count = 0 report "simulation FAILED" severity failure;
        finish;  -- clk_gen never stops on its own; tell the simulator we're done
        wait;
    end process;

end architecture sim;
