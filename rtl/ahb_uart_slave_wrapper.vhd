-- AHB-Lite slave wrapper around a (simplified, modeled-in-register) UART SIP.
-- Implements the slave wrapper FSM from docs/01-ahb-wrapper-fsm.md:
--   IDLE -> NONSEQ -> {WAIT* ->} OKAY -> IDLE   (normal access)
--   IDLE -> NONSEQ -> ERR1 -> ERR2 -> IDLE       (bad address)
--
-- Register map (word-addressed, byte offsets 0x0-0xC):
--   0x0 CTRL   [R/W] bit0 = enable
--   0x4 STATUS [RO]  bit0 = tx_busy, bit1 = rx_ready, bit2 = dma_done
--   0x8 TXDATA [R/W] bits(7:0); a write starts a simulated transmission
--                    (tx_busy held for TX_BUSY_CYCLES cycles). Writing while
--                    tx_busy='1' inserts AHB WAIT states until it clears.
--   0xC RXDATA [RO]  bits(7:0); reading clears rx_ready. Non-blocking: if no
--                    byte has arrived yet, returns the last value with
--                    rx_ready='0' (a real RX-FIFO-empty stall is intentionally
--                    out of scope here -- see docs/05-rtl-simulation.md).
--   >=0x10           any access -> 2-cycle AHB ERROR response.
--
-- rx_ready_o/rx_data_o/ctrl_enable_o and dma_consume/dma_done_set are the
-- hooks used to wire this up to ahb_uart_master_wrapper for the system-level
-- MSC testbench (docs/05): the master wrapper watches rx_ready_o, grabs
-- rx_data_o, pulses dma_consume once it has, bursts the byte to memory, then
-- pulses dma_done_set. All four are additive -- default '0'/open so
-- tb_ahb_uart_slave_wrapper.vhd (which never drives them) is unaffected.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ahb_uart_slave_wrapper is
    port (
        hclk    : in  std_logic;
        hresetn : in  std_logic;

        hsel    : in  std_logic;
        haddr   : in  std_logic_vector(31 downto 0);
        htrans  : in  std_logic_vector(1 downto 0);
        hwrite  : in  std_logic;
        hwdata  : in  std_logic_vector(31 downto 0);
        hready  : in  std_logic;  -- global ready-in (muxed hreadyout)

        hreadyout : out std_logic;
        hresp     : out std_logic_vector(1 downto 0);
        hrdata    : out std_logic_vector(31 downto 0);

        -- test/debug backdoor used by the testbench to emulate a byte arriving
        rx_byte_valid : in std_logic;
        rx_byte_data  : in std_logic_vector(7 downto 0);

        -- additive hooks for ahb_uart_master_wrapper (see register-map comment above)
        rx_ready_o   : out std_logic := '0';
        rx_data_o    : out std_logic_vector(7 downto 0) := (others => '0');
        ctrl_enable_o: out std_logic := '0';
        dma_consume  : in  std_logic := '0';
        dma_done_set : in  std_logic := '0';

        -- out-of-band IRQ (MSC phase D "intr"): level, mirrors dma_done, so it
        -- stays asserted until the CPU services it by reading STATUS
        irq_o        : out std_logic := '0'
    );
end entity ahb_uart_slave_wrapper;

architecture rtl of ahb_uart_slave_wrapper is

    constant HTRANS_IDLE   : std_logic_vector(1 downto 0) := "00";
    constant HTRANS_NONSEQ : std_logic_vector(1 downto 0) := "10";
    constant HTRANS_SEQ    : std_logic_vector(1 downto 0) := "11";

    constant RESP_OKAY  : std_logic_vector(1 downto 0) := "00";
    constant RESP_ERROR : std_logic_vector(1 downto 0) := "01";

    constant ADDR_CTRL   : std_logic_vector(3 downto 0) := x"0";
    constant ADDR_STATUS : std_logic_vector(3 downto 0) := x"4";
    constant ADDR_TXDATA : std_logic_vector(3 downto 0) := x"8";
    constant ADDR_RXDATA : std_logic_vector(3 downto 0) := x"C";

    constant TX_BUSY_CYCLES : unsigned(3 downto 0) := "0100"; -- 4

    type state_t is (S_IDLE, S_NONSEQ, S_WAIT, S_ERR1, S_ERR2);
    signal state, next_state : state_t;

    -- address-phase latch
    signal addr_q      : std_logic_vector(31 downto 0);
    signal write_q      : std_logic;
    signal addr_valid_q : std_logic;

    signal xfer_requested : std_logic;
    signal addr_in_range  : std_logic;

    -- UART register model
    signal ctrl_enable : std_logic;
    signal tx_busy     : std_logic;
    signal tx_busy_cnt : unsigned(3 downto 0);
    signal tx_data     : std_logic_vector(7 downto 0);
    signal rx_ready    : std_logic;
    signal rx_data     : std_logic_vector(7 downto 0);
    signal dma_done    : std_logic;

    signal wait_needed  : std_logic;
    signal commit_write  : std_logic;
    signal commit_read   : std_logic;
    signal hreadyout_i   : std_logic;

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

    rx_ready_o    <= rx_ready;
    rx_data_o     <= rx_data;
    ctrl_enable_o <= ctrl_enable;
    irq_o         <= dma_done;

    xfer_requested <= '1' when (hsel = '1' and hready = '1' and
                                 (htrans = HTRANS_NONSEQ or htrans = HTRANS_SEQ))
                       else '0';

    addr_in_range <= '1' when (haddr(31 downto 4) = (31 downto 4 => '0') and
                                haddr(1 downto 0) = "00")
                      else '0';

    wait_needed <= '1' when (write_q = '1' and addr_q(3 downto 0) = ADDR_TXDATA
                              and tx_busy = '1')
                   else '0';

    -- ---- state register + address-phase latch ----
    process (hclk, hresetn)
    begin
        if hresetn = '0' then
            state        <= S_IDLE;
            addr_q       <= (others => '0');
            write_q      <= '0';
            addr_valid_q <= '0';
        elsif rising_edge(hclk) then
            state <= next_state;
            if xfer_requested = '1' then
                addr_q       <= haddr;
                write_q      <= hwrite;
                addr_valid_q <= addr_in_range;
            end if;
        end if;
    end process;

    -- ---- next-state / output logic ----
    process (state, addr_valid_q, wait_needed, xfer_requested, addr_q,
             ctrl_enable, tx_busy, tx_data, rx_ready, rx_data, dma_done)
    begin
        next_state  <= state;
        hreadyout_i <= '1';
        hresp       <= RESP_OKAY;
        hrdata      <= (others => '0');

        case state is
            when S_IDLE =>
                hreadyout_i <= '1';
                if xfer_requested = '1' then
                    next_state <= S_NONSEQ;
                end if;

            when S_NONSEQ =>
                if addr_valid_q = '0' then
                    hreadyout_i <= '0';
                    hresp       <= RESP_ERROR;
                    next_state  <= S_ERR1;
                elsif wait_needed = '1' then
                    hreadyout_i <= '0';
                    hresp       <= RESP_OKAY;
                    next_state  <= S_WAIT;
                else
                    hreadyout_i <= '1';
                    hresp       <= RESP_OKAY;
                    hrdata      <= reg_rdata(addr_q(3 downto 0), ctrl_enable,
                                              rx_ready, tx_busy, dma_done, tx_data, rx_data);
                    if xfer_requested = '1' then
                        next_state <= S_NONSEQ;
                    else
                        next_state <= S_IDLE;
                    end if;
                end if;

            when S_WAIT =>
                if wait_needed = '0' then
                    hreadyout_i <= '1';
                    hresp       <= RESP_OKAY;
                    hrdata      <= reg_rdata(addr_q(3 downto 0), ctrl_enable,
                                              rx_ready, tx_busy, dma_done, tx_data, rx_data);
                    if xfer_requested = '1' then
                        next_state <= S_NONSEQ;
                    else
                        next_state <= S_IDLE;
                    end if;
                else
                    hreadyout_i <= '0';
                    next_state  <= S_WAIT;
                end if;

            when S_ERR1 =>
                hreadyout_i <= '0';
                hresp       <= RESP_ERROR;
                next_state  <= S_ERR2;

            when S_ERR2 =>
                hreadyout_i <= '1';
                hresp       <= RESP_ERROR;
                if xfer_requested = '1' then
                    next_state <= S_NONSEQ;
                else
                    next_state <= S_IDLE;
                end if;
        end case;
    end process;

    hreadyout <= hreadyout_i;

    -- ---- UART register model: writes commit when a transfer completes OKAY ----
    commit_write <= '1' when (write_q = '1' and addr_valid_q = '1' and
                               ((state = S_NONSEQ and wait_needed = '0' and hreadyout_i = '1') or
                                (state = S_WAIT and wait_needed = '0')))
                     else '0';

    commit_read <= '1' when (write_q = '0' and addr_valid_q = '1' and
                              ((state = S_NONSEQ and wait_needed = '0' and hreadyout_i = '1') or
                               (state = S_WAIT and wait_needed = '0')))
                    else '0';

    process (hclk, hresetn)
    begin
        if hresetn = '0' then
            ctrl_enable <= '0';
            tx_busy     <= '0';
            tx_busy_cnt <= (others => '0');
            tx_data     <= (others => '0');
            rx_ready    <= '0';
            rx_data     <= (others => '0');
            dma_done    <= '0';
        elsif rising_edge(hclk) then
            -- simulated TX shift: busy counts down to 0 on its own
            if tx_busy = '1' then
                if tx_busy_cnt = to_unsigned(1, 4) then
                    tx_busy     <= '0';
                    tx_busy_cnt <= (others => '0');
                else
                    tx_busy_cnt <= tx_busy_cnt - 1;
                end if;
            end if;

            -- the DMA (ahb_uart_master_wrapper) consumed the previously-latched
            -- byte; a fresh arrival this same cycle (below) takes priority
            if dma_consume = '1' then
                rx_ready <= '0';
            end if;

            -- simulated RX arrival (testbench-driven backdoor)
            if rx_byte_valid = '1' then
                rx_data  <= rx_byte_data;
                rx_ready <= '1';
            end if;

            -- DMA burst-to-memory completed; CPU reading STATUS clears it
            if dma_done_set = '1' then
                dma_done <= '1';
            elsif commit_read = '1' and addr_q(3 downto 0) = ADDR_STATUS then
                dma_done <= '0';
            end if;

            if commit_write = '1' then
                case addr_q(3 downto 0) is
                    when ADDR_CTRL =>
                        ctrl_enable <= hwdata(0);
                    when ADDR_TXDATA =>
                        tx_data     <= hwdata(7 downto 0);
                        tx_busy     <= '1';
                        tx_busy_cnt <= TX_BUSY_CYCLES;
                    when others =>
                        null; -- STATUS/RXDATA are read-only, ignore writes
                end case;
            end if;

            if commit_read = '1' and addr_q(3 downto 0) = ADDR_RXDATA then
                rx_ready <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
