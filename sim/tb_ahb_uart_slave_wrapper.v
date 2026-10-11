`timescale 1ns/1ps
// Self-checking testbench for rtl/ahb_uart_slave_wrapper.v
// Exercises every state in docs/01-ahb-wrapper-fsm.md's slave wrapper FSM:
//   IDLE -> NONSEQ -> OKAY -> IDLE            (plain R/W)
//   IDLE -> NONSEQ -> NONSEQ -> ... -> IDLE   (back-to-back pipelined xfers)
//   IDLE -> NONSEQ -> WAIT* -> OKAY -> IDLE   (TXDATA write while tx_busy)
//   IDLE -> NONSEQ -> ERR1 -> ERR2 -> IDLE    (bad address)
module tb_ahb_uart_slave_wrapper;

    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] RESP_OKAY     = 2'b00;
    localparam [1:0] RESP_ERROR    = 2'b01;

    localparam [31:0] ADDR_CTRL   = 32'h0;
    localparam [31:0] ADDR_STATUS = 32'h4;
    localparam [31:0] ADDR_TXDATA = 32'h8;
    localparam [31:0] ADDR_RXDATA = 32'hC;
    localparam [31:0] ADDR_BAD    = 32'h10;

    reg         HCLK;
    reg         HRESETn;
    reg         HSEL;
    reg  [31:0] HADDR;
    reg  [1:0]  HTRANS;
    reg         HWRITE;
    reg  [31:0] HWDATA;
    wire        HREADYOUT;
    wire [1:0]  HRESP;
    wire [31:0] HRDATA;
    reg         rx_byte_valid;
    reg  [7:0]  rx_byte_data;

    integer pass_count = 0;
    integer fail_count = 0;

    ahb_uart_slave_wrapper dut (
        .HCLK        (HCLK),
        .HRESETn     (HRESETn),
        .HSEL        (HSEL),
        .HADDR       (HADDR),
        .HTRANS      (HTRANS),
        .HWRITE      (HWRITE),
        .HWDATA      (HWDATA),
        .HREADY      (HREADYOUT),   // single-slave system: HREADY == this slave's HREADYOUT
        .HREADYOUT   (HREADYOUT),
        .HRESP       (HRESP),
        .HRDATA      (HRDATA),
        .rx_byte_valid (rx_byte_valid),
        .rx_byte_data  (rx_byte_data)
    );

    // 100 MHz clock
    initial HCLK = 1'b0;
    always #5 HCLK = ~HCLK;

    task check(input cond, input [511:0] msg);
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("[PASS] %0t: %0s", $time, msg);
            end else begin
                fail_count = fail_count + 1;
                $display("[FAIL] %0t: %0s", $time, msg);
            end
        end
    endtask

    task ahb_write(input [31:0] addr, input [31:0] data, output [1:0] resp);
        begin
            @(posedge HCLK); #1;
            HSEL = 1'b1; HADDR = addr; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b1;
            @(posedge HCLK); #1;
            HTRANS = HTRANS_IDLE; HWDATA = data;
            while (HREADYOUT !== 1'b1) begin
                @(posedge HCLK); #1;
            end
            resp = HRESP;
            @(posedge HCLK); #1;
            HSEL = 1'b0;
        end
    endtask

    task ahb_read(input [31:0] addr, output [31:0] data, output [1:0] resp);
        begin
            @(posedge HCLK); #1;
            HSEL = 1'b1; HADDR = addr; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b0;
            @(posedge HCLK); #1;
            HTRANS = HTRANS_IDLE;
            while (HREADYOUT !== 1'b1) begin
                @(posedge HCLK); #1;
            end
            data = HRDATA;
            resp = HRESP;
            @(posedge HCLK); #1;
            HSEL = 1'b0;
        end
    endtask

    reg [31:0] rdata;
    reg [1:0]  resp;

    initial begin
        $dumpfile("ahb_uart_slave_wrapper.vcd");
        $dumpvars(0, tb_ahb_uart_slave_wrapper);

        HRESETn = 1'b0; HSEL = 1'b0; HADDR = 32'd0; HTRANS = HTRANS_IDLE;
        HWRITE = 1'b0; HWDATA = 32'd0; rx_byte_valid = 1'b0; rx_byte_data = 8'd0;
        repeat (3) @(posedge HCLK);
        HRESETn = 1'b1;
        @(posedge HCLK);

        // --- 1. plain register write + read-back (IDLE->NONSEQ->OKAY->IDLE) ---
        ahb_write(ADDR_CTRL, 32'h1, resp);
        check(resp == RESP_OKAY, "CTRL write returns OKAY");
        ahb_read(ADDR_CTRL, rdata, resp);
        check(resp == RESP_OKAY && rdata == 32'h1, "CTRL read-back == 1");

        // --- 2. back-to-back pipelined transfers (NONSEQ immediately followed by NONSEQ) ---
        @(posedge HCLK); #1;
        HSEL = 1'b1; HADDR = ADDR_STATUS; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b0;
        @(posedge HCLK); #1;
        // still inside data phase of xfer1 (STATUS read); pipeline xfer2's address phase now
        HADDR = ADDR_CTRL; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b0;
        check(HREADYOUT == 1'b1, "xfer1 (STATUS) completes same cycle xfer2 address phase issued");
        check(HRESP == RESP_OKAY, "xfer1 STATUS resp OKAY");
        @(posedge HCLK); #1;
        HTRANS = HTRANS_IDLE;
        while (HREADYOUT !== 1'b1) begin @(posedge HCLK); #1; end
        check(HRDATA == 32'h1, "pipelined xfer2 (CTRL) read-back == 1");
        @(posedge HCLK); #1; HSEL = 1'b0;

        // --- 3. TXDATA write that collides with tx_busy -> AHB WAIT states ---
        ahb_write(ADDR_TXDATA, 32'h55, resp);
        check(resp == RESP_OKAY, "first TXDATA write OKAY, tx_busy now set");
        ahb_read(ADDR_STATUS, rdata, resp);
        check(rdata[0] == 1'b1, "STATUS.tx_busy == 1 right after TXDATA write");

        fork
            begin : second_write
                ahb_write(ADDR_TXDATA, 32'h66, resp);
            end
        join
        check(resp == RESP_OKAY, "second TXDATA write (into WAIT) eventually OKAY");
        ahb_read(ADDR_TXDATA, rdata, resp);
        check(rdata == 32'h66, "TXDATA committed only after wait states cleared");
        ahb_read(ADDR_STATUS, rdata, resp);
        check(rdata[0] == 1'b0, "STATUS.tx_busy == 0 after TX finished");

        // --- 4. RX byte arrival + read, non-blocking status model ---
        @(posedge HCLK); #1;
        rx_byte_valid = 1'b1; rx_byte_data = 8'hA5;
        @(posedge HCLK); #1;
        rx_byte_valid = 1'b0;
        ahb_read(ADDR_STATUS, rdata, resp);
        check(rdata[1] == 1'b1, "STATUS.rx_ready == 1 after byte arrival");
        ahb_read(ADDR_RXDATA, rdata, resp);
        check(rdata == 32'hA5, "RXDATA read == 0xA5");
        ahb_read(ADDR_STATUS, rdata, resp);
        check(rdata[1] == 1'b0, "STATUS.rx_ready == 0 after RXDATA read (cleared)");

        // --- 5. bad address -> 2-cycle ERROR response (ERR1 -> ERR2) ---
        ahb_read(ADDR_BAD, rdata, resp);
        check(resp == RESP_ERROR, "out-of-range address returns HRESP=ERROR");

        // post-error access must work normally again
        ahb_read(ADDR_CTRL, rdata, resp);
        check(resp == RESP_OKAY && rdata == 32'h1, "FSM recovers to normal OKAY access after ERROR");

        $display("\n==== AHB UART slave wrapper: %0d passed, %0d failed ====\n",
                  pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "simulation FAILED");
        $finish;
    end

endmodule
