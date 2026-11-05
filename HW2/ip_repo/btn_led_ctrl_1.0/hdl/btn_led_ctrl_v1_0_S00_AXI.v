
`timescale 1 ns / 1 ps

	module btn_led_ctrl_v1_0_S00_AXI #
	(
		// Users to add parameters here
		parameter integer MS_CLKS   = 50000,   // 50 MHz 下 1 ms 的 clk 數
		parameter integer LONG_MS   = 1000,    // 按住超過這個時間算長按
		parameter integer DOUBLE_MS = 300,     // 放開後這段時間內再按一次算雙擊
		parameter integer FX_DIV    = 12207,   // 恆亮模式亮度 PWM 的除頻值（約 132 Hz）

		// User parameters ends
		// Do not modify the parameters beyond this line

		// Width of S_AXI data bus
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		// Width of S_AXI address bus
		parameter integer C_S_AXI_ADDR_WIDTH	= 6
	)
	(
		// Users to add ports here
		input  wire btn,    // S6，按下 = 1
		output wire led0,   // LED0
		output wire irq,    // 接 IRQ_F2P[0]，level high
		// User ports ends
		// Do not modify the ports beyond this line

		// Global Clock Signal
		input wire  S_AXI_ACLK,
		// Global Reset Signal. This Signal is Active LOW
		input wire  S_AXI_ARESETN,
		// Write address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		// Write channel Protection type. This signal indicates the
    		// privilege and security level of the transaction, and whether
    		// the transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_AWPROT,
		// Write address valid. This signal indicates that the master signaling
    		// valid write address and control information.
		input wire  S_AXI_AWVALID,
		// Write address ready. This signal indicates that the slave is ready
    		// to accept an address and associated control signals.
		output wire  S_AXI_AWREADY,
		// Write data (issued by master, acceped by Slave) 
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		// Write strobes. This signal indicates which byte lanes hold
    		// valid data. There is one write strobe bit for each eight
    		// bits of the write data bus.    
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		// Write valid. This signal indicates that valid write
    		// data and strobes are available.
		input wire  S_AXI_WVALID,
		// Write ready. This signal indicates that the slave
    		// can accept the write data.
		output wire  S_AXI_WREADY,
		// Write response. This signal indicates the status
    		// of the write transaction.
		output wire [1 : 0] S_AXI_BRESP,
		// Write response valid. This signal indicates that the channel
    		// is signaling a valid write response.
		output wire  S_AXI_BVALID,
		// Response ready. This signal indicates that the master
    		// can accept a write response.
		input wire  S_AXI_BREADY,
		// Read address (issued by master, acceped by Slave)
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		// Protection type. This signal indicates the privilege
    		// and security level of the transaction, and whether the
    		// transaction is a data access or an instruction access.
		input wire [2 : 0] S_AXI_ARPROT,
		// Read address valid. This signal indicates that the channel
    		// is signaling valid read address and control information.
		input wire  S_AXI_ARVALID,
		// Read address ready. This signal indicates that the slave is
    		// ready to accept an address and associated control signals.
		output wire  S_AXI_ARREADY,
		// Read data (issued by slave)
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		// Read response. This signal indicates the status of the
    		// read transfer.
		output wire [1 : 0] S_AXI_RRESP,
		// Read valid. This signal indicates that the channel is
    		// signaling the required read data.
		output wire  S_AXI_RVALID,
		// Read ready. This signal indicates that the master can
    		// accept the read data and response information.
		input wire  S_AXI_RREADY
	);

	// AXI4LITE signals
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_awaddr;
	reg  	axi_awready;
	reg  	axi_wready;
	reg [1 : 0] 	axi_bresp;
	reg  	axi_bvalid;
	reg [C_S_AXI_ADDR_WIDTH-1 : 0] 	axi_araddr;
	reg  	axi_arready;
	reg [C_S_AXI_DATA_WIDTH-1 : 0] 	axi_rdata;
	reg [1 : 0] 	axi_rresp;
	reg  	axi_rvalid;

	// Example-specific design signals
	// local parameter for addressing 32 bit / 64 bit C_S_AXI_DATA_WIDTH
	// ADDR_LSB is used for addressing 32/64 bit registers/memories
	// ADDR_LSB = 2 for 32 bits (n downto 2)
	// ADDR_LSB = 3 for 64 bits (n downto 3)
	localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
	localparam integer OPT_MEM_ADDR_BITS = 3;
	//----------------------------------------------
	//-- Signals for user logic register space example
	//------------------------------------------------
	//-- Number of Slave Registers 16（0x00～0x3C，用到 0x24）
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg0;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg1;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg2;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg3;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg4;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg8;
	reg [C_S_AXI_DATA_WIDTH-1:0]	slv_reg9;
	wire	 slv_reg_rden;
	wire	 slv_reg_wren;
	reg [C_S_AXI_DATA_WIDTH-1:0]	 reg_data_out;
	integer	 byte_index;
	reg	 aw_en;

	// 暫存器（只列有用到的）：
	//   0x00 CTRL       slv_reg0  RW  bit0 mode：0 恆亮、1 呼吸
	//   0x04 STATUS               RO  bit0 防彈跳後的按鈕電位
	//   0x08 INT_STATUS           W1C bit0 按下、bit1 放開、bit2 單擊、bit3 雙擊、bit4 長按
	//   0x0C INT_ENABLE slv_reg3  RW  bit[4:0] 對應 INT_STATUS 每一種中斷的開關
	//   0x10 DATA_IN    slv_reg4  RW  CPU 寫給 IP 的資料
	//   0x14 DATA_OUT             RO  中斷發生時鎖住 DATA_IN + EVENT_CNT
	//   0x18 EVENT_CNT            RO  中斷事件次數
	//   0x1C HOLD_MS              RO  放開時鎖住：這次按住幾 ms
	//   0x20 SPEED      slv_reg8  RW  bit[1:0] 呼吸速度：0 = 3.75 s、1 = 1.9 s、2 = 0.94 s、3 = 0.47 s
	//   0x24 BRIGHT     slv_reg9  RW  bit[4:0] 恆亮模式亮度 0～31，重置值 31
	localparam [4:0] EV_PRESS = 5'b00001, EV_RELEASE = 5'b00010, EV_CLICK = 5'b00100,
	                 EV_DOUBLE = 5'b01000, EV_LONG = 5'b10000;

	wire [0:0] btn_db;      // 防彈跳後的按鈕
	reg        btn_d;       // 前一拍，用來偵測變化
	reg  [4:0] int_status;  // INT_STATUS
	reg  [4:0] ev;          // 這一拍發生的事件
	reg [C_S_AXI_DATA_WIDTH-1:0] event_cnt;  // 中斷事件次數
	reg [C_S_AXI_DATA_WIDTH-1:0] data_out;   // 中斷發生時鎖住 DATA_IN + EVENT_CNT
	reg [15:0] hold_ms;     // 最近一次按住的 ms 數

	// I/O Connections assignments

	assign S_AXI_AWREADY	= axi_awready;
	assign S_AXI_WREADY	= axi_wready;
	assign S_AXI_BRESP	= axi_bresp;
	assign S_AXI_BVALID	= axi_bvalid;
	assign S_AXI_ARREADY	= axi_arready;
	assign S_AXI_RDATA	= axi_rdata;
	assign S_AXI_RRESP	= axi_rresp;
	assign S_AXI_RVALID	= axi_rvalid;
	// Implement axi_awready generation
	// axi_awready is asserted for one S_AXI_ACLK clock cycle when both
	// S_AXI_AWVALID and S_AXI_WVALID are asserted. axi_awready is
	// de-asserted when reset is low.

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_awready <= 1'b0;
	      aw_en <= 1'b1;
	    end 
	  else
	    begin    
	      if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	        begin
	          // slave is ready to accept write address when 
	          // there is a valid write address and write data
	          // on the write address and data bus. This design 
	          // expects no outstanding transactions. 
	          axi_awready <= 1'b1;
	          aw_en <= 1'b0;
	        end
	        else if (S_AXI_BREADY && axi_bvalid)
	            begin
	              aw_en <= 1'b1;
	              axi_awready <= 1'b0;
	            end
	      else           
	        begin
	          axi_awready <= 1'b0;
	        end
	    end 
	end       

	// Implement axi_awaddr latching
	// This process is used to latch the address when both 
	// S_AXI_AWVALID and S_AXI_WVALID are valid. 

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_awaddr <= 0;
	    end 
	  else
	    begin    
	      if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
	        begin
	          // Write Address latching 
	          axi_awaddr <= S_AXI_AWADDR;
	        end
	    end 
	end       

	// Implement axi_wready generation
	// axi_wready is asserted for one S_AXI_ACLK clock cycle when both
	// S_AXI_AWVALID and S_AXI_WVALID are asserted. axi_wready is 
	// de-asserted when reset is low. 

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_wready <= 1'b0;
	    end 
	  else
	    begin    
	      if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en )
	        begin
	          // slave is ready to accept write data when 
	          // there is a valid write address and write data
	          // on the write address and data bus. This design 
	          // expects no outstanding transactions. 
	          axi_wready <= 1'b1;
	        end
	      else
	        begin
	          axi_wready <= 1'b0;
	        end
	    end 
	end       

	// Implement memory mapped register select and write logic generation
	// The write data is accepted and written to memory mapped registers when
	// axi_awready, S_AXI_WVALID, axi_wready and S_AXI_WVALID are asserted. Write strobes are used to
	// select byte enables of slave registers while writing.
	// These registers are cleared when reset (active low) is applied.
	// Slave register write enable is asserted when valid address and data are available
	// and the slave is ready to accept the write address and write data.
	assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      slv_reg0 <= 0;
	      slv_reg1 <= 0;
	      slv_reg2 <= 0;
	      slv_reg3 <= 0;
	      slv_reg4 <= 0;
	      slv_reg8 <= 0;
	      slv_reg9 <= 31;
	    end 
	  else begin
	    if (slv_reg_wren)
	      begin
	        case ( axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	          4'h0:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Respective byte enables are asserted as per write strobes 
	                // Slave register 0
	                slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          4'h1:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Respective byte enables are asserted as per write strobes 
	                // Slave register 1
	                slv_reg1[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          4'h2:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Respective byte enables are asserted as per write strobes 
	                // Slave register 2
	                slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          4'h3:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Respective byte enables are asserted as per write strobes 
	                // Slave register 3
	                slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end  
	          4'h4:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Slave register 4：DATA_IN
	                slv_reg4[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end
	          4'h8:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Slave register 8：SPEED
	                slv_reg8[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end
	          4'h9:
	            for ( byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1 )
	              if ( S_AXI_WSTRB[byte_index] == 1 ) begin
	                // Slave register 9：BRIGHT
	                slv_reg9[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
	              end
	          default : begin
	                      slv_reg0 <= slv_reg0;
	                      slv_reg1 <= slv_reg1;
	                      slv_reg2 <= slv_reg2;
	                      slv_reg3 <= slv_reg3;
	                      slv_reg4 <= slv_reg4;
	                      slv_reg8 <= slv_reg8;
	                      slv_reg9 <= slv_reg9;
	                    end
	        endcase
	      end
	  end
	end    

	// Implement write response logic generation
	// The write response and response valid signals are asserted by the slave 
	// when axi_wready, S_AXI_WVALID, axi_wready and S_AXI_WVALID are asserted.  
	// This marks the acceptance of address and indicates the status of 
	// write transaction.

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_bvalid  <= 0;
	      axi_bresp   <= 2'b0;
	    end 
	  else
	    begin    
	      if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID)
	        begin
	          // indicates a valid write response is available
	          axi_bvalid <= 1'b1;
	          axi_bresp  <= 2'b0; // 'OKAY' response 
	        end                   // work error responses in future
	      else
	        begin
	          if (S_AXI_BREADY && axi_bvalid) 
	            //check if bready is asserted while bvalid is high) 
	            //(there is a possibility that bready is always asserted high)   
	            begin
	              axi_bvalid <= 1'b0; 
	            end  
	        end
	    end
	end   

	// Implement axi_arready generation
	// axi_arready is asserted for one S_AXI_ACLK clock cycle when
	// S_AXI_ARVALID is asserted. axi_awready is 
	// de-asserted when reset (active low) is asserted. 
	// The read address is also latched when S_AXI_ARVALID is 
	// asserted. axi_araddr is reset to zero on reset assertion.

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_arready <= 1'b0;
	      axi_araddr  <= 32'b0;
	    end 
	  else
	    begin    
	      if (~axi_arready && S_AXI_ARVALID)
	        begin
	          // indicates that the slave has acceped the valid read address
	          axi_arready <= 1'b1;
	          // Read address latching
	          axi_araddr  <= S_AXI_ARADDR;
	        end
	      else
	        begin
	          axi_arready <= 1'b0;
	        end
	    end 
	end       

	// Implement axi_arvalid generation
	// axi_rvalid is asserted for one S_AXI_ACLK clock cycle when both 
	// S_AXI_ARVALID and axi_arready are asserted. The slave registers 
	// data are available on the axi_rdata bus at this instance. The 
	// assertion of axi_rvalid marks the validity of read data on the 
	// bus and axi_rresp indicates the status of read transaction.axi_rvalid 
	// is deasserted on reset (active low). axi_rresp and axi_rdata are 
	// cleared to zero on reset (active low).  
	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_rvalid <= 0;
	      axi_rresp  <= 0;
	    end 
	  else
	    begin    
	      if (axi_arready && S_AXI_ARVALID && ~axi_rvalid)
	        begin
	          // Valid read data is available at the read data bus
	          axi_rvalid <= 1'b1;
	          axi_rresp  <= 2'b0; // 'OKAY' response
	        end   
	      else if (axi_rvalid && S_AXI_RREADY)
	        begin
	          // Read data is accepted by the master
	          axi_rvalid <= 1'b0;
	        end                
	    end
	end    

	// Implement memory mapped register select and read logic generation
	// Slave register read enable is asserted when valid address is available
	// and the slave is ready to accept the read address.
	assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;
	always @(*)
	begin
	      // Address decoding for reading registers
	      case ( axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	        4'h0   : reg_data_out <= slv_reg0;                                       // CTRL
	        4'h1   : reg_data_out <= {{(C_S_AXI_DATA_WIDTH-1){1'b0}}, btn_db[0]};    // STATUS
	        4'h2   : reg_data_out <= {{(C_S_AXI_DATA_WIDTH-5){1'b0}}, int_status};   // INT_STATUS
	        4'h3   : reg_data_out <= slv_reg3;                                       // INT_ENABLE
	        4'h4   : reg_data_out <= slv_reg4;                                       // DATA_IN
	        4'h5   : reg_data_out <= data_out;                                       // DATA_OUT
	        4'h6   : reg_data_out <= event_cnt;                                      // EVENT_CNT
	        4'h7   : reg_data_out <= {{(C_S_AXI_DATA_WIDTH-16){1'b0}}, hold_ms};     // HOLD_MS
	        4'h8   : reg_data_out <= slv_reg8;                                       // SPEED
	        4'h9   : reg_data_out <= slv_reg9;                                       // BRIGHT
	        default : reg_data_out <= 0;
	      endcase
	end

	// Output register or memory read data
	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      axi_rdata  <= 0;
	    end 
	  else
	    begin    
	      // When there is a valid read address (S_AXI_ARVALID) with 
	      // acceptance of read address by the slave (axi_arready), 
	      // output the read dada 
	      if (slv_reg_rden)
	        begin
	          axi_rdata <= reg_data_out;     // register read data
	        end   
	    end
	end    

	// Add user logic here

	// ---------------- 1 ms 時基 ----------------
	reg [15:0] ms_div;
	wire       ms_tick = (ms_div == MS_CLKS - 1);

	always @( posedge S_AXI_ACLK )
	  if ( S_AXI_ARESETN == 1'b0 || ms_tick )
	    ms_div <= 0;
	  else
	    ms_div <= ms_div + 1;

	// ---------------- 手勢判斷 ----------------
	// S_IDLE   --按下--> S_PRESS1 --放開--> S_WAIT2 --DOUBLE_MS 內沒再按--> 單擊
	//                      |                   |
	//                  按住 LONG_MS         再按一次
	//                      v                   v
	//                   S_LONG  <--按住 LONG_MS-- S_PRESS2 --放開--> 雙擊
	localparam [2:0] S_IDLE = 3'd0, S_PRESS1 = 3'd1, S_WAIT2 = 3'd2, S_PRESS2 = 3'd3, S_LONG = 3'd4;
	reg  [2:0] g_state;
	reg [15:0] hold_cnt;    // 按住的 ms 數
	reg [15:0] gap_cnt;     // 放開後的 ms 數

	wire rise = btn_db[0] & ~btn_d;
	wire fall = ~btn_db[0] & btn_d;

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      btn_d    <= 1'b0;
	      g_state  <= S_IDLE;
	      hold_cnt <= 0;
	      gap_cnt  <= 0;
	      hold_ms  <= 0;
	      ev       <= 0;
	    end
	  else
	    begin
	      btn_d <= btn_db[0];
	      ev    <= {4'b0, rise} | {3'b0, fall, 1'b0};

	      if (btn_db[0] && ms_tick && hold_cnt != 16'hFFFF)
	        hold_cnt <= hold_cnt + 1;
	      if (!btn_db[0] && ms_tick && gap_cnt != 16'hFFFF)
	        gap_cnt <= gap_cnt + 1;
	      if (rise) hold_cnt <= 0;
	      if (fall) begin gap_cnt <= 0; hold_ms <= hold_cnt; end

	      case (g_state)
	        S_IDLE:   if (rise) g_state <= S_PRESS1;
	        S_PRESS1: if (fall) g_state <= S_WAIT2;
	                  else if (hold_cnt >= LONG_MS) begin g_state <= S_LONG; ev[4] <= 1'b1; end
	        S_WAIT2:  if (rise) g_state <= S_PRESS2;
	                  else if (gap_cnt >= DOUBLE_MS) begin g_state <= S_IDLE; ev[2] <= 1'b1; end
	        S_PRESS2: if (fall) begin g_state <= S_IDLE; ev[3] <= 1'b1; end
	                  else if (hold_cnt >= LONG_MS) begin g_state <= S_LONG; ev[4] <= 1'b1; end
	        S_LONG:   if (fall) g_state <= S_IDLE;
	        default:  g_state <= S_IDLE;
	      endcase
	    end
	end

	// ---------------- 中斷 ----------------
	// 事件發生就設對應的 bit；CPU 對 0x08 寫 1 清除（W1C，可一次清多個 bit），同一拍兩者都發生時以設定為準
	wire [4:0] wr_int_clr = (slv_reg_wren
	                      && axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 4'h2
	                      && S_AXI_WSTRB[0]) ? S_AXI_WDATA[4:0] : 5'b0;

	always @( posedge S_AXI_ACLK )
	begin
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      int_status <= 0;
	      event_cnt  <= 0;
	      data_out   <= 0;
	    end
	  else
	    begin
	      int_status <= (int_status & ~wr_int_clr) | ev;
	      if (ev != 0)
	        begin
	          // 中斷發生的同一拍準備好要給 CPU 的資料，ISR 再經 AXI 讀 DATA_OUT
	          event_cnt <= event_cnt + 1;
	          data_out  <= slv_reg4 + event_cnt + 1;
	        end
	    end
	end

	// 有任何一種開著的中斷就送給 CPU；INT_STATUS 清掉前一直是 High
	assign irq = |(int_status & slv_reg3[4:0]);

	// ---------------- LED ----------------
	// 恆亮模式的亮度 PWM：一個週期 31 格，前 BRIGHT 格亮；BRIGHT = 31 就是全亮
	reg [15:0] fx_div;
	reg  [4:0] fx_cnt;
	wire       led_breath;
	wire       led_fixed = (fx_cnt < slv_reg9[4:0]);

	always @( posedge S_AXI_ACLK )
	  if ( S_AXI_ARESETN == 1'b0 )
	    begin
	      fx_div <= 0;
	      fx_cnt <= 0;
	    end
	  else if (fx_div == FX_DIV - 1)
	    begin
	      fx_div <= 0;
	      fx_cnt <= (fx_cnt == 5'd30) ? 5'd0 : fx_cnt + 1;
	    end
	  else
	    fx_div <= fx_div + 1;

	assign led0 = slv_reg0[0] ? led_breath : led_fixed;

	btn_debounce #(
	    .CLK_HZ      (50_000_000),
	    .DEBOUNCE_MS (20)
	) u_btn_debounce (
	    .clk     (S_AXI_ACLK),
	    .resetn  (S_AXI_ARESETN),
	    .btn_in  (btn),
	    .btn_out (btn_db)
	);

	// SPEED 0～3：除頻值 12207 右移 SPEED 位，呼吸週期 3.75 s / 1.9 s / 0.94 s / 0.47 s
	breathing_pwm_top u_breathing_pwm (
	    .clk     (S_AXI_ACLK),
	    .resetn  (S_AXI_ARESETN),
	    .mode    (slv_reg0[0:0]),      // CTRL bit0
	    .div_n   (16'd12207 >> slv_reg8[1:0]),
	    .led_out (led_breath)
	);

	// User logic ends

	endmodule
