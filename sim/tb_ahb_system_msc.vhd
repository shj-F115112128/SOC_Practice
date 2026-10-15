-- System-level AHB testbench reproducing the full MSC in docs/03-msc-ahb.md:
--   A. CPU configures the UART SIP (CTRL write, OKAY)
--   B. SIP-DMA requests the bus (HBUSREQ1/HGRANT1) once BURST_LEN RX bytes
--      have arrived
--   C. SIP-DMA bursts those bytes into the mem BFM (NONSEQ + SEQ beats)
--   D. SIP signals completion (STATUS.dma_done) and the CPU polls/reads
--      STATUS then RXDATA-equivalent memory contents back
--
-- Wires together: ahb_arbiter, ahb_uart_slave_wrapper, ahb_uart_master_wrapper,
-- ahb_mem_slave_bfm. The CPU master is this testbench's stim process driving
-- the shared bus directly (same role the single-wrapper testbenches play),
-- gated by its own HBUSREQ0/HGRANT0 like a real second master. Address
-- decode + slave response mux is the "standard AHB infrastructure" docs/01
-- says isn't worth drawing separately, so it lives here rather than as its
-- own RTL file:
--   0x0000_0xxx -> UART register file (hsel_uart)
--   0x0000_1xxx -> memory BFM (hsel_mem)
--
-- Run with Vivado xsim 2018.2 (see docs/05-rtl-simulation.md).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_ahb_system_msc is
end entity tb_ahb_system_msc;

architecture sim of tb_ahb_system_msc is

    constant HTRANS_IDLE   : std_logic_vector(1 downto 0) := "00";
    constant HTRANS_NONSEQ : std_logic_vector(1 downto 0) := "10";
    constant RESP_OKAY     : std_logic_vector(1 downto 0) := "00";

    constant ADDR_CTRL   : std_logic_vector(31 downto 0) := x"00000000";
    constant ADDR_STATUS : std_logic_vector(31 downto 0) := x"00000004";
    constant MEM_BASE    : std_logic_vector(31 downto 0) := x"00001000";

    constant BURST_LEN : natural := 4;

    signal hclk    : std_logic := '0';
    signal hresetn : std_logic := '0';

    -- shared (post-mux) bus seen by both slaves
    signal haddr_bus   : std_logic_vector(31 downto 0) := (others => '0');
    signal htrans_bus  : std_logic_vector(1 downto 0)  := HTRANS_IDLE;
    signal hwrite_bus  : std_logic := '0';
    signal hwdata_bus  : std_logic_vector(31 downto 0) := (others => '0');
    signal hready_bus  : std_logic := '1';
    signal hresp_bus   : std_logic_vector(1 downto 0)  := RESP_OKAY;
    signal hrdata_bus  : std_logic_vector(31 downto 0) := (others => '0');

    -- CPU (master 0) side
    signal cpu_haddr   : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_htrans  : std_logic_vector(1 downto 0)  := HTRANS_IDLE;
    signal cpu_hwrite  : std_logic := '0';
    signal cpu_hwdata  : std_logic_vector(31 downto 0) := (others => '0');
    signal cpu_hbusreq : std_logic := '0';
    signal hgrant0     : std_logic;

    -- SIP-DMA (master 1) side
    signal dma_haddr   : std_logic_vector(31 downto 0);
    signal dma_htrans  : std_logic_vector(1 downto 0);
    signal dma_hwrite  : std_logic;
    signal dma_hwdata  : std_logic_vector(31 downto 0);
    signal dma_hbusreq : std_logic;
    signal hgrant1     : std_logic;

    -- UART slave wrapper <-> DMA master wrapper handshake
    signal s_rx_ready   : std_logic;
    signal s_rx_data    : std_logic_vector(7 downto 0);
    signal s_dma_consume: std_logic;
    signal s_dma_done   : std_logic;

    -- UART slave wrapper ports
    signal uart_hreadyout : std_logic;
    signal uart_hresp     : std_logic_vector(1 downto 0);
    signal uart_hrdata    : std_logic_vector(31 downto 0);
    signal rx_byte_valid  : std_logic := '0';
    signal rx_byte_data   : std_logic_vector(7 downto 0) := (others => '0');

    -- mem BFM ports
    signal mem_hreadyout : std_logic;
    signal mem_hresp     : std_logic_vector(1 downto 0);
    signal mem_hrdata    : std_logic_vector(31 downto 0);

    -- address decode + "who's responding this cycle" tracking
    signal hsel_uart, hsel_mem     : std_logic;
    signal hsel_uart_q, hsel_mem_q : std_logic := '0';

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

    procedure cpu_write(signal hclk      : in  std_logic;
                         signal hbusreq   : out std_logic;
                         signal hgrant    : in  std_logic;
                         signal haddr     : out std_logic_vector(31 downto 0);
                         signal htrans    : out std_logic_vector(1 downto 0);
                         signal hwrite    : out std_logic;
                         signal hwdata    : out std_logic_vector(31 downto 0);
                         signal hready    : in  std_logic;
                         signal hresp     : in  std_logic_vector(1 downto 0);
                         addr : std_logic_vector(31 downto 0);
                         data : std_logic_vector(31 downto 0);
                         variable resp : out std_logic_vector(1 downto 0)) is
    begin
        hbusreq <= '1';
        wait until rising_edge(hclk) and hgrant = '1'; wait for 1 ns;
        haddr <= addr; htrans <= HTRANS_NONSEQ; hwrite <= '1';
        wait until rising_edge(hclk); wait for 1 ns;
        htrans <= HTRANS_IDLE; hwdata <= data;
        while hready /= '1' loop
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;
        resp := hresp;
        wait until rising_edge(hclk); wait for 1 ns;
        hbusreq <= '0';
    end procedure;

    procedure cpu_read(signal hclk      : in  std_logic;
                        signal hbusreq   : out std_logic;
                        signal hgrant    : in  std_logic;
                        signal haddr     : out std_logic_vector(31 downto 0);
                        signal htrans    : out std_logic_vector(1 downto 0);
                        signal hwrite    : out std_logic;
                        signal hready    : in  std_logic;
                        signal hresp     : in  std_logic_vector(1 downto 0);
                        signal hrdata    : in  std_logic_vector(31 downto 0);
                        addr : std_logic_vector(31 downto 0);
                        variable data : out std_logic_vector(31 downto 0);
                        variable resp : out std_logic_vector(1 downto 0)) is
    begin
        hbusreq <= '1';
        wait until rising_edge(hclk) and hgrant = '1'; wait for 1 ns;
        haddr <= addr; htrans <= HTRANS_NONSEQ; hwrite <= '0';
        wait until rising_edge(hclk); wait for 1 ns;
        htrans <= HTRANS_IDLE;
        while hready /= '1' loop
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;
        data := hrdata;
        resp := hresp;
        wait until rising_edge(hclk); wait for 1 ns;
        hbusreq <= '0';
    end procedure;

begin

    -- ---- bus mux (grant-selected master drives the shared bus) ----
    haddr_bus  <= cpu_haddr  when hgrant0 = '1' else dma_haddr  when hgrant1 = '1' else (others => '0');
    htrans_bus <= cpu_htrans when hgrant0 = '1' else dma_htrans when hgrant1 = '1' else HTRANS_IDLE;
    hwrite_bus <= cpu_hwrite when hgrant0 = '1' else dma_hwrite when hgrant1 = '1' else '0';
    hwdata_bus <= cpu_hwdata when hgrant0 = '1' else dma_hwdata when hgrant1 = '1' else (others => '0');

    -- ---- address decode ----
    hsel_uart <= '1' when haddr_bus(15 downto 12) = x"0" else '0';
    hsel_mem  <= '1' when haddr_bus(15 downto 12) = x"1" else '0';

    -- ---- track which slave the CURRENT response mux belongs to ----
    process (hclk, hresetn)
    begin
        if hresetn = '0' then
            hsel_uart_q <= '0';
            hsel_mem_q  <= '0';
        elsif rising_edge(hclk) then
            if hready_bus = '1' and (htrans_bus = HTRANS_NONSEQ or htrans_bus = "11") then
                hsel_uart_q <= hsel_uart;
                hsel_mem_q  <= hsel_mem;
            end if;
        end if;
    end process;

    hready_bus <= uart_hreadyout when hsel_uart_q = '1' else
                  mem_hreadyout  when hsel_mem_q  = '1' else '1';
    hresp_bus  <= uart_hresp when hsel_uart_q = '1' else
                  mem_hresp  when hsel_mem_q  = '1' else RESP_OKAY;
    hrdata_bus <= uart_hrdata when hsel_uart_q = '1' else
                  mem_hrdata  when hsel_mem_q  = '1' else (others => '0');

    -- ---- arbiter ----
    arb : entity work.ahb_arbiter
        port map (
            hclk     => hclk,
            hresetn  => hresetn,
            hbusreq0 => cpu_hbusreq,
            hbusreq1 => dma_hbusreq,
            hready   => hready_bus,
            hgrant0  => hgrant0,
            hgrant1  => hgrant1
        );

    -- ---- UART slave wrapper ----
    uart : entity work.ahb_uart_slave_wrapper
        port map (
            hclk          => hclk,
            hresetn       => hresetn,
            hsel          => hsel_uart,
            haddr         => haddr_bus,
            htrans        => htrans_bus,
            hwrite        => hwrite_bus,
            hwdata        => hwdata_bus,
            hready        => hready_bus,
            hreadyout     => uart_hreadyout,
            hresp         => uart_hresp,
            hrdata        => uart_hrdata,
            rx_byte_valid => rx_byte_valid,
            rx_byte_data  => rx_byte_data,
            rx_ready_o    => s_rx_ready,
            rx_data_o     => s_rx_data,
            dma_consume   => s_dma_consume,
            dma_done_set  => s_dma_done
        );

    -- ---- SIP-DMA master wrapper ----
    dma : entity work.ahb_uart_master_wrapper
        generic map (BURST_LEN => BURST_LEN)
        port map (
            hclk          => hclk,
            hresetn       => hresetn,
            hbusreq       => dma_hbusreq,
            hgrant        => hgrant1,
            haddr         => dma_haddr,
            htrans        => dma_htrans,
            hwrite        => dma_hwrite,
            hwdata        => dma_hwdata,
            hready        => hready_bus,
            hresp         => hresp_bus,
            dma_base_addr => MEM_BASE,
            rx_ready_i    => s_rx_ready,
            rx_data_i     => s_rx_data,
            dma_consume_o => s_dma_consume,
            dma_done_o    => s_dma_done
        );

    -- ---- memory BFM ----
    mem : entity work.ahb_mem_slave_bfm
        port map (
            hclk      => hclk,
            hresetn   => hresetn,
            hsel      => hsel_mem,
            haddr     => haddr_bus,
            htrans    => htrans_bus,
            hwrite    => hwrite_bus,
            hwdata    => hwdata_bus,
            hready    => hready_bus,
            hreadyout => mem_hreadyout,
            hresp     => mem_hresp,
            hrdata    => mem_hrdata
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
        variable byte    : std_logic_vector(7 downto 0);
    begin
        hresetn <= '0';
        wait until rising_edge(hclk);
        wait until rising_edge(hclk);
        wait until rising_edge(hclk);
        hresetn <= '1';
        wait until rising_edge(hclk);

        -- ==== Phase A: CPU configures the SIP ====
        cpu_write(hclk, cpu_hbusreq, hgrant0, cpu_haddr, cpu_htrans, cpu_hwrite,
                   cpu_hwdata, hready_bus, hresp_bus, ADDR_CTRL, x"00000001", v_resp);
        check(v_resp = RESP_OKAY, "phase A: CTRL write (enable) returns OKAY");

        -- ==== Phase B/C trigger: BURST_LEN bytes arrive at the SIP's RX side ====
        -- CPU has released the bus (cpu_hbusreq dropped at the end of cpu_write),
        -- so once the DMA collects all BURST_LEN bytes it can win the grant.
        for i in 0 to BURST_LEN - 1 loop
            byte := std_logic_vector(to_unsigned(16#A0# + i, 8));
            wait until rising_edge(hclk); wait for 1 ns;
            rx_byte_valid <= '1'; rx_byte_data <= byte;
            wait until rising_edge(hclk); wait for 1 ns;
            rx_byte_valid <= '0';
            -- give the master wrapper a cycle to consume (dma_consume) before
            -- the next byte arrives, same as a real UART pacing RX bytes
            wait until rising_edge(hclk); wait for 1 ns;
        end loop;

        check(hgrant1 = '1' or dma_hbusreq = '1', "phase B: DMA requested/was granted the bus (HBUSREQ1/HGRANT1)");

        -- ==== Phase C: wait for the burst to finish (dma_done pulses once) ====
        wait until s_dma_done = '1';
        check(true, "phase C: SIP-DMA burst to memory completed (dma_done pulsed)");

        -- ==== Phase D: CPU polls STATUS, then reads back what the DMA wrote ====
        cpu_read(hclk, cpu_hbusreq, hgrant0, cpu_haddr, cpu_htrans, cpu_hwrite,
                  hready_bus, hresp_bus, hrdata_bus, ADDR_STATUS, v_rdata, v_resp);
        check(v_resp = RESP_OKAY and v_rdata(2) = '1', "phase D: STATUS.dma_done == 1 after burst");

        for i in 0 to BURST_LEN - 1 loop
            cpu_read(hclk, cpu_hbusreq, hgrant0, cpu_haddr, cpu_htrans, cpu_hwrite,
                      hready_bus, hresp_bus, hrdata_bus,
                      std_logic_vector(unsigned(MEM_BASE) + to_unsigned(i * 4, 32)),
                      v_rdata, v_resp);
            byte := std_logic_vector(to_unsigned(16#A0# + i, 8));
            check(v_resp = RESP_OKAY and v_rdata(7 downto 0) = byte,
                  "phase D: memory[" & integer'image(i) & "] == byte DMA'd by the SIP");
        end loop;

        report "==== AHB system MSC (A/B/C/D): " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed ====";
        assert fail_count = 0 report "simulation FAILED" severity failure;
        finish;
        wait;
    end process;

end architecture sim;
