`timescale 1ns/1ps
//=====================================================================
// tb_book - unit level tests for book.v
//
// Drives packed event markers directly, bypassing the parser, so book
// behaviour can be tested independently of the parser bugs.
//
// Pipeline timing being exercised:
//   cycle N    : event presented. is_add prices the order and writes
//                the order table; is_red/is_delete latch into pending.
//   cycle N+1  : quantity applied for adds (qa_* stage); proceed
//                asserts for reductions and applies the share maths.
//   cycle N+2  : results settled.
//
// Covers:
//   * add / improve / worsen / equal-price aggregation on both sides
//   * Executed, Cancel and Delete reductions
//   * BBO invalidation when the resting size is fully consumed
//   * stock locate filtering
//   * the sticky book-conflict flag
//   * behaviour of the order table before anything has been written
//=====================================================================
module tb_book;

`include "tb_defs.vh"
`include "itch_frame.vh"

`TB_VARS
`TB_TIMEOUT(20000)

localparam LOCATE = 16'd7;
localparam OTHER  = 16'd9;

reg          clk = 0;
reg          rst_n = 0;
always #5 clk = ~clk;

reg          i_event_valid;
reg  [144:0] i_event_marker;

wire         o_valid;
wire [31:0]  o_best_bid,  o_best_ask;
wire [23:0]  o_best_bid_quantity, o_best_ask_quantity;
wire         o_best_bid_valid, o_best_ask_valid;
wire         o_stat_book_conflict;

book dut (
    .i_clk(clk), 
	.i_rst_n(rst_n),
    .i_event_valid(i_event_valid), 
	.i_event_marker(i_event_marker), 
	.i_locate(LOCATE),
    .o_valid(o_valid),
    .o_best_bid(o_best_bid), 
	.o_best_bid_quantity(o_best_bid_quantity),
    .o_best_bid_valid(o_best_bid_valid),
    .o_best_ask(o_best_ask), 
	.o_best_ask_quantity(o_best_ask_quantity),
    .o_best_ask_valid(o_best_ask_valid),
    .o_stat_book_conflict(o_stat_book_conflict)
);

// Pack a marker the way parser.v does
function automatic [144:0] mk_marker;
    input [7:0]  mtype;
    input [15:0] locate;
    input [63:0] order_ref;
    input        is_buy;
    input [23:0] shares;
    input [31:0] price;
    reg   [144:0] m;
    begin
        m = 145'd0;
        m[7:0]     = mtype;
        m[23:8]    = locate;
        m[87:24]   = order_ref;
        m[88]      = is_buy;
        m[112:89]  = shares;
        m[144:113] = price;
        mk_marker  = m;
    end
endfunction

// Present one event for a single cycle, then leave enough idle cycles
// for both pipeline stages to retire before anything is sampled
task send_event;
    input [144:0] m;
    begin
        @(negedge clk);
        i_event_marker = m;
        i_event_valid  = 1'b1;
        @(negedge clk);
        i_event_valid  = 1'b0;
        i_event_marker = 145'd0;
        repeat (3) @(negedge clk);
    end
endtask

task add_order;
    input [63:0] ref_;
    input        is_buy;
    input [23:0] shares;
    input [31:0] price;
    begin
        send_event(mk_marker(ITCH_ADD_ORDER, LOCATE, ref_, is_buy, shares, price));
    end
endtask

task exec_order;
    input [63:0] ref_;
    input [23:0] shares;
    begin
        send_event(mk_marker(ITCH_EXECUTED, LOCATE, ref_, 1'b0, shares, 32'd0));
    end
endtask

task cancel_order;
    input [63:0] ref_;
    input [23:0] shares;
    begin
        send_event(mk_marker(ITCH_CANCEL, LOCATE, ref_, 1'b0, shares, 32'd0));
    end
endtask

task delete_order;
    input [63:0] ref_;
    begin
        send_event(mk_marker(ITCH_DELETE, LOCATE, ref_, 1'b0, 24'd0, 32'd0));
    end
endtask

task do_reset;
    begin
        rst_n = 0;
        i_event_valid = 0;
        i_event_marker = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
    end
endtask

// Watch o_valid so the BBO-changed pulse can be checked.
integer bbo_pulses;
reg     watch_on;
always @(posedge clk) if (rst_n && watch_on && o_valid) bbo_pulses = bbo_pulses + 1;

integer i;

initial begin
    watch_on = 0; bbo_pulses = 0;
    do_reset;
    watch_on = 1;

    $display("");
    $display("  ###############################################");
    $display("  #  tb_book                                    #");
    $display("  ###############################################");

    //-----------------------------------------------------------------
    `TB_SECTION("Order table contents before any write")
    //-----------------------------------------------------------------
    `CHECK_EQ(o_best_bid_valid, 1'b0, "best bid invalid out of reset")
    `CHECK_EQ(o_best_ask_valid, 1'b0, "best ask invalid out of reset")
    `CHECK_KNOWN_BUG(dut.order_valid[0] === 1'b0,
        "order table entry 0 is cleared by reset",
        "book.v declares order_valid[DEPTH] but never resets it; a reduce against an untouched index reads X in sim and random data on silicon")

    //-----------------------------------------------------------------
    `TB_SECTION("First bid establishes the BBO")
    //-----------------------------------------------------------------
    do_reset; bbo_pulses = 0;
    add_order(64'd1, 1'b1, 24'd500, 32'd100_00);
    `CHECK_EQ(o_best_bid_valid,    1'b1,       "best bid becomes valid")
    `CHECK_EQ(o_best_bid,          32'd100_00, "best bid price")
    `CHECK_EQ(o_best_bid_quantity, 24'd500,    "best bid quantity")
    `CHECK(bbo_pulses > 0,                     "o_valid pulsed on BBO change")

    //-----------------------------------------------------------------
    `TB_SECTION("Better bid replaces, worse bid is ignored")
    //-----------------------------------------------------------------
    add_order(64'd2, 1'b1, 24'd300, 32'd101_00);
    `CHECK_EQ(o_best_bid,          32'd101_00, "higher bid takes over")
    `CHECK_EQ(o_best_bid_quantity, 24'd300,    "quantity replaced, not accumulated")

    add_order(64'd3, 1'b1, 24'd900, 32'd99_00);
    `CHECK_EQ(o_best_bid,          32'd101_00, "lower bid does not change best bid")
    `CHECK_EQ(o_best_bid_quantity, 24'd300,    "lower bid does not change quantity")

    //-----------------------------------------------------------------
    `TB_SECTION("Equal-price bid aggregates quantity")
    //-----------------------------------------------------------------
    add_order(64'd4, 1'b1, 24'd150, 32'd101_00);
    `CHECK_EQ(o_best_bid,          32'd101_00, "price unchanged at same level")
    `CHECK_EQ(o_best_bid_quantity, 24'd450,    "quantity accumulates at same level (300+150)")

    //-----------------------------------------------------------------
    `TB_SECTION("Ask side: lower is better")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd10, 1'b0, 24'd400, 32'd105_00);
    `CHECK_EQ(o_best_ask_valid,    1'b1,       "best ask becomes valid")
    `CHECK_EQ(o_best_ask,          32'd105_00, "best ask price")
    `CHECK_EQ(o_best_ask_quantity, 24'd400,    "best ask quantity")

    add_order(64'd11, 1'b0, 24'd250, 32'd104_00);
    `CHECK_EQ(o_best_ask,          32'd104_00, "lower ask takes over")
    `CHECK_EQ(o_best_ask_quantity, 24'd250,    "ask quantity replaced")

    add_order(64'd12, 1'b0, 24'd800, 32'd106_00);
    `CHECK_EQ(o_best_ask,          32'd104_00, "higher ask does not change best ask")

    add_order(64'd13, 1'b0, 24'd50, 32'd104_00);
    `CHECK_EQ(o_best_ask_quantity, 24'd300,    "ask quantity aggregates at same level (250+50)")

    //-----------------------------------------------------------------
    `TB_SECTION("Partial execution reduces displayed size")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd20, 1'b1, 24'd1000, 32'd200_00);
    `CHECK_EQ(o_best_bid_quantity, 24'd1000, "resting bid size before execution")

    exec_order(64'd20, 24'd400);
    `CHECK_EQ(o_best_bid,          32'd200_00, "price unchanged by partial execution")
    `CHECK_EQ(o_best_bid_quantity, 24'd600,    "size reduced by executed shares")
    `CHECK_EQ(o_best_bid_valid,    1'b1,       "bid still valid after partial execution")

    //-----------------------------------------------------------------
    `TB_SECTION("Full execution invalidates the level")
    //-----------------------------------------------------------------
    exec_order(64'd20, 24'd600);
    `CHECK_EQ(o_best_bid_quantity, 24'd0, "size drops to zero")
    `CHECK_EQ(o_best_bid_valid,    1'b0, "bid level invalidated when fully consumed")

    //-----------------------------------------------------------------
    `TB_SECTION("Cancel behaves like a reduction")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd30, 1'b0, 24'd500, 32'd150_00);
    cancel_order(64'd30, 24'd200);
    `CHECK_EQ(o_best_ask_quantity, 24'd300, "cancel reduces ask size")
    `CHECK_EQ(o_best_ask_valid,    1'b1,    "ask still valid after partial cancel")

    //-----------------------------------------------------------------
    `TB_SECTION("Delete removes the whole resting order")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd40, 1'b1, 24'd750, 32'd175_00);
    delete_order(64'd40);
    `CHECK_EQ(o_best_bid_quantity, 24'd0, "delete removes full resting size")
    `CHECK_EQ(o_best_bid_valid,    1'b0, "bid invalidated by delete")

    //-----------------------------------------------------------------
    `TB_SECTION("Over-sized reduction clamps instead of wrapping")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd45, 1'b1, 24'd100, 32'd90_00);
    exec_order(64'd45, 24'd999);   // more than is resting
    `CHECK_EQ(o_best_bid_quantity, 24'd0, "over-execution clamps to zero, no underflow")
    `CHECK_EQ(o_best_bid_valid,    1'b0, "level invalidated")

    //-----------------------------------------------------------------
    `TB_SECTION("Stock locate filtering")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd50, 1'b1, 24'd400, 32'd120_00);
    send_event(mk_marker(ITCH_ADD_ORDER, OTHER, 64'd51, 1'b1, 24'd999, 32'd130_00));
    `CHECK_EQ(o_best_bid,          32'd120_00, "event for a different locate is ignored")
    `CHECK_EQ(o_best_bid_quantity, 24'd400,    "quantity untouched by foreign locate")

    //-----------------------------------------------------------------
    `TB_SECTION("Index aliasing in the direct-mapped table")
    //-----------------------------------------------------------------
    // Only the low ORDER_INDEX_W bits of the order reference select the
    // entry, so refs 1 and 65 collide in a 64-entry table. The second
    // add overwrites the first; a later reduction against ref 1 then
    // operates on ref 65's data.
    do_reset;
    add_order(64'd1,  1'b1, 24'd100, 32'd50_00);
    add_order(64'd65, 1'b1, 24'd700, 32'd60_00);   // same index as ref 1
    `CHECK_EQ(dut.order_shares[1], 24'd700, "colliding reference overwrote the table entry")
    `CHECK_EQ(o_best_bid,          32'd60_00, "BBO reflects the newer order")

    //-----------------------------------------------------------------
    `TB_SECTION("Book conflict flag")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd60, 1'b1, 24'd500, 32'd80_00);
    `CHECK_EQ(o_stat_book_conflict, 1'b0, "conflict flag clear during well-spaced traffic")

    @(negedge clk);
    i_event_marker = mk_marker(ITCH_EXECUTED, LOCATE, 64'd60, 1'b0, 24'd100, 32'd0);
    i_event_valid  = 1'b1;
    @(negedge clk);
    i_event_marker = mk_marker(ITCH_ADD_ORDER, LOCATE, 64'd61, 1'b1, 24'd200, 32'd81_00);
    @(negedge clk);
    i_event_valid  = 1'b0;
    i_event_marker = 145'd0;
    repeat (4) @(negedge clk);
    `CHECK_EQ(o_stat_book_conflict, 1'b1, "back-to-back add over a retiring reduction sets the sticky conflict flag")

    //-----------------------------------------------------------------
    `TB_SECTION("Both sides tracked independently")
    //-----------------------------------------------------------------
    do_reset;
    add_order(64'd70, 1'b1, 24'd300, 32'd99_00);
    add_order(64'd71, 1'b0, 24'd400, 32'd101_00);
    `CHECK_EQ(o_best_bid,          32'd99_00,  "bid held while ask is added")
    `CHECK_EQ(o_best_bid_quantity, 24'd300,    "bid quantity held")
    `CHECK_EQ(o_best_ask,          32'd101_00, "ask recorded")
    `CHECK_EQ(o_best_ask_quantity, 24'd400,    "ask quantity recorded")
    `CHECK(o_best_bid < o_best_ask,            "book is not crossed")

    `TB_SUMMARY("tb_book")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_book.vcd");
        $dumpvars(0, tb_book);
    end
end

endmodule
