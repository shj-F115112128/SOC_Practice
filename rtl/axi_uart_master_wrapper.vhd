-- AXI master wrapper around the UART SIP's internal DMA engine -- write
-- path only (RX FIFO -> memory), per docs/02-axi-wrapper-fsm.md section 2
-- (the read-DMA path for TX is the symmetric, undrawn case, same as the
-- AHB master wrapper's scope).
--
-- Trigger/handshake with axi_lite_uart_slave_wrapper is identical to the
-- AHB side (rx_ready_i/rx_data_i, dma_consume_o, dma_done_o): once
-- BURST_LEN bytes have arrived, it issues BURST_LEN independent AXI4-Lite
-- write transactions (AXI4-Lite has no protocol-level burst -- each beat is
-- its own AW/W/B exchange) to sequential word addresses starting at
-- dma_base_addr, then pulses dma_done_o once.
--
-- One state machine, combinational outputs from current state (same style
-- as the other wrappers); AWADDR/WDATA are registered (awaddr_r/wdata_r)
-- since they must hold steady across however many cycles AWREADY/WREADY
-- each take to arrive.

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
        awready : in  std_logic;
        wvalid  : out std_logic;
        wdata   : out std_logic_vector(31 downto 0);
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

    type state_t is (S_IDLE, S_AW, S_W, S_B, S_DONE);
    signal state, next_state : state_t := S_IDLE;

    type byte_array_t is array (0 to BURST_LEN - 1) of std_logic_vector(7 downto 0);
    signal buf      : byte_array_t;
    signal byte_cnt : natural range 0 to BURST_LEN := 0;
    signal beat_idx : natural range 0 to BURST_LEN := 0;

    signal awaddr_r : std_logic_vector(31 downto 0);
    signal wdata_r  : std_logic_vector(31 downto 0);

begin

    awaddr <= awaddr_r;
    wdata  <= wdata_r;

    -- ---- state register + burst bookkeeping ----
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            state    <= S_IDLE;
            byte_cnt <= 0;
            beat_idx <= 0;
            awaddr_r <= (others => '0');
            wdata_r  <= (others => '0');
            buf      <= (others => (others => '0'));
        elsif rising_edge(aclk) then
            state <= next_state;

            case state is
                when S_IDLE =>
                    if rx_ready_i = '1' then
                        buf(byte_cnt) <= rx_data_i;
                        if byte_cnt = BURST_LEN - 1 then
                            byte_cnt <= 0;
                            beat_idx <= 0;
                            -- first beat (buf(0) was latched on an earlier
                            -- S_IDLE iteration, not this cycle's rx_data_i)
                            awaddr_r <= dma_base_addr;
                            wdata_r  <= (31 downto 8 => '0') & buf(0);
                        else
                            byte_cnt <= byte_cnt + 1;
                        end if;
                    end if;

                when S_B =>
                    if bvalid = '1' and bready = '1' and beat_idx /= BURST_LEN - 1 then
                        beat_idx <= beat_idx + 1;
                        awaddr_r <= std_logic_vector(unsigned(dma_base_addr) +
                                                       to_unsigned((beat_idx + 1) * 4, 32));
                        wdata_r  <= (31 downto 8 => '0') & buf(beat_idx + 1);
                    end if;

                when others =>
                    null;
            end case;
        end if;
    end process;

    -- ---- combinational outputs + next-state ----
    process (state, byte_cnt, beat_idx, awready, wready, bvalid, rx_ready_i)
    begin
        next_state    <= state;
        awvalid       <= '0';
        wvalid        <= '0';
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
                if wready = '1' then
                    next_state <= S_B;
                end if;

            when S_B =>
                bready <= '1';
                if bvalid = '1' then
                    if beat_idx = BURST_LEN - 1 then
                        next_state <= S_DONE;
                    else
                        next_state <= S_AW;
                    end if;
                end if;

            when S_DONE =>
                dma_done_o <= '1';
                next_state <= S_IDLE;
        end case;
    end process;

end architecture rtl;
