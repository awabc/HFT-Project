`timescale 1ns/1ps
//=====================================================================
// tb_regression - constrained-random regression against a Python
// golden model.
//
// Replays the frame stream produced by verif/py/gen_vectors.py through
// the real 64-bit RX chunk pins of hft_top, and after every frame
// compares the DUT's published BBO and any emitted order against what
// verif/py/itch_model.py says should have happened.
//
// This is the test that catches behaviour no directed test thought to
// look for: unusual event orderings, index aliasing in the order table,
// reductions against partially consumed levels, and interleaved good
// and malformed frames.
//
// Regenerate the vectors and rerun with:
//     make regress FRAMES=500 SEED=7
//
// Build with +define+ETHERTYPE_COMPAT (and generate the vectors with
// --ethertype-compat) while the parser ethertype bug is open.
//=====================================================================
module tb_regression;

`include "tb_defs.vh"
`include "config.vh"

`TB_VARS

localparam CW        = 64;
localparam KW        = CW / 8;
localparam NCHUNKS   = 512 / CW;
localparam MAXFRAMES = 4096;
localparam NFRAMES   = `REG_NUM_FRAMES;

// Give the watchdog room: each frame is 2 beats plus settle time.
`TB_TIMEOUT(NFRAMES * 120 + 5000)

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

reg         i_arm;
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
    .i_udp_port(`REG_UDP_PORT), 
	.i_locate(`REG_LOCATE), 
	.i_enable(1'b1),
    .i_buy_below_value(`REG_BUY_BELOW), 
	.i_sell_above_value(`REG_SELL_ABOVE),
    .i_quantity(`REG_QUANTITY), 
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

//---------------------------------------------------------------------
// Vectors
//---------------------------------------------------------------------
reg [511:0] stim_beats [0:2*MAXFRAMES-1];
reg [7:0]   stim_ctrl  [0:MAXFRAMES-1];
reg [183:0] expected   [0:MAXFRAMES-1];

//---------------------------------------------------------------------
// Outbound order collector
//---------------------------------------------------------------------
reg [511:0] tx_acc, tx_pkt;
integer     tx_chunk_i, tx_pkt_count;
reg [CW-1:0] tx_samp;
always @(posedge clk) #2 tx_samp = tx_tdata_chunk;

always @(posedge clk) begin
    if (rst_n && tx_tvalid_chunk && tx_tready_chunk) begin
        tx_acc     = (tx_acc << CW) | {{(512-CW){1'b0}}, tx_samp};
        tx_chunk_i = tx_chunk_i + 1;
        if (tx_chunk_i == NCHUNKS) begin
            tx_pkt       = tx_acc;
            tx_pkt_count = tx_pkt_count + 1;
            tx_chunk_i   = 0;
        end
    end
end

function automatic [63:0] pkt_get;
    input [511:0] d;
    input integer off;
    input integer n;
    reg   [63:0]  r;
    integer j;
    begin
        r = 64'd0;
        for (j = 0; j < n; j = j + 1)
            r = (r << 8) | {56'd0, d[8*(off+j) +: 8]};
        pkt_get = r;
    end
endfunction

//---------------------------------------------------------------------
// Drivers
//---------------------------------------------------------------------
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

task arm_pulse;
    begin
        @(negedge clk); i_arm = 1'b1;
        @(negedge clk); i_arm = 1'b0;
    end
endtask

//---------------------------------------------------------------------
integer f;
integer mismatches;
integer reported;
integer orders_seen, orders_expected;

reg [183:0] e;
reg         e_bid_v, e_ask_v, e_fired, e_is_buy;
reg [31:0]  e_bid, e_ask, e_oprice, e_oshares;
reg [23:0]  e_bid_q, e_ask_q;
reg [63:0]  keep0;
integer     prev_pkt_count;

initial begin
    $display("");
    $display("  ###############################################");
    $display("  #  tb_regression  (%0d frames vs golden model) #", NFRAMES);
    $display("  ###############################################");

    $readmemh("vectors/stim_beats.hex", stim_beats);
    $readmemh("vectors/stim_ctrl.hex",  stim_ctrl);
    $readmemh("vectors/expected.hex",   expected);

    rx_tdata_chunk = 0; rx_tkeep_chunk = 0; rx_tvalid_chunk = 0;
    rx_tlast = 0; rx_tuser_error = 0; tx_tready_chunk = 1'b1;
    i_arm = 0;
    tx_acc = 0; tx_chunk_i = 0; tx_pkt_count = 0;
    mismatches = 0; reported = 0; orders_seen = 0; orders_expected = 0;

    rst_n = 0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (3) @(negedge clk);

    for (f = 0; f < NFRAMES; f = f + 1) begin
        e = expected[f];
        e_bid_v   = e[2];
        e_ask_v   = e[3];
        e_fired   = e[4];
        e_is_buy  = e[5];
        e_bid     = e[37:6];
        e_ask     = e[69:38];
        e_bid_q   = e[93:70];
        e_ask_q   = e[117:94];
        e_oprice  = e[149:118];
        e_oshares = e[181:150];

        keep0 = stim_ctrl[f][0] ? {64{1'b1}} : 64'h7FFF_FFFF_FFFF_FFFF;

        prev_pkt_count = tx_pkt_count;

        arm_pulse;
        drive_beat(stim_beats[2*f],   keep0,       1'b0, 1'b0);
        drive_beat(stim_beats[2*f+1], {64{1'b1}},  1'b1, stim_ctrl[f][1]);
        repeat (40) @(negedge clk);

        // --- compare against the model ---
        if (e_fired) orders_expected = orders_expected + 1;
        if (tx_pkt_count > prev_pkt_count) orders_seen = orders_seen + 1;

        if ((o_best_bid_valid      !== e_bid_v) ||
            (o_best_ask_valid      !== e_ask_v) ||
            (e_bid_v && (o_best_bid !== e_bid)) ||
            (e_ask_v && (o_best_ask !== e_ask)) ||
            (e_bid_v && (o_best_bid_quantity[23:0] !== e_bid_q)) ||
            (e_ask_v && (o_best_ask_quantity[23:0] !== e_ask_q))) begin
            mismatches = mismatches + 1;
            if (reported < 10) begin
                reported = reported + 1;
                $display("    [FAIL] frame %0d BBO mismatch", f);
                $display("             dut : bid %0d x%0d (v=%b)   ask %0d x%0d (v=%b)",
                         o_best_bid, o_best_bid_quantity, o_best_bid_valid,
                         o_best_ask, o_best_ask_quantity, o_best_ask_valid);
                $display("             model: bid %0d x%0d (v=%b)   ask %0d x%0d (v=%b)",
                         e_bid, e_bid_q, e_bid_v, e_ask, e_ask_q, e_ask_v);
            end
        end

        if (e_fired && (tx_pkt_count > prev_pkt_count)) begin
            if ((pkt_get(tx_pkt, 54, 4) !== {32'd0, e_oprice}) ||
                (pkt_get(tx_pkt, 58, 4) !== {32'd0, e_oshares}) ||
                (pkt_get(tx_pkt, 62, 1) !== (e_is_buy ? 64'h42 : 64'h53))) begin
                mismatches = mismatches + 1;
                if (reported < 10) begin
                    reported = reported + 1;
                    $display("    [FAIL] frame %0d order mismatch", f);
                    $display("             dut : price %0d shares %0d side %0h",
                             pkt_get(tx_pkt, 54, 4), pkt_get(tx_pkt, 58, 4),
                             pkt_get(tx_pkt, 62, 1));
                    $display("             model: price %0d shares %0d side %0h",
                             e_oprice, e_oshares, e_is_buy ? 8'h42 : 8'h53);
                end
            end
        end
    end

    $display("");
    $display("    [INFO] frames driven          : %0d", NFRAMES);
    $display("    [INFO] dut  accepted/dropped  : %0d / %0d", o_stat_accepted, o_stat_dropped);
    $display("    [INFO] dut  fires / orders    : %0d / %0d", o_stat_fires, o_stat_orders);
    $display("    [INFO] orders on the wire     : %0d (model expected %0d)",
             orders_seen, orders_expected);
    $display("    [INFO] book conflict flag     : %b", o_stat_book_conflict);
    $display("    [INFO] tx overrun flag        : %b", o_stat_overrun);
    if (reported >= 10)
        $display("    [INFO] (further mismatches suppressed)");

    `TB_SECTION("Regression verdict")
    `CHECK_EQ(mismatches,  0,               "every frame matched the golden model")
    `CHECK_EQ(orders_seen, orders_expected, "order count on the wire matches the model")
    `CHECK_EQ(o_stat_frames, NFRAMES,       "every frame was counted by the parser")

    `TB_SUMMARY("tb_regression")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_regression.vcd");
        $dumpvars(0, tb_regression);
    end
end

endmodule
