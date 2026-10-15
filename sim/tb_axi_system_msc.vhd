-- System-level AXI testbench reproducing the full MSC in docs/04-msc-axi.md:
--   A. CPU configures the UART SIP (AW/W write, BRESP=OKAY)
--   B. SIP-DMA writes BURST_LEN bytes into the mem BFM (AWID=1-style write
--      burst modeled as BURST_LEN back-to-back AXI4-Lite write transactions
--      -- AXI4-Lite has no protocol-level burst)
--   C. CPU polls STATUS over its OWN read channel -- independent of, and
--      overlapped with, the DMA's write channel (the AXI-specific point
--      docs/04 calls out: this can't happen on AHB's single shared bus)
--   D. CPU reads the memory contents back over its own read channel
--
-- No arbiter/decoder glue is needed here (unlike the AHB system tb): AXI's
-- independent per-channel master/slave wiring means every participant gets
-- its own dedicated AW/W/B or AR/R ports directly to whichever slave it
-- actually talks to --
--   CPU  <-> uart : write (phase A) + read (phase C, STATUS poll)
--   DMA  <-> mem  : write (phase B, burst)
--   CPU  <-> mem  : read (phase D, readback)
-- -- matching docs/02's note that AXI has no central arbiter FSM the way
-- AHB does.
--
-- CPU's own channel traffic reuses the write_driver/read_driver req/done
-- pattern from tb_axi_lite_uart_slave_wrapper.vhd (one permanent driver
-- process per channel role, no multi-driver risk).
--
-- Run with Vivado xsim 2018.2 (see docs/05-rtl-simulation.md).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_axi_system_msc is
end entity tb_axi_system_msc;

architecture sim of tb_axi_system_msc is

    constant RESP_OKAY : std_logic_vector(1 downto 0) := "00";

    constant ADDR_CTRL   : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATUS : std_logic_vector(31 downto 0) := x"00000004";
    constant MEM_BASE    : std_logic_vector(31 downto 0) := x"00001000";

    constant BURST_LEN : natural := 4;

    signal aclk    : std_logic := '0';
    signal aresetn : std_logic := '0';

    -- CPU <-> UART (write: phase A; read: phase C)
    signal cw_awvalid : std_logic := '0';
    signal cw_awaddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal cw_awready : std_logic;
    signal cw_wvalid  : std_logic := '0';
    signal cw_wdata   : std_logic_vector(31 downto 0) := (others => '0');
    signal cw_wready  : std_logic;
    signal cw_bvalid  : std_logic;
    signal cw_bresp   : std_logic_vector(1 downto 0);
    signal cw_bready  : std_logic := '0';

    signal cru_arvalid : std_logic := '0';
    signal cru_araddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal cru_arready : std_logic;
    signal cru_rvalid  : std_logic;
    signal cru_rdata   : std_logic_vector(31 downto 0);
    signal cru_rresp   : std_logic_vector(1 downto 0);
    signal cru_rready  : std_logic := '0';

    -- CPU <-> mem (read: phase D)
    signal crm_arvalid : std_logic := '0';
    signal crm_araddr  : std_logic_vector(31 downto 0) := (others => '0');
    signal crm_arready : std_logic;
    signal crm_rvalid  : std_logic;
    signal crm_rdata   : std_logic_vector(31 downto 0);
    signal crm_rresp   : std_logic_vector(1 downto 0);
    signal crm_rready  : std_logic := '0';

    -- DMA <-> mem (write: phase B)
    signal dw_awvalid : std_logic;
    signal dw_awaddr  : std_logic_vector(31 downto 0);
    signal dw_awready : std_logic;
    signal dw_wvalid  : std_logic;
    signal dw_wdata   : std_logic_vector(31 downto 0);
    signal dw_wready  : std_logic;
    signal dw_bvalid  : std_logic;
    signal dw_bresp   : std_logic_vector(1 downto 0);
    signal dw_bready  : std_logic;

    -- UART slave wrapper <-> DMA master wrapper handshake
    signal s_rx_ready    : std_logic;
    signal s_rx_data     : std_logic_vector(7 downto 0);
    signal s_dma_consume : std_logic;
    signal s_dma_done    : std_logic;

    signal rx_byte_valid : std_logic := '0';
    signal rx_byte_data  : std_logic_vector(7 downto 0) := (others => '0');

    -- req/done handshake layer for the CPU's two driver processes
    signal wr_addr, wr_data : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_req, wr_done  : std_logic := '0';
    signal wr_resp          : std_logic_vector(1 downto 0);

    signal rdu_addr         : std_logic_vector(31 downto 0) := (others => '0');
    signal rdu_req, rdu_done: std_logic := '0';
    signal rdu_data         : std_logic_vector(31 downto 0);
    signal rdu_resp         : std_logic_vector(1 downto 0);

    signal rdm_addr         : std_logic_vector(31 downto 0) := (others => '0');
    signal rdm_req, rdm_done: std_logic := '0';
    signal rdm_data         : std_logic_vector(31 downto 0);
    signal rdm_resp         : std_logic_vector(1 downto 0);

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

    uart : entity work.axi_lite_uart_slave_wrapper
        port map (
            aclk => aclk, aresetn => aresetn,
            awvalid => cw_awvalid, awaddr => cw_awaddr, awready => cw_awready,
            wvalid => cw_wvalid, wdata => cw_wdata, wstrb => "1111", wready => cw_wready,
            bvalid => cw_bvalid, bresp => cw_bresp, bready => cw_bready,
            arvalid => cru_arvalid, araddr => cru_araddr, arready => cru_arready,
            rvalid => cru_rvalid, rdata => cru_rdata, rresp => cru_rresp, rready => cru_rready,
            rx_byte_valid => rx_byte_valid, rx_byte_data => rx_byte_data,
            rx_ready_o => s_rx_ready, rx_data_o => s_rx_data,
            dma_consume => s_dma_consume, dma_done_set => s_dma_done
        );

    dma : entity work.axi_uart_master_wrapper
        generic map (BURST_LEN => BURST_LEN)
        port map (
            aclk => aclk, aresetn => aresetn,
            awvalid => dw_awvalid, awaddr => dw_awaddr, awready => dw_awready,
            wvalid => dw_wvalid, wdata => dw_wdata, wready => dw_wready,
            bvalid => dw_bvalid, bready => dw_bready,
            dma_base_addr => MEM_BASE,
            rx_ready_i => s_rx_ready, rx_data_i => s_rx_data,
            dma_consume_o => s_dma_consume, dma_done_o => s_dma_done
        );

    mem : entity work.axi_mem_slave_bfm
        port map (
            aclk => aclk, aresetn => aresetn,
            awvalid => dw_awvalid, awaddr => dw_awaddr, awready => dw_awready,
            wvalid => dw_wvalid, wdata => dw_wdata, wready => dw_wready,
            bvalid => dw_bvalid, bresp => dw_bresp, bready => dw_bready,
            arvalid => crm_arvalid, araddr => crm_araddr, arready => crm_arready,
            rvalid => crm_rvalid, rdata => crm_rdata, rresp => crm_rresp, rready => crm_rready
        );

    clk_gen : process
    begin
        aclk <= '0';
        wait for 5 ns;
        aclk <= '1';
        wait for 5 ns;
    end process;

    -- CPU's write-channel driver (-> UART, phase A)
    write_driver : process
    begin
        loop
            wait until wr_req = '1';
            wait until rising_edge(aclk); wait for 1 ns;
            cw_awvalid <= '1'; cw_awaddr <= wr_addr;
            cw_wvalid  <= '1'; cw_wdata  <= wr_data;
            cw_bready  <= '1';
            while cw_bvalid /= '1' loop
                wait until rising_edge(aclk); wait for 1 ns;
            end loop;
            wr_resp <= cw_bresp;
            wait until rising_edge(aclk); wait for 1 ns;
            cw_awvalid <= '0'; cw_wvalid <= '0'; cw_bready <= '0';
            wr_done <= '1';
            wait until wr_req = '0';
            wr_done <= '0';
        end loop;
    end process;

    -- CPU's read-channel driver (-> UART, phase C STATUS poll)
    read_uart_driver : process
    begin
        loop
            wait until rdu_req = '1';
            wait until rising_edge(aclk); wait for 1 ns;
            cru_arvalid <= '1'; cru_araddr <= rdu_addr; cru_rready <= '1';
            while cru_rvalid /= '1' loop
                wait until rising_edge(aclk); wait for 1 ns;
            end loop;
            rdu_data <= cru_rdata; rdu_resp <= cru_rresp;
            wait until rising_edge(aclk); wait for 1 ns;
            cru_arvalid <= '0'; cru_rready <= '0';
            rdu_done <= '1';
            wait until rdu_req = '0';
            rdu_done <= '0';
        end loop;
    end process;

    -- CPU's second, independent read-channel driver (-> mem, phase D)
    read_mem_driver : process
    begin
        loop
            wait until rdm_req = '1';
            wait until rising_edge(aclk); wait for 1 ns;
            crm_arvalid <= '1'; crm_araddr <= rdm_addr; crm_rready <= '1';
            while crm_rvalid /= '1' loop
                wait until rising_edge(aclk); wait for 1 ns;
            end loop;
            rdm_data <= crm_rdata; rdm_resp <= crm_rresp;
            wait until rising_edge(aclk); wait for 1 ns;
            crm_arvalid <= '0'; crm_rready <= '0';
            rdm_done <= '1';
            wait until rdm_req = '0';
            rdm_done <= '0';
        end loop;
    end process;

    stim : process
        variable v_resp  : std_logic_vector(1 downto 0);
        variable v_rdata : std_logic_vector(31 downto 0);
        variable byte    : std_logic_vector(7 downto 0);
    begin
        aresetn <= '0';
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- ==== Phase A: CPU configures the SIP ====
        axi_write(wr_req, wr_addr, wr_data, wr_done, wr_resp, ADDR_CTRL, x"00000001", v_resp);
        check(v_resp = RESP_OKAY, "phase A: CTRL write (enable) returns OKAY");

        -- ==== Phase B trigger: BURST_LEN bytes arrive at the SIP's RX side ====
        for i in 0 to BURST_LEN - 1 loop
            byte := std_logic_vector(to_unsigned(16#B0# + i, 8));
            wait until rising_edge(aclk); wait for 1 ns;
            rx_byte_valid <= '1'; rx_byte_data <= byte;
            wait until rising_edge(aclk); wait for 1 ns;
            rx_byte_valid <= '0';
            wait until rising_edge(aclk); wait for 1 ns;
        end loop;

        -- ==== Phase C: poll STATUS on the CPU's OWN read channel. This can
        -- (and, timed right here, does) overlap with the DMA's write-burst
        -- still in flight on the completely independent write channel --
        -- the thing AHB's single shared bus can't do.
        axi_read(rdu_req, rdu_addr, rdu_done, rdu_data, rdu_resp, ADDR_STATUS, v_rdata, v_resp);
        check(v_resp = RESP_OKAY, "phase C: STATUS read completes independently of the DMA write channel");

        wait until s_dma_done = '1';
        check(true, "phase B: SIP-DMA write burst to memory completed (dma_done pulsed)");

        axi_read(rdu_req, rdu_addr, rdu_done, rdu_data, rdu_resp, ADDR_STATUS, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata(2) = '1', "phase C: STATUS.dma_done == 1 after burst");

        -- ==== Phase D: CPU reads the memory contents back ====
        for i in 0 to BURST_LEN - 1 loop
            axi_read(rdm_req, rdm_addr, rdm_done, rdm_data, rdm_resp,
                      std_logic_vector(unsigned(MEM_BASE) + to_unsigned(i * 4, 32)),
                      v_rdata, v_resp);
            byte := std_logic_vector(to_unsigned(16#B0# + i, 8));
            check(v_resp = RESP_OKAY and v_rdata(7 downto 0) = byte,
                  "phase D: memory[" & integer'image(i) & "] == byte DMA'd by the SIP");
        end loop;

        report "==== AXI system MSC (A/B/C/D): " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed ====";
        assert fail_count = 0 report "simulation FAILED" severity failure;
        finish;
        wait;
    end process;

end architecture sim;
