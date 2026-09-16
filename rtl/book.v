
module book #(
	parameter ORDER_INDEX_W = 6 // direct mapped table with 64 entries
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
	reg  [ORDER_INDEX_W-1:0] 	idx_d1;
	wire 						hit;
	
	reg  						best_bid_valid;
	reg  [31:0] 				best_bid;
	reg  [23:0] 				best_bid_quantity;
	reg  						best_ask_valid;
	reg  [31:0] 				best_ask;
	reg  [23:0] 				best_ask_quantity;
	
	wire 			add_bid_better;
	wire 			add_bid_same;
	wire 			add_ask_better;
	wire 			add_ask_same;
	wire 			is_add;
	wire 			is_delete;
	wire 			is_red;
	
	wire 			e_valid;
	reg 			e_valid_d1;
	wire 			e_buy;
	reg 			e_buy_d1;
	wire [31:0]  	e_price;
	reg  [31:0] 	e_price_d1;
	wire [23:0] 	e_shares;
	reg  [23:0] 	e_shares_d1;
	
	wire 			proceed;
	wire 			use_all;
	wire [23:0] 	take;
	wire [23:0] 	remainder;
	wire 			hits_bid;
	wire 			hits_ask;
	
	reg  						wr_en;
	reg [ORDER_INDEX_W-1:0] 	wr_addr;
	reg 						wr_valid;
	reg 						wr_buy;
	reg [31:0] 					wr_price;
	reg [23:0] 					wr_shares;
	
	reg 		bbo_valid;
	reg 		pending;
	reg 		is_delete_d1;
	reg [23:0] 	req;
	
	reg 		qa_ask_add;
	reg 		qa_ask_set;
	reg 		qa_bid_add;
	reg 		qa_bid_set;
	reg [23:0]  qa_val;
	reg 		stat_book_conflict;
	
	integer 	i;
	
	
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
	assign is_delete 		= hit && mtype == ITCH_DELETE;
	assign is_red   		= hit && ( (mtype == ITCH_EXECUTED) || (mtype == ITCH_CANCEL) );
	
	// Asynchronous read
	assign e_valid 	= order_valid[idx];
	assign e_buy 	= order_buy[idx];
	assign e_price 	= order_price[idx];
	assign e_shares = order_shares[idx];
	
	
	//////////////////////////////////////////
	// Cycle 2 : Number of shares
	
	assign proceed 		= pending && e_valid_d1;
	assign use_all 		= is_delete_d1 || req > e_shares_d1;
	assign take    		= use_all ? e_shares_d1 : req;
	assign remainder 	= use_all ? 24'd0 : (e_shares_d1 - req);
	
	assign hits_bid 	= proceed && e_buy_d1 && best_bid_valid && e_price_d1 == best_bid;
	assign hits_ask 	= proceed && !e_buy_d1 && best_ask_valid && e_price_d1 == best_ask;
	
	
	//////////////////////////////////////////
	// Single write port
	
	always @ (*) begin
		if (~i_rst_n) begin
			wr_en 		= 1'b0;
			wr_addr 	= 0;
			wr_valid 	= 1'b0;
			wr_buy 		= 1'b0;
			wr_price 	= 32'd0;
			wr_shares 	= 24'd0;
		end else begin
			if (is_add) begin
				wr_en 		= 1'b1;
				wr_addr 	= idx;
				wr_valid 	= 1'b1;
				wr_buy 		= is_buy;
				wr_price 	= price;
				wr_shares 	= shares;
			end else begin
				wr_en 		= proceed;
				wr_addr 	= idx_d1;
				wr_valid 	= ~use_all;
				wr_buy 		= e_buy_d1;
				wr_price 	= e_price_d1;
				wr_shares 	= remainder;
			end
		end
	end
	
	/////////////////////////////////////////
	// Book update (sequential logic)
	
	always @ (posedge i_clk) begin
		if (!i_rst_n) begin
			for (i=0; i<DEPTH; i=i+1) begin
				order_valid[i]  <= 1'b0;
			end
			bbo_valid 			<= 1'b0;
			best_bid 			<= 32'd0;
			best_bid_quantity 	<= 24'd0;
			best_bid_valid 		<= 1'b0;
			best_ask 			<= 32'd0;
			best_ask_quantity 	<= 24'd0;
			best_ask_valid 		<= 1'b0;
			pending 			<= 1'b0;
			qa_bid_set 			<= 1'b0;
			qa_bid_add 			<= 1'b0;
			qa_ask_add 			<= 1'b0;
			qa_ask_set 			<= 1'b0;
			qa_val 				<= 24'd0;
			stat_book_conflict 	<= 1'b0;
			pending 			<= 1'b0;
			idx_d1 				<= 0;
			is_delete_d1 		<= 1'b0;
			req 				<= 1'b0;
			e_valid_d1 			<= 1'b0;
			e_buy_d1 			<= 1'b0;
			e_price_d1 			<= 32'd0;
			e_shares_d1 		<= 24'd0;
		end else begin
			bbo_valid <= 1'b0;
			
			// Pipeline stage
			pending 		<= is_delete | is_red;
			idx_d1 			<= idx;
			is_delete_d1 	<= is_delete;
			req 			<= shares;
			e_valid_d1 	 	<= e_valid;
			e_buy_d1  		<= e_buy;
			e_price_d1 		<= e_price;
			e_shares_d1 	<= e_shares;
			
			// Write port
			if (wr_en) begin
				order_valid  [wr_addr] <= wr_valid;
				order_buy    [wr_addr] <= wr_buy;
				order_price  [wr_addr] <= wr_price;
				order_shares [wr_addr] <= wr_shares;
			end 
			
			// Add order, price (cycle 1)
			qa_bid_set 	<= 1'b0;
			qa_bid_add 	<= 1'b0;
			qa_ask_set 	<= 1'b0;
			qa_ask_add 	<= 1'b0;
			qa_val 		<= shares;
			
			if (is_add) begin
				if (is_buy) begin
					
					if (add_bid_better) begin
						best_bid 		<= price;
						best_bid_valid 	<= 1'b1;
						qa_bid_set 		<= 1'b1;
						bbo_valid 		<= 1'b1;
					end else if (add_bid_same) begin
						qa_bid_add 	<= 1'b1;
						bbo_valid 	<= 1'b1;
					end 
				end else begin
					if (add_ask_better) begin
						best_ask 		<= price;
						best_ask_valid 	<= 1'b1;
						qa_ask_set 		<= 1'b1;
						bbo_valid  		<= 1'b1;
					end else if (add_ask_same) begin
						qa_ask_add 	<= 1'b1;
						bbo_valid 	<= 1'b1;
					end
				end
			end
			
			// Add order, quantity (one cycle behind)
			if (qa_bid_set) begin
				best_bid_quantity <= qa_val;
			end else if (qa_bid_add) begin
				best_bid_quantity <= best_bid_quantity + qa_val;
			end 
			if (qa_ask_set) begin
				best_ask_quantity <= qa_val;
			end else if (qa_ask_add) begin
				best_ask_quantity <= best_ask_quantity + qa_val;
			end 
			
			// Apply reduction to book
			if (proceed) begin
				if (hits_bid) begin
					if (best_bid_quantity > take) begin
						best_bid_quantity <= best_bid_quantity - take;
					end else begin
						best_bid_quantity <= 24'd0;
						best_bid_valid 	  <= 1'b0;
					end 
					bbo_valid <= 1'b1;
				end else if (hits_ask) begin
					if (best_ask_quantity > take) begin
						best_ask_quantity <= best_ask_quantity - take;
					end else begin
						best_ask_quantity <= 24'd0;
						best_ask_valid 	  <= 1'b0;
					end
					bbo_valid <= 1'b1;
				end 
			end 
			
			// Mark conflict (sticky)
			if (is_add && proceed) begin
				stat_book_conflict <= 1'b1;
			end
			if ((qa_bid_set || qa_bid_add) && hits_bid) begin
				stat_book_conflict <= 1'b1;
			end 
			if ((qa_ask_set || qa_ask_add) && hits_ask) begin
				stat_book_conflict <= 1'b1;
			end 
		end 
	end
	
	// Assign outputs
	assign o_valid 				= bbo_valid;
	assign o_best_bid 			= best_bid;
	assign o_best_bid_quantity 	= best_bid_quantity;
	assign o_best_bid_valid 	= best_bid_valid;
	assign o_best_ask 			= best_ask;
	assign o_best_ask_quantity 	= best_ask_quantity;
	assign o_best_ask_valid 	= best_ask_valid;
	assign o_stat_book_conflict = stat_book_conflict;
	
endmodule
