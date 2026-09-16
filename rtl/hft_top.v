
module hft_top #(
    parameter DATA_WIDTH   		= 512,
    parameter BEAT_WIDTH   		= 64,                        // tkeep width: 1 bit per byte of DATA_WIDTH
    parameter CHUNK_WIDTH  		= 64,                        // width of each external data chunk (ASIC pin budget)
    parameter NUM_CHUNKS       = DATA_WIDTH / CHUNK_WIDTH,   // chunks per full beat (16 for 512/32)
    parameter KEEP_CHUNK_WIDTH = BEAT_WIDTH / NUM_CHUNKS     // tkeep bits per chunk (4 for 64/16)
)(

    input      clk,
    input      rst_n,

    // RX AXI4-Stream, narrowed to 64-bit chunks 
    input  [CHUNK_WIDTH-1:0]      	rx_tdata_chunk,
    input  [KEEP_CHUNK_WIDTH-1:0] 	rx_tkeep_chunk,
    input                          	rx_tvalid_chunk,
    output                          rx_tready_chunk,
    input                          	rx_tlast,
    input                          	rx_tuser_error,

    // TX AXI4-Stream, narrowed to 64-bit chuncks (MSB first)
    output [CHUNK_WIDTH-1:0]      	tx_tdata_chunk,
    output [KEEP_CHUNK_WIDTH-1:0] 	tx_tkeep_chunk,
    output                          tx_tvalid_chunk,
    input                          	tx_tready_chunk,
    output                          tx_tlast,

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
	output 						o_stat_book_conflict,
	output [63:0] 				o_order_id

);

	localparam CHUNK_CNT_WIDTH  = $clog2(NUM_CHUNKS);


	/////////////////////////////////////////////
	//  RX de-serializer (64 bit -> 512 bit)   //
	/////////////////////////////////////////////

	reg [DATA_WIDTH-1:0]      rx_data_word;
	reg [BEAT_WIDTH-1:0]      rx_keep_word;
	reg                       rx_valid_word;
	reg                       rx_last_word;
	reg                       rx_error_word;

	reg [DATA_WIDTH-1:0]      rx_shift_reg;
	reg [BEAT_WIDTH-1:0]      rx_keep_shift_reg;
	reg [CHUNK_CNT_WIDTH-1:0] rx_chunk_cnt;

	wire [DATA_WIDTH-1:0] rx_shift_next = {rx_shift_reg[DATA_WIDTH-CHUNK_WIDTH-1:0], rx_tdata_chunk};
	wire [BEAT_WIDTH-1:0] rx_keep_shift_next = {rx_keep_shift_reg[BEAT_WIDTH-KEEP_CHUNK_WIDTH-1:0], rx_tkeep_chunk};
	wire                  rx_chunk_xfer = rx_tvalid_chunk && rx_tready_chunk;
	wire                  rx_last_chunk = (rx_chunk_cnt == NUM_CHUNKS-1);

	assign rx_tready_chunk = 1'b1;

	always @(posedge clk) begin
		if (!rst_n) begin
			rx_chunk_cnt      <= {CHUNK_CNT_WIDTH{1'b0}};
			rx_shift_reg      <= {DATA_WIDTH{1'b0}};
			rx_keep_shift_reg <= {BEAT_WIDTH{1'b0}};
			rx_valid_word     <= 1'b0;
			rx_data_word      <= {DATA_WIDTH{1'b0}};
			rx_keep_word      <= {BEAT_WIDTH{1'b0}};
			rx_last_word      <= 1'b0;
			rx_error_word     <= 1'b0;
		end else begin
			rx_valid_word <= 1'b0; // default: single-cycle pulse

			if (rx_chunk_xfer) begin
				rx_shift_reg      <= rx_shift_next;
				rx_keep_shift_reg <= rx_keep_shift_next;

				if (rx_last_chunk) begin
					rx_chunk_cnt  <= {CHUNK_CNT_WIDTH{1'b0}};
					rx_data_word  <= rx_shift_next;
					rx_keep_word  <= rx_keep_shift_next;
					rx_valid_word <= 1'b1;
					rx_last_word  <= rx_tlast;
					rx_error_word <= rx_tuser_error;
				end else begin
					rx_chunk_cnt <= rx_chunk_cnt + 1'b1;
				end
			end
		end
	end


	///////////////////////////
	//         Parser        //
	///////////////////////////
	
	wire 			event_valid;
	wire [144:0] 	event_marker;
	wire [31:0]		stat_frames;
	wire [31:0] 	stat_accepted;
	wire [31:0]		stat_bad_fcs;
	wire [31:0] 	stat_dropped;
	
	parser parser_inst (
		.i_clk				(clk),
		.i_rst_n			(rst_n),
		
		.i_data				(rx_data_word),
		.i_keep				(rx_keep_word),
		.i_data_valid		(rx_valid_word),
		.i_last				(rx_last_word),
		.i_error			(rx_error_word),
		
		.i_udp_port			(i_udp_port),
		
		.o_event_valid		(event_valid),
		.o_event_marker		(event_marker),
		
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
		.o_stat_fires		(stat_fires)
	);
	
	assign o_armed = armed;
	assign o_stat_fires = stat_fires;
	
	
	///////////////////////////
	//     Transmit Order    //
	///////////////////////////

	wire [63:0] order_id;
	wire [31:0] stat_orders;
	wire 		stat_overrun;

	wire [DATA_WIDTH-1:0] order_tx_tdata;
	wire [BEAT_WIDTH-1:0] order_tx_tkeep;
	wire                  order_tx_tvalid;
	wire                  order_tx_tlast;
	wire                  order_tx_tready;

	order_tx order_tx_inst (
		.i_clk 				(clk),
		.i_rst_n			(rst_n),
		
		.i_fire				(fire),
		.i_fire_price		(fire_price),
		.i_fire_shares		(fire_shares),
		.i_fire_is_buy		(fire_is_buy),
		
		.o_tdata			(order_tx_tdata),
		.o_tkeep			(order_tx_tkeep),
		.o_tvalid			(order_tx_tvalid),
		.o_tlast			(order_tx_tlast),
		.i_tready			(order_tx_tready),
		
		.o_order_id			(order_id),
		.o_stat_orders		(stat_orders),
		.o_stat_overrun		(stat_overrun)
	);

	assign o_stat_orders = stat_orders;
	assign o_stat_overrun = stat_overrun;
	assign o_order_id = order_id;


	////////////////////////////////////////////
	//   TX serializer (512 bit -> 64 bit)    //
	////////////////////////////////////////////

	localparam TX_IDLE = 1'b0;
	localparam TX_SEND = 1'b1;

	reg                       tx_state;
	reg [DATA_WIDTH-1:0]      tx_data_sr;   
	reg [BEAT_WIDTH-1:0]      tx_keep_sr;
	reg [CHUNK_CNT_WIDTH-1:0] tx_chunk_cnt;
	reg                       tx_last_latched;

	assign order_tx_tready = (tx_state == TX_IDLE);

	assign tx_tdata_chunk  = tx_data_sr[DATA_WIDTH-1 -: CHUNK_WIDTH];
	assign tx_tkeep_chunk  = tx_keep_sr[BEAT_WIDTH-1 -: KEEP_CHUNK_WIDTH];
	assign tx_tvalid_chunk = (tx_state == TX_SEND);
	assign tx_tlast        = tx_last_latched;

	always @(posedge clk) begin
		if (!rst_n) begin
			tx_state        <= TX_IDLE;
			tx_data_sr      <= {DATA_WIDTH{1'b0}};
			tx_keep_sr      <= {BEAT_WIDTH{1'b0}};
			tx_chunk_cnt    <= {CHUNK_CNT_WIDTH{1'b0}};
			tx_last_latched <= 1'b0;
		end else begin
			case (tx_state)
				TX_IDLE: begin
					if (order_tx_tvalid) begin // order_tx_tready == 1 here
						tx_data_sr      <= order_tx_tdata;
						tx_keep_sr      <= order_tx_tkeep;
						tx_last_latched <= order_tx_tlast;
						tx_chunk_cnt    <= {CHUNK_CNT_WIDTH{1'b0}};
						tx_state        <= TX_SEND;
					end
				end

				TX_SEND: begin
					if (tx_tready_chunk) begin // tx_tvalid_chunk == 1 here
						if (tx_chunk_cnt == NUM_CHUNKS-1) begin
							tx_state     <= TX_IDLE;
							tx_chunk_cnt <= {CHUNK_CNT_WIDTH{1'b0}};
						end else begin
							tx_data_sr   <= {tx_data_sr[DATA_WIDTH-CHUNK_WIDTH-1:0], {CHUNK_WIDTH{1'b0}}};
							tx_keep_sr   <= {tx_keep_sr[BEAT_WIDTH-KEEP_CHUNK_WIDTH-1:0], {KEEP_CHUNK_WIDTH{1'b0}}};
							tx_chunk_cnt <= tx_chunk_cnt + 1'b1;
						end
					end
				end
			endcase
		end
	end


endmodule
