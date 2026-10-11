`timescale 1ns/1ps
// Self-checking testbench for rtl/axi_lite_uart_slave_wrapper.v
// Exercises docs/02-axi-wrapper-fsm.md's slave write/read channel FSMs, plus
// the key AXI-vs-AHB difference: an independent read can complete while a
// write is still back-pressured (not possible on the single shared AHB bus).
module tb_axi_lite_uart_slave_wrapper;

    localparam [1:0] RESP_OKAY  = 2'b00;
    localparam [1:0] RESP_ERROR = 2'b10;

    localparam [31:0] ADDR_CTRL   = 32'h0;
    localparam [31:0] ADDR_STATUS = 32'h4;
    localparam [31:0] ADDR_TXDATA = 32'h8;
    localparam [31:0] ADDR_RXDATA = 32'hC;
    localparam [31:0] ADDR_BAD    = 32'h10;

    reg         ACLK, ARESETn;
    reg         AWVALID; reg [31:0] AWADDR; wire AWREADY;
    reg         WVALID;  reg [31:0] WDATA;  reg [3:0] WSTRB; wire WREADY;
    wire        BVALID;  wire [1:0] BRESP;  reg BREADY;
    reg         ARVALID; reg [31:0] ARADDR; wire ARREADY;
    wire        RVALID;  wire [31:0] RDATA; wire [1:0] RRESP; reg RREADY;
    reg         rx_byte_valid; reg [7:0] rx_byte_data;

    integer pass_count = 0;
    integer fail_count = 0;

    axi_lite_uart_slave_wrapper dut (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWVALID(AWVALID), .AWADDR(AWADDR), .AWREADY(AWREADY),
        .WVALID(WVALID), .WDATA(WDATA), .WSTRB(WSTRB), .WREADY(WREADY),
        .BVALID(BVALID), .BRESP(BRESP), .BREADY(BREADY),
        .ARVALID(ARVALID), .ARADDR(ARADDR), .ARREADY(ARREADY),
        .RVALID(RVALID), .RDATA(RDATA), .RRESP(RRESP), .RREADY(RREADY),
        .rx_byte_valid(rx_byte_valid), .rx_byte_data(rx_byte_data)
    );

    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

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

    // AVALID/WVALID/BREADY (or ARVALID/RREADY) held high until handshake --
    // a valid, if simplistic, AXI master behavior for a single outstanding xfer.
    task axi_write(input [31:0] addr, input [31:0] data, output [1:0] bresp);
        begin
            @(posedge ACLK); #1;
            AWVALID = 1'b1; AWADDR = addr;
            WVALID  = 1'b1; WDATA  = data; WSTRB = 4'hF;
            BREADY  = 1'b1;
            while (!BVALID) begin @(posedge ACLK); #1; end
            bresp = BRESP;
            @(posedge ACLK); #1;
            AWVALID = 1'b0; WVALID = 1'b0; BREADY = 1'b0;
        end
    endtask

    task axi_read(input [31:0] addr, output [31:0] rdata, output [1:0] rresp);
        begin
            @(posedge ACLK); #1;
            ARVALID = 1'b1; ARADDR = addr; RREADY = 1'b1;
            while (!RVALID) begin @(posedge ACLK); #1; end
            rdata = RDATA; rresp = RRESP;
            @(posedge ACLK); #1;
            ARVALID = 1'b0; RREADY = 1'b0;
        end
    endtask

    reg [31:0] rdata;
    reg [1:0]  resp, resp2;

    initial begin
        $dumpfile("axi_lite_uart_slave_wrapper.vcd");
        $dumpvars(0, tb_axi_lite_uart_slave_wrapper);

        ARESETn = 1'b0;
        AWVALID = 0; AWADDR = 0; WVALID = 0; WDATA = 0; WSTRB = 0; BREADY = 0;
        ARVALID = 0; ARADDR = 0; RREADY = 0;
        rx_byte_valid = 0; rx_byte_data = 0;
        repeat (3) @(posedge ACLK);
        ARESETn = 1'b1;
        @(posedge ACLK);

        // --- 1. plain register write + read-back ---
        axi_write(ADDR_CTRL, 32'h1, resp);
        check(resp == RESP_OKAY, "CTRL write returns OKAY");
        axi_read(ADDR_CTRL, rdata, resp);
        check(resp == RESP_OKAY && rdata == 32'h1, "CTRL read-back == 1");

        // --- 2. TXDATA write that collides with tx_busy -> WREADY back-pressure ---
        axi_write(ADDR_TXDATA, 32'h55, resp);
        check(resp == RESP_OKAY, "first TXDATA write OKAY, tx_busy now set");
        axi_read(ADDR_STATUS, rdata, resp);
        check(rdata[0] == 1'b1, "STATUS.tx_busy == 1 right after TXDATA write");

        // --- 3. second TXDATA write overlapped with an independent STATUS read:
        //        the read channel is NOT blocked by the write channel's wait,
        //        unlike the AHB version where only one transfer can be in flight.
        fork
            begin : second_write
                axi_write(ADDR_TXDATA, 32'h66, resp);
            end
            begin : overlapped_read
                #2; // start just after the write's AWVALID/WVALID assert
                axi_read(ADDR_STATUS, rdata, resp2);
            end
        join
        check(resp2 == RESP_OKAY, "STATUS read (read channel) completes independently");
        check(resp == RESP_OKAY, "second TXDATA write eventually OKAY once tx_busy clears");
        axi_read(ADDR_TXDATA, rdata, resp);
        check(rdata == 32'h66, "TXDATA committed only after back-pressure cleared");

        // --- 4. RX byte arrival + read, non-blocking status model ---
        @(posedge ACLK); #1;
        rx_byte_valid = 1'b1; rx_byte_data = 8'hA5;
        @(posedge ACLK); #1;
        rx_byte_valid = 1'b0;
        axi_read(ADDR_STATUS, rdata, resp);
        check(rdata[1] == 1'b1, "STATUS.rx_ready == 1 after byte arrival");
        axi_read(ADDR_RXDATA, rdata, resp);
        check(rdata == 32'hA5, "RXDATA read == 0xA5");
        axi_read(ADDR_STATUS, rdata, resp);
        check(rdata[1] == 1'b0, "STATUS.rx_ready == 0 after RXDATA read (cleared)");

        // --- 5. bad address -> SLVERR on both channels ---
        axi_read(ADDR_BAD, rdata, resp);
        check(resp == RESP_ERROR, "out-of-range read returns RRESP=SLVERR");
        axi_write(ADDR_BAD, 32'hDEAD, resp);
        check(resp == RESP_ERROR, "out-of-range write returns BRESP=SLVERR");

        // post-error access must work normally again
        axi_read(ADDR_CTRL, rdata, resp);
        check(resp == RESP_OKAY && rdata == 32'h1, "FSM recovers to normal OKAY access after SLVERR");

        $display("\n==== AXI-Lite UART slave wrapper: %0d passed, %0d failed ====\n",
                  pass_count, fail_count);
        if (fail_count != 0) $fatal(1, "simulation FAILED");
        $finish;
    end

endmodule
