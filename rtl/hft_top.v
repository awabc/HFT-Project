
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
	input [15:0]           		udp_port,
	input [15:0] 				locate,
	input						enable,
	input [31:0] 				buy_below_value,
	input [31:0] 				sell_above_value,
	input [31:0] 				quantity,
	input 						arm,
	
	// Status signals
	output [31:0] 				best_bid,
	output [31:0] 				best_bid_quantity,
	output 						best_bid_valid,
	output [31:0]				best_ask,
	output [31:0] 				best_ask_quantity,
	output 						best_ask_valid,
	output 						armed,
	
	// Stats
	output [31:0] 				stat_frames,
	output [31:0] 				stat_accepted,
	output [31:0]				stat_bad_fcs,
	output [31:0] 				stat_dropped,
	output [31:0] 				stat_fires,
	output [31:0] 				stat_orders,
	output 						stat_overrun,
	output 						stat_book_conflict

);


	///////////////////////////
	//         Parser        //
	///////////////////////////
	

	///////////////////////////
	//          Book         //
	///////////////////////////
	
	
	///////////////////////////
	//        Strategy       //
	///////////////////////////
	
	
	
	
	///////////////////////////
	//     Transmit Order    //
	///////////////////////////










endmodule























