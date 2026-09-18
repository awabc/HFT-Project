`timescale 1ns/1ps
//=====================================================================
// tb_hft_top - full chip integration test.
//
// Drives complete MoldUDP64/ITCH frames in through the 64-bit RX chunk
// pins, lets the whole pipeline run, and collects the outbound order
// packet from the TX chunk pins, reassembling and checking it.
//
// Covers:
//   * tick-to-trade: market data in -> order packet out
//   * the outbound packet's headers and payload
//   * measured end-to-end latency
//   * config plumbing (udp port, locate, thresholds, quantity, arm)
//   * stats plumbing to top-level pins
//   * no order is emitted when disarmed, disabled, or when the market
//     does not cross the threshold
//=====================================================================
module tb_hft_top;

`include "tb_defs.vh"
`include "itch_frame.vh"

`TB_VARS
`TB_TIMEOUT(60000)

localparam CW       = 64;
localparam KW       = CW / 8;
localparam NCHUNKS  = 512 / CW;
localparam UDP_PORT = 16'd26400;
localparam LOCATE   = 16'd7;

reg clk = 0;
reg rst_n = 0;
always #5 clk = ~clk;

reg  [CW-1:0] rx_tdata_chunk;
reg  [KW-1:0] rx_tkeep_chunk;
reg           rx_tvalid_chunk;
wire          rx_tready_chunk;
reg           rx_tlast;
reg           rx_tuser_error;

wire [CW-1:0] tx_tdata_chunk;
wire [KW-1:0] tx_tkeep_chunk;
wire          tx_tvalid_chunk;
reg           tx_tready_chunk;
wire          tx_tlast;

reg  [15:0] i_udp_port, i_locate;
reg         i_enable, i_arm;
reg  [31:0] i_buy_below_value, i_sell_above_value, i_quantity;

wire [31:0] o_best_bid, o_best_bid_quantity, o_best_ask, o_best_ask_quantity;
wire        o_best_bid_valid, o_best_ask_valid, o_armed;
wire [31:0] o_stat_frames, o_stat_accepted, o_stat_bad_fcs, o_stat_dropped;
wire [31:0] o_stat_fires, o_stat_orders;
wire        o_stat_overrun, o_stat_book_conflict;
wire [63:0] o_order_id;

hft_top uut (
    .clk(clk), 
	.rst_n(rst_n),
    .rx_tdata_chunk(rx_tdata_chunk), 
	.rx_tkeep_chunk(rx_tkeep_chunk),
    .rx_tvalid_chunk(rx_tvalid_chunk), 
	.rx_tready_chunk(rx_tready_chunk),
    .rx_tlast(rx_tlast), 
	.rx_tuser_error(rx_tuser_error),
    .tx_tdata_chunk(tx_tdata_chunk), 
	.tx_tkeep_chunk(tx_tkeep_chunk),
    .tx_tvalid_chunk(tx_tvalid_chunk), 
	.tx_tready_chunk(tx_tready_chunk),
    .tx_tlast(tx_tlast),
    .i_udp_port(i_udp_port), 
	.i_locate(i_locate), 
	.i_enable(i_enable),
    .i_buy_below_value(i_buy_below_value), 
	.i_sell_above_value(i_sell_above_value),
    .i_quantity(i_quantity), 
	.i_arm(i_arm),
    .o_best_bid(o_best_bid), 
	.o_best_bid_quantity(o_best_bid_quantity),
    .o_best_bid_valid(o_best_bid_valid),
    .o_best_ask(o_best_ask), 
	.o_best_ask_quantity(o_best_ask_quantity),
    .o_best_ask_valid(o_best_ask_valid), 
	.o_armed(o_armed),
    .o_stat_frames(o_stat_frames), 
	.o_stat_accepted(o_stat_accepted),
    .o_stat_bad_fcs(o_stat_bad_fcs), 
	.o_stat_dropped(o_stat_dropped),
    .o_stat_fires(o_stat_fires), 
	.o_stat_orders(o_stat_orders),
    .o_stat_overrun(o_stat_overrun), 
	.o_stat_book_conflict(o_stat_book_conflict),
    .o_order_id(o_order_id)
);

integer cyc;
initial cyc = 0;
always @(posedge clk) cyc = cyc + 1;

//---------------------------------------------------------------------
// Outbound packet collector: reassembles TX chunks into a 512-bit beat
//---------------------------------------------------------------------
reg [511:0] tx_pkt;
reg [511:0] tx_acc;
integer     tx_chunk_i;
integer     tx_pkt_count;
integer     tx_first_cyc, tx_done_cyc;
reg         tx_collect_on;

reg [CW-1:0] tx_samp;
always @(posedge clk) #2 tx_samp = tx_tdata_chunk;

always @(posedge clk) begin
    if (rst_n && tx_collect_on && tx_tvalid_chunk && tx_tready_chunk) begin
        if (tx_chunk_i == 0) tx_first_cyc = cyc;
        tx_acc     = (tx_acc << CW) | {{(512-CW){1'b0}}, tx_samp};
        tx_chunk_i = tx_chunk_i + 1;
        if (tx_chunk_i == NCHUNKS) begin
            tx_pkt       = tx_acc;
            tx_pkt_count = tx_pkt_count + 1;
            tx_chunk_i   = 0;
            tx_done_cyc  = cyc;
        end
    end
end

task clr_tx; begin tx_chunk_i = 0; tx_pkt_count = 0; tx_acc = 0; end endtask

//---------------------------------------------------------------------
// RX driver
//---------------------------------------------------------------------
integer rx_start_cyc;

task drive_beat;
    input [511:0] d;
    input [63:0]  k;
    input         last;
    input         err;
    integer c;
    begin
        for (c = 0; c < NCHUNKS; c = c + 1) begin
            @(negedge clk);
            rx_tdata_chunk  = d[511 - c*CW -: CW];
            rx_tkeep_chunk  = k[63 - c*KW -: KW];
            rx_tvalid_chunk = 1'b1;
            rx_tlast        = last;
            rx_tuser_error  = err;
        end
        @(negedge clk);
        rx_tvalid_chunk = 1'b0;
        rx_tlast = 1'b0; rx_tuser_error = 1'b0;
    end
endtask

// Send one complete two-beat frame, then wait long enough for the whole
// pipeline to retire and any resulting order to finish serializing:
// parser (2) + book (2) + strategy (1) + order_tx (1) + TX load (1)
// + NCHUNKS chunks, with margin.
task send_frame;
    input [511:0] beat1;
    begin
        rx_start_cyc = cyc;
        drive_beat(fr_beat0(UDP_PORT, 64'd5000, 16'd1, 16'd36), {64{1'b1}}, 1'b0, 1'b0);
        drive_beat(beat1, {64{1'b1}}, 1'b1, 1'b0);
        repeat (40) @(negedge clk);
    end
endtask

task arm_pulse;
    begin
        @(negedge clk); i_arm = 1'b1;
        @(negedge clk); i_arm = 1'b0;
        @(negedge clk);
    end
endtask

task do_reset;
    begin
        rst_n = 0;
        rx_tdata_chunk = 0; rx_tkeep_chunk = 0; rx_tvalid_chunk = 0;
        rx_tlast = 0; rx_tuser_error = 0;
        tx_tready_chunk = 1'b1;
        i_udp_port = UDP_PORT; i_locate = LOCATE;
        i_enable = 1'b0; i_arm = 1'b0;
        i_buy_below_value = 32'd100_00; i_sell_above_value = 32'd110_00;
        i_quantity = 32'd250;
        clr_tx;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
    end
endtask

initial begin
    tx_collect_on = 0;
    do_reset;
    tx_collect_on = 1;

    $display("");
    $display("  ###############################################");
    $display("  #  tb_hft_top  (integration)                  #");
    $display("  ###############################################");
`ifndef ETHERTYPE_COMPAT
    $display("  NOTE: built without ETHERTYPE_COMPAT. While the parser");
    $display("        ethertype offset bug is open, no frame will be");
    $display("        accepted and every downstream check will fail.");
`endif

    //-----------------------------------------------------------------
    `TB_SECTION("Reset state at the pins")
    //-----------------------------------------------------------------
    `CHECK_EQ(tx_tvalid_chunk, 1'b0,  "no outbound traffic out of reset")
    `CHECK_EQ(o_armed,         1'b0,  "not armed")
    `CHECK_EQ(o_stat_frames,   32'd0, "frame counter zeroed")
    `CHECK_EQ(o_stat_orders,   32'd0, "order counter zeroed")
    `CHECK_EQ(rx_tready_chunk, 1'b1,  "RX ready to receive")

    //-----------------------------------------------------------------
    `TB_SECTION("Market data reaches the book")
    //-----------------------------------------------------------------
    // Resting ask at 150.00, outside the buy threshold, so no order yet.
    clr_tx;
    send_frame(fr_add_order(LOCATE, 64'd1, 1'b0, 32'd400, 32'd150_00));

    `CHECK_EQ(o_stat_frames,    32'd1, "frame counted at the top level")
    `CHECK_EQ(o_stat_accepted,  32'd1, "frame accepted by the header filter")
    `CHECK_EQ(o_best_ask_valid, 1'b1,  "best ask published on the status pins")
    `CHECK_EQ(o_best_ask,       32'd150_00, "best ask price correct end to end")
    `CHECK_EQ(tx_pkt_count,     0,     "no order sent while disarmed and disabled")

    //-----------------------------------------------------------------
    `TB_SECTION("No order while disarmed")
    //-----------------------------------------------------------------
    i_enable = 1'b1;              // enabled, but still not armed
    clr_tx;
    send_frame(fr_add_order(LOCATE, 64'd2, 1'b0, 32'd300, 32'd95_00)); // crosses threshold
    `CHECK_EQ(tx_pkt_count, 0, "enabled but disarmed does not trade")

    //-----------------------------------------------------------------
    `TB_SECTION("Tick to trade: attractive ask produces a buy order")
    //-----------------------------------------------------------------
    do_reset;
    tx_collect_on = 1;
    i_enable = 1'b1;
    arm_pulse;
    `CHECK_EQ(o_armed, 1'b1, "armed via the config pin")

    clr_tx;
    send_frame(fr_add_order(LOCATE, 64'd10, 1'b0, 32'd500, 32'd95_00));

    `CHECK_EQ(tx_pkt_count, 1,     "exactly one order packet emitted")
    `CHECK_EQ(o_stat_fires, 32'd1, "strategy fire counted")
    `CHECK_EQ(o_stat_orders,32'd1, "order counted")
    `CHECK_EQ(o_armed,      1'b0,  "disarmed after trading")

    if (tx_pkt_count > 0) begin
        $display("    [INFO] tick-to-trade: %0d cycles from first RX chunk to last TX chunk",
                 tx_done_cyc - rx_start_cyc);
        $display("    [INFO]                %0d cycles to first TX chunk",
                 tx_first_cyc - rx_start_cyc);
    end

    //-----------------------------------------------------------------
    `TB_SECTION("Outbound order packet contents")
    //-----------------------------------------------------------------
    `CHECK_EQ(fr_get(tx_pkt,  0, 6), 64'h00_0A_35_02_9D_E5, "destination MAC")
    `CHECK_EQ(fr_get(tx_pkt, 12, 2), 64'h0800,              "ethertype IPv4")
    `CHECK_EQ(fr_get(tx_pkt, 14, 1), 64'h45,                "IPv4 version/IHL")
    `CHECK_EQ(fr_get(tx_pkt, 23, 1), 64'd17,                "protocol UDP")
    `CHECK_EQ(fr_get(tx_pkt, 36, 2), 64'd41001,             "destination port")
    `CHECK_EQ(fr_get(tx_pkt, 42, 4), 64'h4157_4142,         "order magic 'AWAB'")
    `CHECK_EQ(fr_get(tx_pkt, 54, 4), 64'd95_00,             "order price is the ask we lifted")
    `CHECK_EQ(fr_get(tx_pkt, 58, 4), 64'd250,               "order quantity from config")
    `CHECK_EQ(fr_get(tx_pkt, 62, 1), 64'h42,                "side 'B' for buy")

    //-----------------------------------------------------------------
    `TB_SECTION("Sell side: attractive bid produces a sell order")
    //-----------------------------------------------------------------
    do_reset;
    tx_collect_on = 1;
    i_enable = 1'b1;
    arm_pulse;
    clr_tx;
    send_frame(fr_add_order(LOCATE, 64'd20, 1'b1, 32'd600, 32'd120_00));

    `CHECK_EQ(tx_pkt_count, 1, "one order packet emitted on the sell side")
    `CHECK_EQ(fr_get(tx_pkt, 62, 1), 64'h53,     "side 'S' for sell")
    `CHECK_EQ(fr_get(tx_pkt, 54, 4), 64'd120_00, "order price is the bid we hit")
    `CHECK_EQ(o_best_bid, 32'd120_00,            "best bid visible on the status pins")

    //-----------------------------------------------------------------
    `TB_SECTION("Market inside the band does not trade")
    //-----------------------------------------------------------------
    do_reset;
    tx_collect_on = 1;
    i_enable = 1'b1;
    arm_pulse;
    clr_tx;
    send_frame(fr_add_order(LOCATE, 64'd30, 1'b0, 32'd100, 32'd105_00)); // between thresholds
    `CHECK_EQ(tx_pkt_count, 0,    "no order when the market sits inside the band")
    `CHECK_EQ(o_armed,      1'b1, "still armed")

    //-----------------------------------------------------------------
    `TB_SECTION("Foreign stock locate is ignored")
    //-----------------------------------------------------------------
    clr_tx;
    send_frame(fr_add_order(16'd99, 64'd31, 1'b0, 32'd100, 32'd50_00));
    `CHECK_EQ(tx_pkt_count, 0,    "attractive price on another symbol does not trade")
    `CHECK_EQ(o_armed,      1'b1, "still armed after ignoring a foreign symbol")

    //-----------------------------------------------------------------
    `TB_SECTION("Malformed frames are dropped, not traded")
    //-----------------------------------------------------------------
    begin : bad_frames
        reg [31:0] drop0;
        drop0 = o_stat_dropped;
        clr_tx;
        // wrong destination UDP port
        rx_start_cyc = cyc;
        drive_beat(fr_beat0(16'd1234, 64'd1, 16'd1, 16'd36), {64{1'b1}}, 1'b0, 1'b0);
        drive_beat(fr_add_order(LOCATE, 64'd40, 1'b0, 32'd100, 32'd10_00), {64{1'b1}}, 1'b1, 1'b0);
        repeat (40) @(negedge clk);

        `CHECK_EQ(o_stat_dropped, drop0 + 1, "misdirected frame counted as dropped")
        `CHECK_EQ(tx_pkt_count,   0,         "misdirected frame does not trade")
        `CHECK_EQ(o_armed,        1'b1,      "still armed after a dropped frame")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("TX backpressure does not corrupt the order")
    //-----------------------------------------------------------------
    do_reset;
    tx_collect_on = 1;
    i_enable = 1'b1;
    arm_pulse;
    clr_tx;
    tx_tready_chunk = 1'b0;      // hold the outbound interface off
    send_frame(fr_add_order(LOCATE, 64'd50, 1'b0, 32'd500, 32'd90_00));
    `CHECK_EQ(tx_pkt_count, 0, "nothing transferred while the sink is stalled")
    `CHECK(tx_tvalid_chunk === 1'b1, "order is waiting on the TX pins")

    @(negedge clk);
    tx_tready_chunk = 1'b1;
    repeat (NCHUNKS + 6) @(negedge clk);
    `CHECK_EQ(tx_pkt_count, 1,           "order transfers once the sink accepts")
    `CHECK_EQ(fr_get(tx_pkt, 54, 4), 64'd90_00, "stalled order kept the right price")
    `CHECK_EQ(fr_get(tx_pkt, 62, 1), 64'h42,    "stalled order kept the right side")

    //-----------------------------------------------------------------
    `TB_SECTION("Statistics plumbing")
    //-----------------------------------------------------------------
    `CHECK_EQ(o_stat_bad_fcs,        32'd0, "no bad FCS seen")
    `CHECK_EQ(o_stat_overrun,        1'b0,  "no TX overrun in this scenario")
    `CHECK_EQ(o_order_id,            64'd1, "order id advanced once")
    `CHECK(o_stat_frames  > 32'd0,          "frame counter reaches the top level")
    `CHECK(o_stat_accepted> 32'd0,          "accepted counter reaches the top level")

    `TB_SUMMARY("tb_hft_top")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_hft_top.vcd");
        $dumpvars(0, tb_hft_top);
    end
end

endmodule
