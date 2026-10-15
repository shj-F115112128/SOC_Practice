-- AXI master wrapper around the UART SIP's internal DMA engine -- write
-- path only (RX FIFO -> memory), per docs/02-axi-wrapper-fsm.md section 2
-- and Upload/axi_master_fsm.drawio (IDLE -> AW -> W{WLAST} -> BWAIT -> IDLE).
-- (The symmetric read-DMA path for TX, also drawn on that diagram, is not
-- implemented -- it would need a TX-FIFO-threshold abstraction that doesn't
-- exist anywhere else in this project either, AHB side included; see
-- docs/05-rtl-simulation.md.)
--
-- This is a real AXI4 INCR burst (AWLEN/AWBURST + WLAST), not AXI4-Lite --
-- one AWVALID carries the whole transfer's base address and length, then
-- BURST_LEN W beats stream through with WLAST marking the last one, and a
-- single BVALID/BRESP closes the whole burst. (The CPU-facing register file
-- in axi_lite_uart_slave_wrapper.vhd stays AXI4-Lite -- a single-register
-- CSR interface has no reason to carry burst support -- only this
-- DMA-to-memory path needs it, matching axi_mem_slave_bfm.vhd's write side.)
--
-- Trigger/handshake with axi_lite_uart_slave_wrapper is identical to the
-- AHB side (rx_ready_i/rx_data_i, dma_consume_o, dma_done_o): once
-- BURST_LEN bytes have arrived, it issues the burst, then pulses
-- dma_done_o once BVALID arrives.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_uart_master_wrapper is
    generic (
        BURST_LEN : natural := 4
    );
    port (
        aclk    : in  std_logic;
        aresetn : in  std_logic;

        awvalid : out std_logic;
        awaddr  : out std_logic_vector(31 downto 0);
        awlen   : out std_logic_vector(7 downto 0);  -- AXI4: beats - 1
        awburst : out std_logic_vector(1 downto 0);  -- "01" = INCR
        awready : in  std_logic;
        wvalid  : out std_logic;
        wdata   : out std_logic_vector(31 downto 0);
        wlast   : out std_logic;
        wready  : in  std_logic;
        bvalid  : in  std_logic;
        bready  : out std_logic;

        dma_base_addr : in std_logic_vector(31 downto 0) := x"00001000";

        rx_ready_i    : in  std_logic;
        rx_data_i     : in  std_logic_vector(7 downto 0);
        dma_consume_o : out std_logic := '0';
        dma_done_o    : out std_logic := '0'
    );
end entity axi_uart_master_wrapper;

architecture rtl of axi_uart_master_wrapper is

    constant AWBURST_INCR : std_logic_vector(1 downto 0) := "01";

    type state_t is (S_IDLE, S_AW, S_W, S_BWAIT);
    signal state, next_state : state_t := S_IDLE;

    type byte_array_t is array (0 to BURST_LEN - 1) of std_logic_vector(7 downto 0);
    signal buf      : byte_array_t;
    signal byte_cnt : natural range 0 to BURST_LEN := 0;
    signal beat_idx : natural range 0 to BURST_LEN := 0;

begin

    awaddr  <= dma_base_addr;
    awlen   <= std_logic_vector(to_unsigned(BURST_LEN - 1, 8));
    awburst <= AWBURST_INCR;

    -- ---- state register + burst bookkeeping ----
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            state    <= S_IDLE;
            byte_cnt <= 0;
            beat_idx <= 0;
            buf      <= (others => (others => '0'));
        elsif rising_edge(aclk) then
            state <= next_state;

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

                when S_AW =>
                    if awready = '1' then
                        beat_idx <= 0;
                    end if;

                when S_W =>
                    if wready = '1' and beat_idx /= BURST_LEN - 1 then
                        beat_idx <= beat_idx + 1;
                    end if;

                when others =>
                    null;
            end case;
        end if;
    end process;

    -- ---- combinational outputs + next-state ----
    process (state, byte_cnt, beat_idx, buf, rx_ready_i, awready, wready, bvalid)
    begin
        next_state    <= state;
        awvalid       <= '0';
        wvalid        <= '0';
        wdata         <= (others => '0');
        wlast         <= '0';
        bready        <= '0';
        dma_consume_o <= '0';
        dma_done_o    <= '0';

        case state is
            when S_IDLE =>
                if rx_ready_i = '1' then
                    dma_consume_o <= '1';
                    if byte_cnt = BURST_LEN - 1 then
                        next_state <= S_AW;
                    end if;
                end if;

            when S_AW =>
                awvalid <= '1';
                if awready = '1' then
                    next_state <= S_W;
                end if;

            when S_W =>
                wvalid <= '1';
                wdata  <= (31 downto 8 => '0') & buf(beat_idx);
                if beat_idx = BURST_LEN - 1 then
                    wlast <= '1';
                end if;
                if wready = '1' and beat_idx = BURST_LEN - 1 then
                    next_state <= S_BWAIT;
                end if;

            when S_BWAIT =>
                bready <= '1';
                if bvalid = '1' then
                    dma_done_o <= '1';
                    next_state <= S_IDLE;
                end if;
        end case;
    end process;

end architecture rtl;
