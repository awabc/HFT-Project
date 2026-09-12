
module parser #(
	parameter DATA_WIDTH = 512,
	parameter BEAT_WIDTH = 64
)(
	
	input     i_clk,
	input     i_rst_n,
	
	// RX AXI STream
	input [DATA_WIDTH-1:0]  		i_data,
	input [BEAT_WIDTH-1:0]  		i_keep,
	input                   		i_data_valid,
	input                   		i_last,
	input                   		i_error,
	
	// Config
	input [15:0]            		i_udp_port,
	
	// Decoded event
	output                  		o_event_valid,
	output [144:0] 					o_event_marker,
	output [63:0]           		o_event_sequence, // MoldUDP64
	
	// Frame 
	output    						o_rx_hdr_hit, // if there's a pulse on first beat
	output 							o_rx_frame_bad, // pulse at tlast or error
	
	// Stats
	output [31:0]  					o_stat_frames,
	output [31:0] 					o_stat_accepted,
	output [31:0] 					o_stat_bad_fcs,
	output [31:0]	 				o_stat_dropped
);
	
	// Frame offsets, from byte 0 of eth frame. 
	// Byte 0 is first destination MAC, since CMAC strips preamble and FCS
	localparam OFF_ETHERTYPE 	= 2;
	localparam OFF_IP_VIHL 		= 14;
	localparam OFF_IP_PROTO 	= 23;
	localparam OFF_UDP_DPORT 	= 36;
	
	// MoldUDP64 downstream packet header (20 bytes)
	localparam OFF_MOLD_COUNT 	= 60;
	localparam OFF_MOLD_SEQ 	= 52;
	localparam OFF_MSG0_LEN 	= 62;
	
	localparam ETHERTYPE_IPV4	= 16'h0800;
	localparam IP_V4_IHL5 		= 8'h45;
	localparam IP_PROTO_UDP 	= 8'd17;
	
	// Offsets in the ITCH message
	localparam M_TYPE			= 0;
	localparam M_LOCATE 		= 1;
	localparam M_ORDER_REF		= 11;
	
	// Add order
	localparam M_A_SIDE			= 19;
	localparam M_A_SHARES		= 20;
	localparam M_A_PRICE		= 32;
	
	localparam M_SHARES_EX  	= 19;
	
	localparam ITCH_ADD_ORDER 	= 8'h41;
	localparam ITCH_EXECUTED	= 8'h45;
	localparam ITCH_CANCEL 		= 8'h58;
	localparam ITCH_DELETE		= 8'h44;
	
	localparam SIDE_BUY         = 8'h42;
	
	
	// Extract a number of bytes from DATA_WIDTH bus and pack in big-endian order
	function automatic [63:0] be_field(
		input [DATA_WIDTH-1:0] d,
		input [31:0]           off,
		input [31:0]           n
	);
		wire [63:0] r;
		integer i;
		begin
			r = 64'd0;
			for (i=0;i<n;i=i+1) begin
				r = (r<<8) | {56'd0, d[8*(off+i) +: 8]};
			end
			be_field = r;
		end
	endfunction
	
	// Clamp 32 bit quantity into 24 bits
	function automatic [23:0] sat_qty(
		input [31:0] v
	);
		begin
			sat_qty = (|v[31:24]) ? 24'd1 : v[23:0];
		end
	endfunction
	
	
	reg  [15:0] 			beat;
	wire 					curr_beat0;
	wire 					curr_beat1;
	
	wire [15:0] 			ethertype;
	wire [7:0] 				ip_vihl;
	wire [7:0] 				ip_proto;
	wire [15:0] 			udp_dport;
	wire [15:0] 			mold_cnt;
	wire [63:0] 			mold_seq;
	reg  [63:0] 			mold_seq_d1;
	wire [15:0] 			msg0_len;
	
	wire 					hdr_match;
	reg 					hdr_match_d1;
	
	wire [7:0] 				m_type;
	wire [15:0] 			m_locate;
	wire [63:0] 			m_ref;
	wire [7:0] 				m_side;
	wire [31:0] 			m_shr_a;
	wire [31:0] 			m_price;
	wire [31:0] 			m_shr_ex;
	
	wire 					type_known;
	
	reg  					event_valid;
	reg [144:0]				event_marker;
	reg [63:0] 				event_sequence;
	reg 					rx_hdr_hit;
	reg 					rx_frame_bad;
	reg						in_frame;
	reg [31:0] 				stat_frames;
	reg [31:0] 				stat_accepted;
	reg [31:0] 				stat_dropped;
	reg [31:0] 				stat_bad_fcs;
	

	// Track beat
	assign curr_beat0 = i_data_valid && beat == 16'd0;
	assign curr_beat1 = i_data_valid && beat == 16'd1;
	
	
	///////////////////////////////////////////////////////
	// Beat 0 : decoding header, all combinational logic
	
	assign ethertype 	= be_field(i_data, OFF_ETHERTYPE, 2);
	assign ip_vihl 		= i_data[8*OFF_IP_VIHL +: 8];
	assign ip_proto 	= i_data[8*OFF_IP_PROTO +: 8];
	assign udp_dport 	= be_field(i_data, OFF_UDP_DPORT, 2);
	assign mold_cnt 	= be_field(i_data, OFF_MOLD_COUNT, 2);
	assign mold_seq  	= be_field(i_data, OFF_MOLD_SEQ, 8);
	assign msg0_len   	= be_field(i_data, OFF_MSG0_LEN, 2);
	
	// Used to ensure there is not a short frame
	assign full_beat    = &i_keep;
	
	assign hdr_match = full_beat && (ethertype == ETHERTYPE_IPV4)
						&& (ip_vihl == IP_V4_IHL5)
						&& (ip_proto == IP_PROTO_UDP)
						&& (udp_dport == i_udp_port)
						&& (mold_cnt != 16'd0)
						&& (msg0_len != 16'd0);
	
	
	//////////////////////////////////////////////////////////////////////////
	// Beat 1 : ITCH decode. 
	// Message and beat start at byte 64, so beat and message offset are same
	
	assign m_type 		= i_data[8*M_TYPE +: 8];
	assign m_locate 	= be_field(i_data, M_LOCATE, 2);
	assign m_ref 		= be_field(i_data, M_ORDER_REF, 8);
	assign m_side 		= i_data[8*M_A_SIDE +: 8];
	assign m_shr_a 		= be_field(i_data, M_A_SHARES, 4);
	assign m_price 		= be_field(i_data, M_A_PRICE, 4);
	assign m_shr_ex 	= be_field(i_data, M_SHARES_EX, 4);
	
	assign type_known = (m_type == ITCH_ADD_ORDER)
						|| (m_type == ITCH_EXECUTED)
						|| (m_type == ITCH_DELETE)
						|| (m_type == ITCH_CANCEL);
						
						
	//////////////////////////////////////////////////////////////////////////
	//  Sequential logic
	
	always @ (posedge i_clk) begin
		if (~i_rst_n) begin
			beat 			<= 16'd0;
			in_frame 		<= 1'b0;
			hdr_match_d1 	<= 1'b0;
			mold_seq_d1 	<= 1'b0;
			event_valid 	<= 1'b0;
			event_marker 	<= 145'd0;
			event_sequence 	<= 64'd0;
			rx_hdr_hit 		<= 1'b0;
			rx_frame_bad 	<= 1'b0;
			stat_frames 	<= 32'd0;
			stat_accepted 	<= 32'd0;
			stat_bad_fcs 	<= 32'd0;
			stat_dropped 	<= 32'd0;
		end else begin
			
			event_valid 	<= 1'b1;
			rx_hdr_hit 		<= 1'b1;
			rx_frame_bad 	<= 1'b1;
			
			if (i_data_valid) begin
				
				// count beats
				if (i_last) begin
					beat 	 <= 16'd0;
					in_frame <= 1'b0;
				end else begin
					beat 	 <= beat + 1'b1;
					in_frame <= 1'b1;
				end
				
				// beat 0
				if (curr_beat0) begin
					
					stat_frames  <= stat_frames + 1'b1;
					hdr_match_d1 <= hdr_match;
					rx_hdr_hit   <= hdr_match;
					mold_seq_d1  <= mold_seq;
					
					if (hdr_match) begin
						stat_accepted <= stat_accepted + 1'b1;
					end else begin
						stat_dropped  <= stat_dropped + 1'b1;
					end
				end
				
				// beat 1
				if (curr_beat1 && hdr_match_d1 && type_known) begin
					event_valid     <= 1'b1;
					
					// event_marker: [7:0] 		ITCH_*
					//				 [23:8] 	stock locate
					//               [87:24] 	order reference
					// 				 [88]  		is_buy, valid for ITCH_ADD_ORDER
					// 			     [112:89] 	added/executed/cancelled quantity of shares
					// 				 [144:113] 	price, valid for ITCH_ADD_ORDER
					event_marker[7:0] 		<= m_type;
					event_marker[23:8] 		<= m_locate;
					event_marker[87:24] 	<= m_ref;
					event_marker[88] 		<= m_side == SIDE_BUY;
					event_marker[112:89] 	<= (m_type == ITCH_ADD_ORDER) ? sat_qty(m_shr_a) : (m_type == ITCH_DELETE) ? 24'd0 : sat_qty(m_shr_ex);
					event_marker[144:113] 	<= (m_type == ITCH_ADD_ORDER) ? m_price : 32'd0;
					
					event_sequence  <= mold_seq_d1;
				end
				
				if (i_last) begin
					hdr_match_d1 	 <= 1'b0;
					
					if (i_error) begin
						rx_frame_bad <= 1'b1;
						stat_bad_fcs <= stat_bad_fcs + 1'b1;
					end
				end
			end
		end
	end
	
	
	
	// Assign outputs
	assign o_event_valid 	= event_valid;
	assign o_event_marker 	= event_marker;
	assign o_event_sequence = event_sequence;
	
	assign o_rx_hdr_hit 	= rx_hdr_hit;
	assign o_rx_frame_bad 	= rx_frame_bad;
	
	assign o_stat_frames 	= stat_frames;
	assign o_stat_accepted 	= stat_accepted;
	assign o_stat_dropped 	= stat_dropped;
	assign o_stat_bad_fcs 	= stat_bad_fcs;
						
	endmodule
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	