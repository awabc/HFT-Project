
module hft_top #(
    parameter DATA_WIDTH = 512,
    parameter BEAT_WIDTH = 64
)(

    input      clk,
    input      rst_n,
    
    // RX AXI4 Stream
    input [DATA_WIDTH-1:0]    	rx_tdata,
    input [BEAT_WIDTH-1:0]     	rx_tkeep,
	input                      	rx_tvalid,
	input                      	rx_tlast,
	input 				       	rx_tuser_error,
	
	// TX AXI4 Stream
	output [DATA_WIDTH-1:0]    	tx_tdata,
	output [BEAT_WIDTH-1:0]    	tx_tkeep,
	output                     	tx_tvalid,
	output						tx_tlast,
	input                       tx_tready,
	
	// Configuration signals, drive through VIO
	input [15:0]           		i_udp_port,
	input [15:0] 				i_locate,
	input						i_enable,
	input [31:0] 				i_buy_below_value,
	input [31:0] 				i_sell_above_value,
	input [31:0] 				i_quantity,
	input 						i_arm,
	
	// Status signals
	output [31:0] 				o_best_bid,
	output [31:0] 				o_best_bid_quantity,
	output 						o_best_bid_valid,
	output [31:0]				o_best_ask,
	output [31:0] 				o_best_ask_quantity,
	output 						o_best_ask_valid,
	output 						o_armed,
	
	// Stats
	output [31:0] 				o_stat_frames,
	output [31:0] 				o_stat_accepted,
	output [31:0]				o_stat_bad_fcs,
	output [31:0] 				o_stat_dropped,
	output [31:0] 				o_stat_fires,
	output [31:0] 				o_stat_orders,
	output 						o_stat_overrun,
	output 						o_stat_book_conflict

);


	///////////////////////////
	//         Parser        //
	///////////////////////////
	
	wire 			event_valid;
	wire [144:0] 	event_marker;
	wire [63:0] 	event_sequence;
	wire 			rx_hdr_hit;
	wire 			rx_frame_bad;
	wire [31:0]		stat_frames;
	wire [31:0] 	stat_accepted;
	wire [31:0]		stat_bad_fcs;
	wire [31:0] 	stat_dropped;
	
	parser parser_inst (
		.i_clk				(clk),
		.i_rst_n			(rst_n),
		
		.i_data				(rx_tdata),
		.i_keep				(rx_tkeep),
		.i_data_valid		(rx_tvalid),
		.i_last				(rx_tlast),
		.i_error			(rx_tuser_error),
		
		.i_udp_port			(i_udp_port),
		
		.o_event_valid		(event_valid),
		.o_event_marker		(event_marker),
		.o_event_sequence   (event_sequence),
		
		.o_rx_hdr_hit		(rx_hdr_hit),
		.o_rx_frame_bad		(rx_frame_bad),
		
		.o_stat_frames		(stat_frames),
		.o_stat_accepted	(stat_accepted),
		.o_stat_bad_fcs		(stat_bad_fcs),
		.o_stat_dropped		(stat_dropped)
	);
	
	assign o_stat_frames 	= stat_frames;
	assign o_stat_accepted 	= stat_accepted;
	assign o_stat_bad_fcs 	= stat_bad_fcs;
	assign o_stat_dropped 	= stat_dropped;
	

	///////////////////////////
	//          Book         //
	///////////////////////////
	
	wire 		bbo_valid;
	wire [23:0] bid_quantity;
	wire [23:0] ask_quantity;
	wire [31:0] best_bid;
	wire        best_bid_valid;
	wire [31:0] best_ask;
	wire        best_ask_valid;
	wire 		stat_book_conflict;
	
	book book_inst (
		.i_clk					(clk),
		.i_rst_n				(rst_n),
		
		.i_event_valid			(event_valid),
		.i_event_marker			(event_marker),
		.i_locate				(i_locate),
		
		.o_valid				(bbo_valid),
		.o_best_bid 			(best_bid),
		.o_best_bid_quantity	(bid_quantity),
		.o_best_bid_valid		(best_bid_valid),
		
		.o_best_ask 			(best_ask),
		.o_best_ask_quantity	(ask_quantity),
		.o_best_ask_valid		(best_ask_valid),
		
		.o_stat_book_conflict	(stat_book_conflict)
	);
	
	assign o_best_bid 			= best_bid;
	assign o_best_bid_valid 	= best_bid_valid;
	assign o_best_ask 			= best_ask;
	assign o_best_ask_valid 	= best_ask_valid;
	assign o_stat_book_conflict = stat_book_conflict;
	// 0 Pad output signals to 32 bits
	assign o_best_bid_quantity 	= {8'd0, bid_quantity};
	assign o_best_ask_quantity 	= {8'd0, ask_quantity};
	
	
	///////////////////////////
	//        Strategy       //
	///////////////////////////
	
	wire 		fire;
	wire [31:0] fire_price;
	wire [31:0] fire_shares;
	wire 		fire_is_buy;
	wire 		armed;
	wire [31:0]	stat_fires;
	
	strategy strategy_inst (
		.i_clk				(clk),
		.i_rst_n			(rst_n),
		
		.i_bbo_valid		(bbo_valid),
		.i_best_bid			(best_bid),
		.i_best_bid_valid	(best_bid_valid),
		.i_best_ask			(best_ask),
		.i_best_ask_valid	(best_ask_valid),
		
		.i_config_enable	(i_enable),
		.i_buy_below		(i_buy_below_value),
		.i_sell_above		(i_sell_above_value),
		.i_quantity			(i_quantity),
		.i_arm_pulse		(i_arm),
		
		.o_fire				(fire),
		.o_fire_price		(fire_price),
		.o_fire_shares		(fire_shares),
		.o_fire_is_buy		(fire_is_buy),
		
		.o_armed			(armed),
		.o_stat_fires		(stat_fires),
	);
	
	assign o_armed = armed;
	assign o_stat_fires = stat_fires;
	
	
	///////////////////////////
	//     Transmit Order    //
	///////////////////////////










endmodule























