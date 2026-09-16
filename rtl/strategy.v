
module strategy (
	
	input 			i_clk,
	input 			i_rst_n,
	
	input 			i_bbo_valid,
	input [31:0] 	i_best_bid,
	input 			i_best_bid_valid,
	input [31:0] 	i_best_ask,
	input 			i_best_ask_valid,
	
	input 			i_config_enable,
	input [31:0] 	i_buy_below,
	input [31:0] 	i_sell_above,
	input [31:0] 	i_quantity,
	input 			i_arm_pulse,
	
	output 			o_fire,
	output [31:0] 	o_fire_price,
	output [31:0] 	o_fire_shares,
	output 			o_fire_is_buy,
	
	output 			o_armed,
	output [31:0] 	o_stat_fires
);

	wire 			buy_order;
	wire 			sell_order;
	reg  			armed;
	reg  			fire;
	reg  [31:0] 	fire_price;
	reg  [31:0] 	fire_shares;
	reg  		 	fire_is_buy;
	reg  [31:0] 	stat_fires;
	
	assign buy_order  = i_bbo_valid && i_config_enable && armed && i_best_ask_valid && (i_best_ask <= i_buy_below);
	assign sell_order = i_bbo_valid && i_config_enable && armed && i_best_bid_valid && (i_best_bid >= i_sell_above);
	
	always @ (posedge i_clk) begin
		if (~i_rst_n) begin
			fire 		<= 1'b0;
			armed 		<= 1'b0;
			fire_price 	<= 32'd0;
			fire_shares <= 32'd0;
			stat_fires 	<= 32'd0;
			fire_is_buy <= 1'b0;
		end else begin
			fire 		<= 1'b0;
			
			if (i_arm_pulse) begin
				armed 	<= 1'b1;
			end
			
			// Take the order, if both qualify then hit the bid
			if (buy_order) begin
				fire 		<= 1'b1;
				fire_price 	<= i_best_ask;
				fire_shares <= i_quantity;
				fire_is_buy <= 1'b1;
				armed 		<= 1'b0;
				stat_fires 	<= stat_fires + 1'b1;
			end else if (sell_order) begin
				fire 		<= 1'b1;
				fire_price 	<= i_best_bid;
				fire_shares <= i_quantity;
				fire_is_buy <= 1'b0;
				armed 		<= 1'b0;
				stat_fires 	<= stat_fires + 1'b1;
			end else begin
				fire 		<= 1'b0;
				fire_price 	<= 32'd0;
				fire_shares <= 32'd0;
				fire_is_buy <= 1'b0;
			end
		end
	end

	
	// Output assignments
	assign o_fire 			= fire;
	assign o_fire_price 	= fire_price;
	assign o_fire_shares 	= fire_shares;
	assign o_fire_is_buy 	= fire_is_buy;
	assign o_armed 			= armed;
	assign o_stat_fires 	= stat_fires;

endmodule
	