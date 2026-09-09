
module order_tx (
	input 			i_clk,
	input 			i_rst_n,
	
	input 			i_fire,
	input [31:0] 	i_fire_price,
	input [31:0] 	i_fire_shares
	input 			i_fire_is_buy,
	
	// Simulated AXI output
	output [511:0] 	o_tdata,
	output [63:0] 	o_tkeep,
	output 			o_tvalid,
	output 			o_tlast,
	input 			i_tready,
	
	output [63:0] 	o_order_id,
	output [31:0] 	o_stat_orders,
	output 			o_stat_overrun // fired while tx was busy
);
	
	localparam ORDER_BYTES = 64;
	localparam PAYLOAD_BYTES = ORDER_BYTES - 42;
	
	// Offsets
	localparam OFF_ETH_DST 		= 0;
	localparam OFF_ETH_SRC 		= 6;
	localparam OFF_ETHERTYPE 	= 12;
	localparam OFF_IP_SRC 		= 26;
	localparam OFF_IP_DST		= 30;
	localparam OFF_UDP_SPORT 	= 34;
	localparam OFF_UDP_DPORT  	= 36;
	localparam OFF_UDP_LEN  	= 38;
	localparam OFF_UDP_CSUM 	= 40;
	localparam OFF_MAGIC 	 	= 42;
	localparam OFF_ORD_ID 		= 46;
	localparam OFF_ORD_PRICE 	= 54;
	localparam OFF_ORD_SHARES 	= 58;
	localparam OFF_ORD_SIDE 	= 62;
	
	wire [15:0] IP_TOTLEN   = 16'd50;
	wire [15:0] UDP_LEN     = 16'd30;
	wire [31:0] ORDER_MAGIC = 32'h4157_4142; // AWAB!
	wire [7:0]  SIDE_BUY 	= 8'h42;
	wire [7:0]  SIDE_SELL   = 8'h53;
	
	wire [47:0] DST_MAC  		= 48'h00_0A_35_02_9D_E5;
	wire [47:0] SRC_MAC  		= 48'h00_0A_35_02_9D_E4;
	wire [31:0] SRC_IP   		= {8'd192, 8'd168, 8'd1,  8'd10};
	wire [31:0] DST_IP   		= {8'd192, 8'd168, 8'd1,  8'd20};
	wire [15:0] SRC_PORT    	= 16'd41000;
	wire [15:0] DST_PORT 		= 16'd41001;
	wire [15:0] ETHERTYPE_IPV4 	= 16'h0800;
	wire [7:0]  IP_V4_IHL5     	= 8'h45;
	wire [7:0]  IP_PROTO_UDP   	= 8'd17;
	
	// Logic wires/regs
	reg [7:0] 		tpl [0:ORDER_BYTES-1];
	reg [31:0] 		checksum_accumulate;
	reg [31:0] 		checksum_f1;
	reg [15:0] 		ip_checksum;
	reg [511:0] 	tpl_beat;
	reg [511:0] 	patched;
	reg [63:0] 		order_id;
	
	wire 			tx_hs;
	
	reg [511:0] 	tdata;
	reg [63:0] 		tkeep;
	reg  			tvalid;
	reg 			tlast;
	reg [31:0] 		stat_orders;
	reg 			stat_overrun;
	
	integer i;
	
	// Place n byte big endian field into a beat at an offset
	function automatic [511:0] be_patch(
		input [511:0] d,
		input integer  off,
		input integer  n,
		input [63:0]   v
	);
		reg [511:0] r;
		integer j;
		begin
			r = d;
			for (j = 0; j < n; j = j + 1) begin
				r[8(off+j) +: 8] = v[8(n-1-j) +: 8];
			end
			be_patch = r;
		end
	endfunction
	
	
	// Frame template (byte array)
	always @ (*) begin
		if (~i_rst_n) begin
			for (i=0; i<ORDER_BYTES; i=i+1) begin
				tpl[i] = 8'h00;
			end
			checksum_accumulate = 32'd0;
			checksum_f1 		= 32'd0;
			ip_checksum 		= 16'd0;
		end else begin
			for (i=0; i<ORDER_BYTES; i=i+1) begin
				tpl[i] = 8'h00;
			end
			
			// Ethernet
			for (i=0;i<6;i=i+1) begin
				tpl[OFF_ETH_DST+i] = DST_MAC[8*(5-i)+:8];
				tpl[OFF_ETH_SRC+i] = SRC_MAC[8*(5-i)+:8];
			end
			tpl[OFF_ETHERTYPE] 		= ETHERTYPE_IPV4[15:8];
			tpl[OFF_ETHERTYPE+1] 	= ETHERTYPE_IPV4[7:0];
			
			// IPV4
			tpl[14] = IP_V4_IHL5;          
			tpl[15] = 8'h00;               
			tpl[16] = IP_TOTLEN[15:8];
			tpl[17] = IP_TOTLEN[7:0];	
			tpl[18] = 8'h00;  
			tpl[19] = 8'h00;   
			tpl[20] = 8'h40;  
			tpl[21] = 8'h00;   
			tpl[22] = 8'd64;                     
			tpl[23] = IP_PROTO_UDP;
			tpl[24] = 8'h00;  
			tpl[25] = 8'h00;  
			for (i=0; i<4; i=i+1) begin
				tpl[OFF_IP_SRC + i] = SRC_IP[8*(3-i) +: 8];
			end
			for (i=0; i<4; i=i+1) begin
				tpl[OFF_IP_DST + i] = DST_IP[8*(3-i) +: 8];
			end
			
			// IPV4 Header Checksumn
			checksum_accumulate = 32'd0;
			for (i=14; i<34; i=i+2) begin
				checksum_accumulate = checksum_accumulate + {16'd0, tpl[i], tpl[i+1]};
			end
			checksum_f1 = {16'd0, checksum_accumulate[15:0]} + {16'd0, checksum_accumulate[31:16]};
			ip_checksum = ~(checksum_f1[15:0] + checksum_f1[31:16]);
			tpl[24] = ip_checksum[15:8];
			tpl[25] = ip_checksum[7:0];
			
			// UDP
			tpl[OFF_UDP_SPORT] 		= SRC_PORT[15:8];
			tpl[OFF_UDP_SPORT+1] 	= SRC_PORT[7:0];
			tpl[OFF_UDP_DPORT] 		= DST_PORT[15:8];
			tpl[OFF_UDP_DPORT+1] 	= DST_PORT[7:0];
			tpl[OFF_UDP_LEN] 		= UDP_LEN[15:8];
			tpl[OFF_UDP_LEN+1] 		= UDP_LEN[7:0];
			tpl[OFF_UDP_CSUM] 		= 8'h00;
			tpl[OFF_UDP_CSUM+1] 	= 8'h00;
			
			// Magic ID
			for (i=0; i<4; i=i+1) begin
				tpl[OFF_MAGIC+i] = ORDER_MAGIC[8*(3-i) +: 8];
			end
		end
	end
	
	// Stitch template into one beat
	always @ (*) begin
		if (~i_rst_n) begin
			tpl_beat = 512'd0;
		end else begin
			tpl_beat = 512'd0;
			for (i=0; i<64; i=i+1) begin
				tpl_beat[8*i+:8] = tpl[i];
			end
		end
	end
	
	// Patch live fields
	always @ (*) begin
		if (~i_rst_n) begin
			patched = 512'd0;
		end else begin
			patched = tpl_beat;
			patched = be_patch(patched, OFF_ORD_ID, 	8, order_id);
			patched = be_patch(patched, OFF_ORD_PRICE, 	4, {32'd0, i_fire_price});
			patched = be_patch(patched, OFF_ORD_SHARES, 4, {32'd0, i_fire_shares});
			patched[8*OFF_ORD_SIDE+:8] = i_fire_is_buy ? SIDE_BUY : SIDE_SELL;
		end
	end
	
	// --------------Beat TX---------------
	assign tx_hs = tvalid & i_tready;
	
	always @ posedge(i_clk) begin
		if (~i_rst_n) begin
			tdata 			<= 512'd0;
			tkeep 			<= 64'd0;
			tvalid 			<= 1'b0;
			tlast 			<= 1'b0;
			order_id 		<= 64'd0;
			stat_orders 	<= 32'd0;
			stat_overrun 	<= 1'b0;
		end else begin
			if (i_fire && !tvalid) begin
				tdata 		<= patched;
				tkeep 		<= {64{1'b1}};
				tvalid 		<= 1'b1;
				tlast 		<= 1'b1;
				order_id 	<= order_id + 64'd1;
				stat_orders <= stat_orders + 32'd1;
			end else if (tx_hs) begin
				tvalid 	<= 1'b0;
				tlast 	<= 1'b0;
			end
			
			// Latch overrun if a fire arrvies when previous beat is still waiting for tready
			if (i_fire && tvalid) begin
				stat_overrun <= 1'b1;
			end
		end
	end
	
	// Output Assignments
	assign o_tdata = tdata;
	assign o_tkeep = tkeep;
	assign o_tlast = tlast;
	assign o_tvalid = tvalid;
	
	assign o_order_id 		= order_id;
	assign o_stat_orders 	= stat_orders;
	assign o_stat_overrun 	= stat_overrun;
	
endmodule
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	


	