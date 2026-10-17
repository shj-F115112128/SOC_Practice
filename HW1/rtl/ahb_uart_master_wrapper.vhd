-- AHB master wrapper around the UART SIP's internal DMA engine.
-- Implements the FSM from docs/01-ahb-wrapper-fsm.md section 2
-- (Upload/ahb_master_fsm.drawio):
--   IDLE -> REQ -> NONSEQ -> SEQ(*) -> LAST -> DONE -> IDLE
-- (SEQ's self-loop in the diagram is the "insert a BUSY beat while
--  collecting/waiting on FIFO" case, folded into this one state.)
--
-- Trigger: this models the RX-side DMA only (MSC phase B/C in
-- docs/03-msc-ahb.md): once BURST_LEN bytes have arrived from the slave
-- wrapper (rx_ready_i/rx_data_i, consumed one at a time via dma_consume_o,
-- same handshake as ahb_uart_slave_wrapper's additive hooks), it requests
-- the bus (HBUSREQ1), and once granted bursts all BURST_LEN bytes out as
-- one word each (zero-padded) to sequential addresses starting at
-- dma_base_addr using NONSEQ + SEQ beats.
--
-- Like the slave wrapper, outputs are purely combinational functions of
-- the current state/registers (one process), with state/burst bookkeeping
-- in a second, clocked process -- except HWDATA, which is an explicit
-- one-cycle pipeline register (hwdata_q) behind HADDR/HTRANS, matching
-- standard AHB write timing (the data phase of beat N coincides with the
-- address phase of beat N+1) and what ahb_mem_slave_bfm expects.
--
-- On completion it pulses dma_done_o once (consumed by the slave
-- wrapper's dma_done_set, which sets STATUS.dma_done for the CPU to
-- observe in MSC phase D) and drops HBUSREQ1.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ahb_uart_master_wrapper is
    generic (
        BURST_LEN : natural := 4
    );
    port (
        hclk    : in  std_logic;
        hresetn : in  std_logic;

        -- AHB master side (arbitrated bus)
        hbusreq : out std_logic;
        hgrant  : in  std_logic;
        haddr   : out std_logic_vector(31 downto 0);
        htrans  : out std_logic_vector(1 downto 0);
        hwrite  : out std_logic;
        hwdata  : out std_logic_vector(31 downto 0);
        hready  : in  std_logic;  -- global (muxed) ready
        hresp   : in  std_logic_vector(1 downto 0);

        dma_base_addr : in std_logic_vector(31 downto 0) := x"00001000";

        -- handshake with ahb_uart_slave_wrapper
        rx_ready_i    : in  std_logic;
        rx_data_i     : in  std_logic_vector(7 downto 0);
        dma_consume_o : out std_logic := '0';
        dma_done_o    : out std_logic := '0'
    );
end entity ahb_uart_master_wrapper;

architecture rtl of ahb_uart_master_wrapper is

    constant HTRANS_IDLE   : std_logic_vector(1 downto 0) := "00";
    constant HTRANS_NONSEQ : std_logic_vector(1 downto 0) := "10";
    constant HTRANS_SEQ    : std_logic_vector(1 downto 0) := "11";
    constant RESP_OKAY     : std_logic_vector(1 downto 0) := "00";

    type state_t is (S_IDLE, S_REQ, S_NONSEQ, S_SEQ, S_LAST, S_DONE, S_ERR1, S_ERR2);
    signal state, next_state : state_t := S_IDLE;

    type byte_array_t is array (0 to BURST_LEN - 1) of std_logic_vector(7 downto 0);
    signal buf      : byte_array_t;
    signal byte_cnt : natural range 0 to BURST_LEN := 0;
    signal beat_idx : natural range 0 to BURST_LEN := 0; -- beat currently on the address phase

    signal addr_reg : unsigned(31 downto 0);

    signal pending_wdata : std_logic_vector(31 downto 0);
    signal hwdata_q      : std_logic_vector(31 downto 0);

begin

    hwdata <= hwdata_q;

    -- ---- state register + burst bookkeeping ----
    process (hclk, hresetn)
    begin
        if hresetn = '0' then
            state    <= S_IDLE;
            byte_cnt <= 0;
            beat_idx <= 0;
            addr_reg <= (others => '0');
            buf      <= (others => (others => '0'));
            hwdata_q <= (others => '0');
        elsif rising_edge(hclk) then
            state    <= next_state;
            hwdata_q <= pending_wdata; -- 1-cycle pipeline: data phase trails address phase

            case state is
                when S_IDLE =>
                    if rx_ready_i = '1' then
                        buf(byte_cnt) <= rx_data_i;
                        if byte_cnt = BURST_LEN - 1 then
                            byte_cnt <= 0;
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;
                    end if;

                when S_REQ =>
                    if hgrant = '1' and hready = '1' then
                        addr_reg <= unsigned(dma_base_addr);
                        beat_idx <= 0;
                    end if;

                when S_NONSEQ | S_SEQ =>
                    if hready = '1' then
                        addr_reg <= addr_reg + 4;
                        beat_idx <= beat_idx + 1;
                    end if;

                when others =>
                    null;
            end case;
        end if;
    end process;

    -- ---- combinational outputs + next-state ----
    process (state, byte_cnt, beat_idx, addr_reg, buf, rx_ready_i, hgrant, hready, hresp)
    begin
        next_state    <= state;
        hbusreq       <= '0';
        haddr         <= (others => '0');
        htrans        <= HTRANS_IDLE;
        hwrite        <= '0';
        dma_consume_o <= '0';
        dma_done_o    <= '0';
        pending_wdata <= hwdata_q;

        case state is
            when S_IDLE =>
                if rx_ready_i = '1' then
                    dma_consume_o <= '1';
                    if byte_cnt = BURST_LEN - 1 then
                        next_state <= S_REQ;
                    end if;
                end if;

            when S_REQ =>
                hbusreq <= '1';
                if hgrant = '1' and hready = '1' then
                    next_state <= S_NONSEQ;
                end if;

            when S_NONSEQ =>
                hbusreq       <= '1';
                haddr         <= std_logic_vector(addr_reg);
                htrans        <= HTRANS_NONSEQ;
                hwrite        <= '1';
                pending_wdata <= (31 downto 8 => '0') & buf(beat_idx);
                if hready = '1' then
                    if BURST_LEN = 1 then
                        next_state <= S_LAST;
                    else
                        next_state <= S_SEQ;
                    end if;
                end if;

            when S_SEQ =>
                hbusreq <= '1';
                if hresp /= RESP_OKAY then
                    if hready = '1' then
                        next_state <= S_ERR1;
                    end if;
                else
                    haddr         <= std_logic_vector(addr_reg);
                    htrans        <= HTRANS_SEQ;
                    hwrite        <= '1';
                    pending_wdata <= (31 downto 8 => '0') & buf(beat_idx);
                    if hready = '1' and beat_idx = BURST_LEN - 1 then
                        next_state <= S_LAST;
                    end if;
                end if;

            when S_LAST =>
                -- no more address phases; let the final beat's data phase land
                hbusreq <= '1';
                if hready = '1' then
                    next_state <= S_DONE;
                end if;

            when S_DONE =>
                dma_done_o <= '1';
                next_state <= S_IDLE;

            when S_ERR1 =>
                if hready = '1' then
                    next_state <= S_ERR2;
                end if;

            when S_ERR2 =>
                next_state <= S_IDLE;
        end case;
    end process;

end architecture rtl;
