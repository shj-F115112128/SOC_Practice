-- AXI4-Lite slave wrapper around the same simplified UART SIP register model
-- as rtl/ahb_uart_slave_wrapper.vhd (same map, same behavior), implementing
-- the independent write/read channel FSMs from docs/02-axi-wrapper-fsm.md:
--   Write: IDLE -> WADDR -> WDATA{wait*} -> RESP -> IDLE
--   Read:  IDLE -> RADDR -> RDATA -> IDLE
--
-- Register map (word-addressed, byte offsets 0x0-0xC) -- identical to the
-- AHB version so the two wrappers are directly comparable:
--   0x0 CTRL   [R/W] bit0 = enable
--   0x4 STATUS [RO]  bit0 = tx_busy, bit1 = rx_ready, bit2 = dma_done
--   0x8 TXDATA [R/W] bits(7:0); write starts a simulated transmission
--                    (tx_busy for TX_BUSY_CYCLES cycles). A write while
--                    tx_busy='1' deasserts wready (back-pressure) until clear.
--   0xC RXDATA [RO]  bits(7:0); reading clears rx_ready. Non-blocking, same
--                    simplification as the AHB version.
--   >=0x10           SLVERR on BRESP/RRESP.
--
-- rx_ready_o/rx_data_o and dma_consume/dma_done_set are the additive hooks
-- used to wire this up to axi_uart_master_wrapper for the system-level MSC
-- testbench (docs/05) -- same convention as ahb_uart_slave_wrapper's hooks.
-- All default '0'/open so tb_axi_lite_uart_slave_wrapper.vhd (which never
-- drives them) is unaffected.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_lite_uart_slave_wrapper is
    port (
        aclk    : in std_logic;
        aresetn : in std_logic;

        -- write address channel
        awvalid : in  std_logic;
        awaddr  : in  std_logic_vector(31 downto 0);
        awready : out std_logic;
        -- write data channel
        wvalid  : in  std_logic;
        wdata   : in  std_logic_vector(31 downto 0);
        wstrb   : in  std_logic_vector(3 downto 0);
        wready  : out std_logic;
        -- write response channel
        bvalid  : out std_logic;
        bresp   : out std_logic_vector(1 downto 0);
        bready  : in  std_logic;

        -- read address channel
        arvalid : in  std_logic;
        araddr  : in  std_logic_vector(31 downto 0);
        arready : out std_logic;
        -- read data channel
        rvalid  : out std_logic;
        rdata   : out std_logic_vector(31 downto 0);
        rresp   : out std_logic_vector(1 downto 0);
        rready  : in  std_logic;

        -- test/debug backdoor used by the testbench to emulate a byte arriving
        rx_byte_valid : in std_logic;
        rx_byte_data  : in std_logic_vector(7 downto 0);

        -- additive hooks for axi_uart_master_wrapper (see register-map comment above)
        rx_ready_o   : out std_logic := '0';
        rx_data_o    : out std_logic_vector(7 downto 0) := (others => '0');
        dma_consume  : in  std_logic := '0';
        dma_done_set : in  std_logic := '0';

        -- out-of-band IRQ (MSC phase C "intr"): level, mirrors dma_done, so it
        -- stays asserted until the CPU services it by reading STATUS
        irq_o        : out std_logic := '0'
    );
end entity axi_lite_uart_slave_wrapper;

architecture rtl of axi_lite_uart_slave_wrapper is

    constant RESP_OKAY  : std_logic_vector(1 downto 0) := "00";
    constant RESP_ERROR : std_logic_vector(1 downto 0) := "10"; -- SLVERR

    constant ADDR_CTRL   : std_logic_vector(3 downto 0) := x"0";
    constant ADDR_STATUS : std_logic_vector(3 downto 0) := x"4";
    constant ADDR_TXDATA : std_logic_vector(3 downto 0) := x"8";
    constant ADDR_RXDATA : std_logic_vector(3 downto 0) := x"C";

    constant TX_BUSY_CYCLES : unsigned(3 downto 0) := "0100"; -- 4

    type wstate_t is (WS_IDLE, WS_WDATA, WS_RESP);
    type rstate_t is (RS_IDLE, RS_DATA);

    signal wstate, wnext : wstate_t;
    signal rstate, rnext : rstate_t;

    signal awaddr_q     : std_logic_vector(31 downto 0);
    signal awaddr_valid : std_logic;

    signal araddr_q     : std_logic_vector(31 downto 0);
    signal araddr_valid : std_logic;

    -- UART register model (identical behavior to the AHB wrapper)
    signal ctrl_enable : std_logic;
    signal tx_busy     : std_logic;
    signal tx_busy_cnt : unsigned(3 downto 0);
    signal tx_data     : std_logic_vector(7 downto 0);
    signal rx_ready    : std_logic;
    signal rx_data     : std_logic_vector(7 downto 0);
    signal dma_done    : std_logic;

    signal wait_needed   : std_logic;
    signal commit_write   : std_logic;
    signal commit_read    : std_logic; -- RXDATA-specific: clears rx_ready
    signal read_ok        : std_logic; -- any successful read, any address
    signal awready_i, wready_i, bvalid_i : std_logic;
    signal arready_i, rvalid_i           : std_logic;
    signal bresp_i, rresp_i              : std_logic_vector(1 downto 0);

    function reg_rdata(sel : std_logic_vector(3 downto 0);
                        ctrl_enable, rx_ready, tx_busy, dma_done : std_logic;
                        tx_data, rx_data : std_logic_vector(7 downto 0))
        return std_logic_vector is
    begin
        case sel is
            when ADDR_CTRL   => return (31 downto 1 => '0') & ctrl_enable;
            when ADDR_STATUS => return (31 downto 3 => '0') & dma_done & rx_ready & tx_busy;
            when ADDR_TXDATA => return (31 downto 8 => '0') & tx_data;
            when ADDR_RXDATA => return (31 downto 8 => '0') & rx_data;
            when others      => return (31 downto 0 => '0');
        end case;
    end function;

begin

    rx_ready_o <= rx_ready;
    rx_data_o  <= rx_data;
    irq_o      <= dma_done;

    awaddr_valid <= '1' when (awaddr_q(31 downto 4) = (31 downto 4 => '0') and
                               awaddr_q(1 downto 0) = "00")
                     else '0';

    araddr_valid <= '1' when (araddr_q(31 downto 4) = (31 downto 4 => '0') and
                               araddr_q(1 downto 0) = "00")
                     else '0';

    wait_needed <= '1' when (awaddr_valid = '1' and awaddr_q(3 downto 0) = ADDR_TXDATA
                              and tx_busy = '1')
                   else '0';

    -- ---------------- write address channel ----------------
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
        end if;
    end process;

    process (wstate, awvalid, wvalid, wait_needed, bready, awaddr_valid)
    begin
        wnext     <= wstate;
        awready_i <= '0';
        wready_i  <= '0';
        bvalid_i  <= '0';
        bresp_i   <= RESP_OKAY;
        case wstate is
            when WS_IDLE =>
                awready_i <= '1';
                if awvalid = '1' then
                    wnext <= WS_WDATA;
                end if;
            when WS_WDATA =>
                wready_i <= not wait_needed;
                if wvalid = '1' and wait_needed = '0' then
                    wnext <= WS_RESP;
                end if;
            when WS_RESP =>
                bvalid_i <= '1';
                if awaddr_valid = '1' then
                    bresp_i <= RESP_OKAY;
                else
                    bresp_i <= RESP_ERROR;
                end if;
                if bready = '1' then
                    wnext <= WS_IDLE;
                end if;
        end case;
    end process;

    awready <= awready_i;
    wready  <= wready_i;
    bvalid  <= bvalid_i;
    bresp   <= bresp_i;

    commit_write <= '1' when (wstate = WS_WDATA and wvalid = '1' and wready_i = '1'
                               and awaddr_valid = '1')
                     else '0';

    -- ---------------- read address + data channel ----------------
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

    process (rstate, arvalid, rready, araddr_valid, araddr_q,
             ctrl_enable, tx_busy, tx_data, rx_ready, rx_data, dma_done)
    begin
        rnext      <= rstate;
        arready_i  <= '0';
        rvalid_i   <= '0';
        rresp_i    <= RESP_OKAY;
        rdata      <= (others => '0');
        case rstate is
            when RS_IDLE =>
                arready_i <= '1';
                if arvalid = '1' then
                    rnext <= RS_DATA;
                end if;
            when RS_DATA =>
                rvalid_i <= '1';
                if araddr_valid = '1' then
                    rresp_i <= RESP_OKAY;
                    rdata   <= reg_rdata(araddr_q(3 downto 0), ctrl_enable,
                                          rx_ready, tx_busy, dma_done, tx_data, rx_data);
                else
                    rresp_i <= RESP_ERROR;
                end if;
                if rready = '1' then
                    rnext <= RS_IDLE;
                end if;
        end case;
    end process;

    arready <= arready_i;
    rvalid  <= rvalid_i;
    rresp   <= rresp_i;

    commit_read <= '1' when (rstate = RS_DATA and rready = '1' and araddr_valid = '1'
                              and araddr_q(3 downto 0) = ADDR_RXDATA)
                    else '0';

    read_ok <= '1' when (rstate = RS_DATA and rready = '1' and araddr_valid = '1')
               else '0';

    -- ---------------- UART register model ----------------
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            ctrl_enable <= '0';
            tx_busy     <= '0';
            tx_busy_cnt <= (others => '0');
            tx_data     <= (others => '0');
            rx_ready    <= '0';
            rx_data     <= (others => '0');
            dma_done    <= '0';
        elsif rising_edge(aclk) then
            if tx_busy = '1' then
                if tx_busy_cnt = to_unsigned(1, 4) then
                    tx_busy     <= '0';
                    tx_busy_cnt <= (others => '0');
                else
                    tx_busy_cnt <= tx_busy_cnt - 1;
                end if;
            end if;

            if dma_consume = '1' then
                rx_ready <= '0';
            end if;

            if rx_byte_valid = '1' then
                rx_data  <= rx_byte_data;
                rx_ready <= '1';
            end if;

            if dma_done_set = '1' then
                dma_done <= '1';
            elsif read_ok = '1' and araddr_q(3 downto 0) = ADDR_STATUS then
                dma_done <= '0';
            end if;

            if commit_write = '1' then
                case awaddr_q(3 downto 0) is
                    when ADDR_CTRL =>
                        ctrl_enable <= wdata(0);
                    when ADDR_TXDATA =>
                        tx_data     <= wdata(7 downto 0);
                        tx_busy     <= '1';
                        tx_busy_cnt <= TX_BUSY_CYCLES;
                    when others =>
                        null; -- STATUS/RXDATA are read-only
                end case;
            end if;

            if commit_read = '1' then
                rx_ready <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
