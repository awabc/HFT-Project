`timescale 1ns/1ps
//=====================================================================
// tb_strategy - unit level tests for strategy.v
//
// Covers:
//   * arm / disarm behaviour and the single-shot guarantee
//   * buy trigger  (best ask <= buy_below)
//   * sell trigger (best bid >= sell_above)
//   * every guard that must suppress a fire: not armed, not enabled,
//     BBO side invalid, no bbo_valid pulse, price outside threshold
//   * boundary conditions at exactly the threshold price
//   * fire payload (price / shares / side)
//   * fire counter
//=====================================================================
module tb_strategy;

`include "tb_defs.vh"

`TB_VARS
`TB_TIMEOUT(20000)

reg         clk = 0;
reg         rst_n = 0;
always #5 clk = ~clk;

reg         i_bbo_valid;
reg  [31:0] i_best_bid;
reg         i_best_bid_valid;
reg  [31:0] i_best_ask;
reg         i_best_ask_valid;
reg         i_config_enable;
reg  [31:0] i_buy_below;
reg  [31:0] i_sell_above;
reg  [31:0] i_quantity;
reg         i_arm_pulse;

wire        o_fire;
wire [31:0] o_fire_price, o_fire_shares;
wire        o_fire_is_buy, o_armed;
wire [31:0] o_stat_fires;

strategy dut (
    .i_clk				(clk), 
	.i_rst_n			(rst_n),
    .i_bbo_valid		(i_bbo_valid),
    .i_best_bid			(i_best_bid), 
	.i_best_bid_valid	(i_best_bid_valid),
    .i_best_ask			(i_best_ask), 
	.i_best_ask_valid	(i_best_ask_valid),
    .i_config_enable	(i_config_enable),
    .i_buy_below		(i_buy_below), 
	.i_sell_above		(i_sell_above),
    .i_quantity			(i_quantity), 
	.i_arm_pulse		(i_arm_pulse),
    .o_fire				(o_fire), 
	.o_fire_price		(o_fire_price), 
	.o_fire_shares		(o_fire_shares),
    .o_fire_is_buy		(o_fire_is_buy), 
	.o_armed			(o_armed), 
	.o_stat_fires		(o_stat_fires)
);

// Capture the fire pulse and its payload
reg        saw_fire;
reg [31:0] fire_price_c, fire_shares_c;
reg        fire_is_buy_c;
integer    fire_count;
reg        watch_on;

always @(posedge clk) begin
    if (rst_n && watch_on && o_fire) begin
        saw_fire      = 1'b1;
        fire_price_c  = o_fire_price;
        fire_shares_c = o_fire_shares;
        fire_is_buy_c = o_fire_is_buy;
        fire_count    = fire_count + 1;
    end
end

task clr;
    begin saw_fire = 0; fire_count = 0; end
endtask

task arm;
    begin
        @(negedge clk);
        i_arm_pulse = 1'b1;
        @(negedge clk);
        i_arm_pulse = 1'b0;
        @(negedge clk);
    end
endtask

// Present one BBO update pulse.
task bbo;
    input [31:0] bid;
    input        bid_v;
    input [31:0] ask;
    input        ask_v;
    begin
        @(negedge clk);
        i_best_bid = bid; i_best_bid_valid = bid_v;
        i_best_ask = ask; i_best_ask_valid = ask_v;
        i_bbo_valid = 1'b1;
        @(negedge clk);
        i_bbo_valid = 1'b0;
        repeat (2) @(negedge clk);
    end
endtask

task do_reset;
    begin
        rst_n = 0;
        i_bbo_valid = 0; i_best_bid = 0; i_best_bid_valid = 0;
        i_best_ask = 0; i_best_ask_valid = 0;
        i_config_enable = 0; i_arm_pulse = 0;
        i_buy_below = 32'd100_00; i_sell_above = 32'd110_00; i_quantity = 32'd250;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
    end
endtask

initial begin
    watch_on = 0; clr;
    do_reset;
    watch_on = 1;

    $display("");
    $display("  ###############################################");
    $display("  #  tb_strategy                                #");
    $display("  ###############################################");

    //-----------------------------------------------------------------
    `TB_SECTION("Reset state")
    //-----------------------------------------------------------------
    `CHECK_EQ(o_armed,      1'b0,   "not armed out of reset")
    `CHECK_EQ(o_fire,       1'b0,   "not firing out of reset")
    `CHECK_EQ(o_stat_fires, 32'd0,  "fire counter starts at zero")

    //-----------------------------------------------------------------
    `TB_SECTION("Arming")
    //-----------------------------------------------------------------
    arm;
    `CHECK_EQ(o_armed, 1'b1, "arm pulse arms the strategy")

    //-----------------------------------------------------------------
    `TB_SECTION("No fire while disabled")
    //-----------------------------------------------------------------
    i_config_enable = 1'b0;
    clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b1);   // ask well below buy_below
    `CHECK_EQ(fire_count, 0,    "armed but disabled does not fire")
    `CHECK_EQ(o_armed,    1'b1, "still armed after a suppressed trigger")

    //-----------------------------------------------------------------
    `TB_SECTION("Buy trigger: best ask at or below buy_below")
    //-----------------------------------------------------------------
    i_config_enable = 1'b1;
    clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b1);
    `CHECK_EQ(fire_count,    1,          "fires once when ask crosses the buy threshold")
    `CHECK_EQ(fire_is_buy_c, 1'b1,       "fire is a buy")
    `CHECK_EQ(fire_price_c,  32'd95_00,  "fire price is the best ask being lifted")
    `CHECK_EQ(fire_shares_c, 32'd250,    "fire quantity comes from config")
    `CHECK_EQ(o_stat_fires,  32'd1,      "fire counter incremented")
    `CHECK_EQ(o_armed,       1'b0,       "disarmed after firing")

    //-----------------------------------------------------------------
    `TB_SECTION("Single shot: no second fire without re-arming")
    //-----------------------------------------------------------------
    clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b1);
    bbo(32'd90_00, 1'b1, 32'd94_00, 1'b1);
    `CHECK_EQ(fire_count,   0,     "does not fire again while disarmed")
    `CHECK_EQ(o_stat_fires, 32'd1, "fire counter unchanged")

    //-----------------------------------------------------------------
    `TB_SECTION("Sell trigger: best bid at or above sell_above")
    //-----------------------------------------------------------------
    arm;
    clr;
    bbo(32'd115_00, 1'b1, 32'd120_00, 1'b1);  // ask above buy_below, bid above sell_above
    `CHECK_EQ(fire_count,    1,           "fires on the sell side")
    `CHECK_EQ(fire_is_buy_c, 1'b0,        "fire is a sell")
    `CHECK_EQ(fire_price_c,  32'd115_00,  "fire price is the best bid being hit")
    `CHECK_EQ(o_stat_fires,  32'd2,       "fire counter incremented again")

    //-----------------------------------------------------------------
    `TB_SECTION("Threshold boundaries are inclusive")
    //-----------------------------------------------------------------
    arm; clr;
    bbo(32'd50_00, 1'b1, 32'd100_00, 1'b1);   // ask exactly == buy_below
    `CHECK_EQ(fire_count,    1,    "fires when ask equals buy_below exactly")
    `CHECK_EQ(fire_is_buy_c, 1'b1, "boundary fire is a buy")

    arm; clr;
    bbo(32'd110_00, 1'b1, 32'd200_00, 1'b1);  // bid exactly == sell_above
    `CHECK_EQ(fire_count,    1,    "fires when bid equals sell_above exactly")
    `CHECK_EQ(fire_is_buy_c, 1'b0, "boundary fire is a sell")

    //-----------------------------------------------------------------
    `TB_SECTION("Prices outside the thresholds do not fire")
    //-----------------------------------------------------------------
    arm; clr;
    bbo(32'd105_00, 1'b1, 32'd108_00, 1'b1);  // inside the band, neither side triggers
    `CHECK_EQ(fire_count, 0,    "no fire when the market sits between thresholds")
    `CHECK_EQ(o_armed,    1'b1, "stays armed when nothing triggers")

    //-----------------------------------------------------------------
    `TB_SECTION("Invalid BBO sides are ignored")
    //-----------------------------------------------------------------
    clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b0);    // attractive ask, but ask invalid
    `CHECK_EQ(fire_count, 0, "invalid ask does not trigger a buy")

    clr;
    bbo(32'd115_00, 1'b0, 32'd120_00, 1'b1);  // attractive bid, but bid invalid
    `CHECK_EQ(fire_count, 0, "invalid bid does not trigger a sell")
    `CHECK_EQ(o_armed,    1'b1, "still armed after both suppressed triggers")

    //-----------------------------------------------------------------
    `TB_SECTION("A trigger requires the bbo_valid pulse")
    //-----------------------------------------------------------------
    // Hold an attractive market on the data inputs without pulsing
    // bbo_valid. Nothing should happen, the strategy is edge driven.
    clr;
    @(negedge clk);
    i_best_bid = 32'd90_00; i_best_bid_valid = 1'b1;
    i_best_ask = 32'd95_00; i_best_ask_valid = 1'b1;
    i_bbo_valid = 1'b0;
    repeat (6) @(negedge clk);
    `CHECK_EQ(fire_count, 0, "steady attractive market with no bbo_valid does not fire")

    //-----------------------------------------------------------------
    `TB_SECTION("Buy takes priority when both sides qualify")
    //-----------------------------------------------------------------
    // With a crossed/locked configuration both buy_order and sell_order
    // can be true at once. evaluate the buy branch first.
    arm; clr;
    i_buy_below  = 32'd200_00;
    i_sell_above = 32'd1_00;
    bbo(32'd150_00, 1'b1, 32'd160_00, 1'b1);
    `CHECK_EQ(fire_count,    1,    "exactly one fire when both sides qualify")
    `CHECK_EQ(fire_is_buy_c, 1'b1, "code prioritises the buy branch (comment says otherwise)")

    //-----------------------------------------------------------------
    `TB_SECTION("Re-arming restores firing")
    //-----------------------------------------------------------------
    i_buy_below = 32'd100_00; i_sell_above = 32'd110_00;
    arm;
    `CHECK_EQ(o_armed, 1'b1, "re-arm works after a fire")
    clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b1);
    `CHECK_EQ(fire_count, 1, "fires again after re-arming")

    //-----------------------------------------------------------------
    `TB_SECTION("Fire is a single-cycle pulse")
    //-----------------------------------------------------------------
    arm; clr;
    bbo(32'd90_00, 1'b1, 32'd95_00, 1'b1);
    `CHECK_EQ(fire_count, 1, "fire asserted for exactly one cycle")

    `TB_SUMMARY("tb_strategy")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_strategy.vcd");
        $dumpvars(0, tb_strategy);
    end
end

endmodule
