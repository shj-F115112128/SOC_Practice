-- Fixed-priority AHB arbiter (CPU > DMA), implementing the FSM from
-- docs/01-ahb-wrapper-fsm.md section 3 (Upload/ahb_arbiter_fsm.drawio):
--   GRANT_NONE <-> GRANT_CPU <-> GRANT_DMA
-- Grant only switches when the target master is requesting and the
-- currently-granted master has released its own request (hbusreqX='0') --
-- i.e. masters are expected to drop hbusreq only once they've reached a
-- safe transfer boundary, so the arbiter itself doesn't need to track
-- HBURST/HTRANS beat-counting to detect "mid-burst".

library ieee;
use ieee.std_logic_1164.all;

entity ahb_arbiter is
    port (
        hclk    : in std_logic;
        hresetn : in std_logic;

        hbusreq0 : in std_logic;  -- CPU
        hbusreq1 : in std_logic;  -- SIP-DMA
        hready   : in std_logic;  -- global (muxed) ready

        hgrant0 : out std_logic;
        hgrant1 : out std_logic
    );
end entity ahb_arbiter;

architecture rtl of ahb_arbiter is

    type state_t is (GRANT_NONE, GRANT_CPU, GRANT_DMA);
    signal state, next_state : state_t;

begin

    process (hclk, hresetn)
    begin
        if hresetn = '0' then
            state <= GRANT_NONE;
        elsif rising_edge(hclk) then
            state <= next_state;
        end if;
    end process;

    process (state, hbusreq0, hbusreq1, hready)
    begin
        next_state <= state;
        case state is
            when GRANT_NONE =>
                if hbusreq0 = '1' and hready = '1' then
                    next_state <= GRANT_CPU;
                elsif hbusreq0 = '0' and hbusreq1 = '1' and hready = '1' then
                    next_state <= GRANT_DMA;
                end if;

            when GRANT_CPU =>
                -- CPU keeps priority even if DMA is also requesting
                if hbusreq0 = '0' and hbusreq1 = '1' and hready = '1' then
                    next_state <= GRANT_DMA;
                elsif hbusreq0 = '0' and hbusreq1 = '0' and hready = '1' then
                    next_state <= GRANT_NONE;
                end if;

            when GRANT_DMA =>
                -- non-preemptive: only cede the grant once DMA drops hbusreq1
                -- itself (a mid-burst master never checks hgrant again, so
                -- the arbiter must never switch out from under it)
                if hbusreq1 = '0' and hbusreq0 = '1' and hready = '1' then
                    next_state <= GRANT_CPU;
                elsif hbusreq1 = '0' and hbusreq0 = '0' and hready = '1' then
                    next_state <= GRANT_NONE;
                end if;
        end case;
    end process;

    hgrant0 <= '1' when state = GRANT_CPU else '0';
    hgrant1 <= '1' when state = GRANT_DMA else '0';

end architecture rtl;
