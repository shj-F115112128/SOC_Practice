// AXI4-Lite slave wrapper around the same simplified UART SIP register model
// as rtl/ahb_uart_slave_wrapper.v (same map, same behavior), implementing the
// independent write/read channel FSMs from docs/02-axi-wrapper-fsm.md:
//   Write: IDLE -> WADDR -> WDATA{wait*} -> RESP -> IDLE
//   Read:  IDLE -> RADDR -> RDATA -> IDLE
//
// Register map (word-addressed, byte offsets 0x0-0xC) -- identical to the
// AHB version so the two wrappers are directly comparable:
//   0x0 CTRL   [R/W] bit0 = enable
//   0x4 STATUS [RO]  bit0 = tx_busy, bit1 = rx_ready
//   0x8 TXDATA [R/W] bits[7:0]; write starts a simulated transmission
//                    (tx_busy for TX_BUSY_CYCLES cycles). A write while
//                    tx_busy=1 deasserts WREADY (back-pressure) until clear.
//   0xC RXDATA [RO]  bits[7:0]; reading clears rx_ready. Non-blocking, same
//                    simplification as the AHB version.
//   >=0x10           SLVERR on BRESP/RRESP.
module axi_lite_uart_slave_wrapper (
    input  wire        ACLK,
    input  wire        ARESETn,

    // write address channel
    input  wire         AWVALID,
    input  wire [31:0]  AWADDR,
    output reg           AWREADY,
    // write data channel
    input  wire         WVALID,
    input  wire [31:0]  WDATA,
    input  wire [3:0]   WSTRB,
    output reg           WREADY,
    // write response channel
    output reg           BVALID,
    output reg  [1:0]   BRESP,
    input  wire         BREADY,

    // read address channel
    input  wire         ARVALID,
    input  wire [31:0]  ARADDR,
    output reg           ARREADY,
    // read data channel
    output reg           RVALID,
    output reg  [31:0]  RDATA,
    output reg  [1:0]   RRESP,
    input  wire         RREADY,

    // test/debug backdoor used by the testbench to emulate a byte arriving
    input  wire         rx_byte_valid,
    input  wire [7:0]   rx_byte_data
);

    localparam [1:0] RESP_OKAY  = 2'b00;
    localparam [1:0] RESP_ERROR = 2'b10; // SLVERR

    localparam [3:0] ADDR_CTRL   = 4'h0;
    localparam [3:0] ADDR_STATUS = 4'h4;
    localparam [3:0] ADDR_TXDATA = 4'h8;
    localparam [3:0] ADDR_RXDATA = 4'hC;

    localparam [3:0] TX_BUSY_CYCLES = 4'd4;

    // write-channel FSM states
    localparam [1:0] WS_IDLE  = 2'd0,
                      WS_WDATA = 2'd1,
                      WS_RESP  = 2'd2;
    // read-channel FSM states
    localparam [1:0] RS_IDLE  = 2'd0,
                      RS_DATA  = 2'd1;

    reg [1:0] wstate, wnext;
    reg [1:0] rstate, rnext;

    reg [31:0] awaddr_q;
    wire       awaddr_valid = (awaddr_q[31:4] == 28'd0) && (awaddr_q[1:0] == 2'b00);

    reg [31:0] araddr_q;
    wire       araddr_valid = (araddr_q[31:4] == 28'd0) && (araddr_q[1:0] == 2'b00);

    // UART register model (identical behavior to the AHB wrapper)
    reg       ctrl_enable;
    reg       tx_busy;
    reg [3:0] tx_busy_cnt;
    reg [7:0] tx_data;
    reg       rx_ready;
    reg [7:0] rx_data;

    wire wait_needed = awaddr_valid && (awaddr_q[3:0] == ADDR_TXDATA) && tx_busy;

    // ---------------- write address channel ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            wstate   <= WS_IDLE;
            awaddr_q <= 32'd0;
        end else begin
            wstate <= wnext;
            if (wstate == WS_IDLE && AWVALID && AWREADY) awaddr_q <= AWADDR;
        end
    end

    always @(*) begin
        wnext   = wstate;
        AWREADY = 1'b0;
        WREADY  = 1'b0;
        BVALID  = 1'b0;
        BRESP   = RESP_OKAY;
        case (wstate)
            WS_IDLE: begin
                AWREADY = 1'b1;
                if (AWVALID) wnext = WS_WDATA;
            end
            WS_WDATA: begin
                WREADY = !wait_needed;
                if (WVALID && !wait_needed) wnext = WS_RESP;
            end
            WS_RESP: begin
                BVALID = 1'b1;
                BRESP  = awaddr_valid ? RESP_OKAY : RESP_ERROR;
                if (BREADY) wnext = WS_IDLE;
            end
            default: wnext = WS_IDLE;
        endcase
    end

    wire commit_write = (wstate == WS_WDATA) && WVALID && WREADY && awaddr_valid;

    // ---------------- read address + data channel ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            rstate   <= RS_IDLE;
            araddr_q <= 32'd0;
        end else begin
            rstate <= rnext;
            if (rstate == RS_IDLE && ARVALID && ARREADY) araddr_q <= ARADDR;
        end
    end

    always @(*) begin
        rnext   = rstate;
        ARREADY = 1'b0;
        RVALID  = 1'b0;
        RRESP   = RESP_OKAY;
        RDATA   = 32'd0;
        case (rstate)
            RS_IDLE: begin
                ARREADY = 1'b1;
                if (ARVALID) rnext = RS_DATA;
            end
            RS_DATA: begin
                RVALID = 1'b1;
                RRESP  = araddr_valid ? RESP_OKAY : RESP_ERROR;
                case (araddr_q[3:0])
                    ADDR_CTRL:   RDATA = {31'd0, ctrl_enable};
                    ADDR_STATUS: RDATA = {30'd0, rx_ready, tx_busy};
                    ADDR_TXDATA: RDATA = {24'd0, tx_data};
                    ADDR_RXDATA: RDATA = {24'd0, rx_data};
                    default:     RDATA = 32'd0;
                endcase
                if (RREADY) rnext = RS_IDLE;
            end
            default: rnext = RS_IDLE;
        endcase
    end

    wire commit_read = (rstate == RS_DATA) && RREADY && araddr_valid &&
                        (araddr_q[3:0] == ADDR_RXDATA);

    // ---------------- UART register model ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            ctrl_enable <= 1'b0;
            tx_busy     <= 1'b0;
            tx_busy_cnt <= 4'd0;
            tx_data     <= 8'd0;
            rx_ready    <= 1'b0;
            rx_data     <= 8'd0;
        end else begin
            if (tx_busy) begin
                if (tx_busy_cnt == 4'd1) begin
                    tx_busy     <= 1'b0;
                    tx_busy_cnt <= 4'd0;
                end else begin
                    tx_busy_cnt <= tx_busy_cnt - 4'd1;
                end
            end

            if (rx_byte_valid) begin
                rx_data  <= rx_byte_data;
                rx_ready <= 1'b1;
            end

            if (commit_write) begin
                case (awaddr_q[3:0])
                    ADDR_CTRL: ctrl_enable <= WDATA[0];
                    ADDR_TXDATA: begin
                        tx_data     <= WDATA[7:0];
                        tx_busy     <= 1'b1;
                        tx_busy_cnt <= TX_BUSY_CYCLES;
                    end
                    default: ; // STATUS/RXDATA are read-only
                endcase
            end

            if (commit_read) rx_ready <= 1'b0;
        end
    end

endmodule
