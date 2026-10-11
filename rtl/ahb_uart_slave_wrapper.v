// AHB-Lite slave wrapper around a (simplified, modeled-in-register) UART SIP.
// Implements the slave wrapper FSM from docs/01-ahb-wrapper-fsm.md:
//   IDLE -> NONSEQ -> {WAIT* -> } OKAY -> IDLE   (normal access)
//   IDLE -> NONSEQ -> ERR1 -> ERR2 -> IDLE        (bad address)
//
// Register map (word-addressed, byte offsets 0x0-0xC):
//   0x0 CTRL   [R/W] bit0 = enable
//   0x4 STATUS [RO]  bit0 = tx_busy, bit1 = rx_ready
//   0x8 TXDATA [R/W] bits[7:0]; a write starts a simulated transmission
//                    (tx_busy held for TX_BUSY_CYCLES cycles). Writing while
//                    tx_busy=1 inserts AHB WAIT states until it clears.
//   0xC RXDATA [RO]  bits[7:0]; reading clears rx_ready. Non-blocking: if no
//                    byte has arrived yet, returns the last value with
//                    rx_ready=0 (a real RX-FIFO-empty stall is intentionally
//                    out of scope here — see docs/05-rtl-simulation.md).
//   >=0x10           any access -> 2-cycle AHB ERROR response.
module ahb_uart_slave_wrapper (
    input  wire        HCLK,
    input  wire        HRESETn,

    input  wire         HSEL,
    input  wire [31:0]  HADDR,
    input  wire [1:0]   HTRANS,
    input  wire         HWRITE,
    input  wire [31:0]  HWDATA,
    input  wire         HREADY,     // global ready-in (muxed HREADYOUT)

    output reg          HREADYOUT,
    output reg  [1:0]   HRESP,
    output reg  [31:0]  HRDATA,

    // test/debug backdoor used by the testbench to emulate a byte arriving
    input  wire         rx_byte_valid,
    input  wire [7:0]   rx_byte_data
);

    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_BUSY   = 2'b01;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] HTRANS_SEQ    = 2'b11;

    localparam [1:0] RESP_OKAY  = 2'b00;
    localparam [1:0] RESP_ERROR = 2'b01;

    localparam [3:0] ADDR_CTRL   = 4'h0;
    localparam [3:0] ADDR_STATUS = 4'h4;
    localparam [3:0] ADDR_TXDATA = 4'h8;
    localparam [3:0] ADDR_RXDATA = 4'hC;

    localparam [3:0] TX_BUSY_CYCLES = 4'd4;

    // FSM states, named to match docs/01-ahb-wrapper-fsm.md
    localparam [2:0] S_IDLE   = 3'd0,
                      S_NONSEQ = 3'd1,
                      S_WAIT   = 3'd2,
                      S_ERR1   = 3'd3,
                      S_ERR2   = 3'd4;

    reg [2:0] state, next_state;

    // address-phase latch
    reg [31:0] addr_q;
    reg        write_q;
    reg        addr_valid_q;

    wire xfer_requested = HSEL && HREADY &&
                           (HTRANS == HTRANS_NONSEQ || HTRANS == HTRANS_SEQ);
    wire addr_in_range  = (HADDR[31:4] == 28'd0) && (HADDR[1:0] == 2'b00);

    // UART register model
    reg       ctrl_enable;
    reg       tx_busy;
    reg [3:0] tx_busy_cnt;
    reg [7:0] tx_data;
    reg       rx_ready;
    reg [7:0] rx_data;

    wire wait_needed = write_q && (addr_q[3:0] == ADDR_TXDATA) && tx_busy;

    // ---- state register + address-phase latch ----
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            state        <= S_IDLE;
            addr_q       <= 32'd0;
            write_q      <= 1'b0;
            addr_valid_q <= 1'b0;
        end else begin
            state <= next_state;
            if (xfer_requested) begin
                addr_q       <= HADDR;
                write_q      <= HWRITE;
                addr_valid_q <= addr_in_range;
            end
        end
    end

    // ---- next-state / output logic ----
    always @(*) begin
        next_state = state;
        HREADYOUT  = 1'b1;
        HRESP      = RESP_OKAY;
        HRDATA     = 32'd0;

        case (state)
            S_IDLE: begin
                HREADYOUT  = 1'b1;
                if (xfer_requested) next_state = S_NONSEQ;
            end

            S_NONSEQ: begin
                if (!addr_valid_q) begin
                    HREADYOUT  = 1'b0;
                    HRESP      = RESP_ERROR;
                    next_state = S_ERR1;
                end else if (wait_needed) begin
                    HREADYOUT  = 1'b0;
                    HRESP      = RESP_OKAY;
                    next_state = S_WAIT;
                end else begin
                    HREADYOUT  = 1'b1;
                    HRESP      = RESP_OKAY;
                    case (addr_q[3:0])
                        ADDR_CTRL:   HRDATA = {31'd0, ctrl_enable};
                        ADDR_STATUS: HRDATA = {30'd0, rx_ready, tx_busy};
                        ADDR_TXDATA: HRDATA = {24'd0, tx_data};
                        ADDR_RXDATA: HRDATA = {24'd0, rx_data};
                        default:     HRDATA = 32'd0;
                    endcase
                    next_state = xfer_requested ? S_NONSEQ : S_IDLE;
                end
            end

            S_WAIT: begin
                if (!wait_needed) begin
                    HREADYOUT = 1'b1;
                    HRESP     = RESP_OKAY;
                    case (addr_q[3:0])
                        ADDR_CTRL:   HRDATA = {31'd0, ctrl_enable};
                        ADDR_STATUS: HRDATA = {30'd0, rx_ready, tx_busy};
                        ADDR_TXDATA: HRDATA = {24'd0, tx_data};
                        ADDR_RXDATA: HRDATA = {24'd0, rx_data};
                        default:     HRDATA = 32'd0;
                    endcase
                    next_state = xfer_requested ? S_NONSEQ : S_IDLE;
                end else begin
                    HREADYOUT  = 1'b0;
                    next_state = S_WAIT;
                end
            end

            S_ERR1: begin
                HREADYOUT  = 1'b0;
                HRESP      = RESP_ERROR;
                next_state = S_ERR2;
            end

            S_ERR2: begin
                HREADYOUT  = 1'b1;
                HRESP      = RESP_ERROR;
                next_state = xfer_requested ? S_NONSEQ : S_IDLE;
            end

            default: next_state = S_IDLE;
        endcase
    end

    // ---- UART register model: writes commit when a transfer completes OKAY ----
    wire commit_write = write_q && addr_valid_q &&
                         ((state == S_NONSEQ && !wait_needed && HREADYOUT) ||
                          (state == S_WAIT && !wait_needed));
    wire commit_read  = !write_q && addr_valid_q &&
                         ((state == S_NONSEQ && !wait_needed && HREADYOUT) ||
                          (state == S_WAIT && !wait_needed));

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            ctrl_enable <= 1'b0;
            tx_busy     <= 1'b0;
            tx_busy_cnt <= 4'd0;
            tx_data     <= 8'd0;
            rx_ready    <= 1'b0;
            rx_data     <= 8'd0;
        end else begin
            // simulated TX shift: busy counts down to 0 on its own
            if (tx_busy) begin
                if (tx_busy_cnt == 4'd1) begin
                    tx_busy     <= 1'b0;
                    tx_busy_cnt <= 4'd0;
                end else begin
                    tx_busy_cnt <= tx_busy_cnt - 4'd1;
                end
            end

            // simulated RX arrival (testbench-driven backdoor)
            if (rx_byte_valid) begin
                rx_data  <= rx_byte_data;
                rx_ready <= 1'b1;
            end

            if (commit_write) begin
                case (addr_q[3:0])
                    ADDR_CTRL: ctrl_enable <= HWDATA[0];
                    ADDR_TXDATA: begin
                        tx_data     <= HWDATA[7:0];
                        tx_busy     <= 1'b1;
                        tx_busy_cnt <= TX_BUSY_CYCLES;
                    end
                    default: ; // STATUS/RXDATA are read-only, ignore writes
                endcase
            end

            if (commit_read && addr_q[3:0] == ADDR_RXDATA) begin
                rx_ready <= 1'b0;
            end
        end
    end

endmodule
