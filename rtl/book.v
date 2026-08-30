
module book #(
	parameter ORDER_INDEX_W = 8 // direct mapped table with 256 entries
)(
	
	input 			i_clk,
	input 			i_rst_n,
	
	input 			i_event_valid,
	input [144:0] 	i_event_marker,
	input [15:0] 	i_locate,
	
	output			o_valid,
	
	output [31:0] 	o_best_bid,
	output [23:0]   o_best_bid_quantity,
	output 			o_best_bid_valid,
	
	output [31:0] 	o_best_ask,
	output [23:0] 	o_best_ask_quantity,
	output  		o_best_ask_valid,
	
	output 			o_stat_book_conflict
);
	
	// Localparams 
	localparam DEPTH = 1 << ORDER_INDEX_W;
	
	localparam ITCH_ADD_ORDER 	= 8'h41;
	localparam ITCH_EXECUTED	= 8'h45;
	localparam ITCH_CANCEL 		= 8'h58;
	localparam ITCH_DELETE		= 8'h44;
	
	// Declare wires and regs
	reg 			order_buy[DEPTH];
	reg [23:0] 		order_shares[DEPTH];
	reg [31:0] 		order_price[DEPTH];
	reg 			order_valid[DEPTH];
	
	wire [7:0]   	mtype;
	wire [15:0] 	locate;
	wire [63:0] 	order_ref;
	wire 			is_buy;
	wire [23:0] 	shares;
	wire [31:0] 	price;
	
	wire [ORDER_INDEX_W-1:0] 	idx;
	wire 						hit;
	
	wire 						best_bid_valid;
	wire [31:0] 				best_bid;
	wire 						best_ask_valid;
	wire [31:0] 				best_ask;
	
	wire 			add_bid_better;
	wire 			add_bid_same;
	wire 			add_ask_better;
	wire 			add_ask_same;
	wire 			is_add;
	wire 			is_delete;
	wire 			is_red;
	
	wire 			e_valid;
	wire 			e_buy;
	wire [31:0]  	e_price;
	wire [23:0] 	e_shares;
	
	wire 			proceed;
	wire 			use_all;
	wire 			pending;
	wire [23:0] 	take;
	wire [23:0] 	remainder;
	wire 			hits_bid;
	wire 			hits_ask;
	
	
	// Unpack event marker
	assign mtype 		= i_event_marker[7:0];
	assign locate 		= i_event_marker[23:8];
	assign order_ref 	= i_event_marker[87:24];
	assign is_buy 		= i_event_marker[88];
	assign shares 		= i_event_marker[112:89];
	assign price 		= i_event_marker[144:113];
	
	assign idx = order_ref[ORDER_INDEX_W-1:0];
	
	//////////////////////////////////////////
	// Cycle 1: Price the order
	
	// Mark a hit
	assign hit = i_event_valid && (locate == i_locate);
	
	// Add the order now, price the decision now, number of shares one cycle after
	assign add_bid_better 	= ~best_bid_valid || (price > best_bid);
	assign add_bid_same 	= price == best_bid;
	assign add_ask_better 	= ~best_ask_valid || (price < best_ask);
	assign add_ask_same  	= price == best_ask;
	
	assign is_add 			= hit && mtype == ITCH_ADD_ORDER;
	assign is_delete 		= hit && mytpe == ITCH_DELETE;
	assign is_red   		= hit && ( (mytype == ITCH_EXECUTE) || (mtype == ITCH_CANCEL) );
	
	// Asynchronous read
	assign e_valid 	= order_valid[idx];
	assign e_buy 	= order_buy[idx];
	assign e_price 	= order_price[idx];
	assign e_shares = order_shares[idx];
	
	
	//////////////////////////////////////////
	// Cycle 2 : Number of shares
	
	assign proceed 		= pending && e_valid_d1;
	assign use_all 		= is_delete || req > e_shares_d1;
	assign take    		= use_all ? e_shares_d1 : req;
	assign remainder 	= use_all ? 24'd0 : (e_shares_d1 - req);
	
	assign hits_bid 	= proceed && e_buy_d1 && best_bid_valid && e_price_d1 == best_bid;
	assign hits_ask 	= proceed && !e_buy_d1 && best_ask_valid && e_price_d1 == best_ask;
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
	
endmodule
	