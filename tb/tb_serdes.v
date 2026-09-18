`timescale 1ns/1ps
//=====================================================================
// tb_serdes - tests the narrow-pin AXI4-Stream chunking at the top
// level boundary of hft_top, independently of the trading pipeline.
//
// The RX deserializer and TX serializer are exercised directly:
//   * RX: chunks are driven in on the real pins and the reassembled
//     512-bit beat is checked at parser_inst's input.
//   * TX: order_tx's output is forced to a known pattern so the
//     serializer can be drained and checked without needing the
//     pipeline to produce an order.
//
// Covers:
//   * MSB-first chunk ordering in both directions
//   * tkeep travelling with its data chunk
//   * tlast / tuser_error latching onto the assembled beat
//   * backpressure on the TX chunk interface
//   * rx_tready behaviour
//   * gaps in the input stream (tvalid deasserting mid-beat)
//   * measured serialization latency in each direction
//=====================================================================
module tb_serdes;

`include "tb_defs.vh"

`TB_VARS
`TB_TIMEOUT(20000)

localparam CW      = 64;                 // must match hft_top CHUNK_WIDTH
localparam KW      = CW / 8;
localparam NCHUNKS = 512 / CW;

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
    .i_udp_port(16'd26400), 
	.i_locate(16'd7), 
	.i_enable(1'b0),
    .i_buy_below_value(32'd0), 
	.i_sell_above_value(32'd0),
    .i_quantity(32'd0), 
	.i_arm(1'b0),
    .o_best_bid(), 
	.o_best_bid_quantity(), 
	.o_best_bid_valid(),
    .o_best_ask(), 
	.o_best_ask_quantity(), 
	.o_best_ask_valid(), 
	.o_armed(),
    .o_stat_frames(), 
	.o_stat_accepted(), 
	.o_stat_bad_fcs(), 
	.o_stat_dropped(),
    .o_stat_fires(), 
	.o_stat_orders(), 
	.o_stat_overrun(),
    .o_stat_book_conflict(), 
	.o_order_id()
);

integer cyc;
initial cyc = 0;
always @(posedge clk) cyc = cyc + 1;

reg [511:0] pattern;
reg [63:0]  keeppat;
integer i;
integer rx_first, rx_done;
integer tx_start, tx_first, tx_last_c;
integer tx_idx, tx_errs;
reg     tx_sb_on;

// sample the TX bus mid-cycle so the value checked is the one a real
// receiver would latch at the next rising edge.
reg [CW-1:0] samp;
reg [KW-1:0] samp_k;
always @(posedge clk) #2 begin samp = tx_tdata_chunk; samp_k = tx_tkeep_chunk; end

always @(posedge clk) begin
    if (tx_sb_on && tx_tvalid_chunk && tx_tready_chunk) begin
        if (tx_first < 0) tx_first = cyc;
        if (samp !== pattern[511 - tx_idx*CW -: CW]) begin
            $display("    [FAIL] TX chunk %0d: got=%h expected=%h",
                     tx_idx, samp, pattern[511 - tx_idx*CW -: CW]);
            tx_errs = tx_errs + 1;
        end
        if (samp_k !== keeppat[63 - tx_idx*KW -: KW]) begin
            $display("    [FAIL] TX tkeep chunk %0d: got=%h expected=%h",
                     tx_idx, samp_k, keeppat[63 - tx_idx*KW -: KW]);
            tx_errs = tx_errs + 1;
        end
        tx_idx    = tx_idx + 1;
        tx_last_c = cyc;
    end
end

// drive one beat as NCHUNKS chunks, optionally inserting an idle gap.
task drive_beat;
    input [511:0] d;
    input [63:0]  k;
    input         last;
    input         err;
    input integer gap_after_chunk;   // -1 for none
    integer c;
    begin
        for (c = 0; c < NCHUNKS; c = c + 1) begin
            @(negedge clk);
            if (c == 0) rx_first = cyc;
            rx_tdata_chunk  = d[511 - c*CW -: CW];
            rx_tkeep_chunk  = k[63 - c*KW -: KW];
            rx_tvalid_chunk = 1'b1;
            rx_tlast        = last;
            rx_tuser_error  = err;
            if (c == gap_after_chunk) begin
                @(negedge clk);
                rx_tvalid_chunk = 1'b0;
                rx_tdata_chunk  = {CW{1'bx}};   // must be ignored while invalid
                repeat (3) @(negedge clk);
            end
        end
        @(negedge clk);
        rx_tvalid_chunk = 1'b0;
        rx_tlast = 0; rx_tuser_error = 0;
    end
endtask

initial begin
    rx_tdata_chunk = 0; rx_tkeep_chunk = 0; rx_tvalid_chunk = 0;
    rx_tlast = 0; rx_tuser_error = 0; tx_tready_chunk = 0;
    tx_sb_on = 0; tx_idx = 0; tx_errs = 0; tx_first = -1;
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);

    $display("");
    $display("  ###############################################");
    $display("  #  tb_serdes  (CHUNK_WIDTH=%0d)                #", CW);
    $display("  ###############################################");

    // Distinctive per-chunk pattern
    pattern = 0;
    keeppat = 64'hFFFF_FFFF_FFFF_FF0F;
    for (i = 0; i < NCHUNKS; i = i + 1)
        pattern = (pattern << CW) | (64'hC0DE_0000_0000_0000 + i);

    //-----------------------------------------------------------------
    `TB_SECTION("RX ready behaviour")
    //-----------------------------------------------------------------
    `CHECK_EQ(rx_tready_chunk, 1'b1, "rx_tready is asserted (reassembly never stalls the source)")

    //-----------------------------------------------------------------
    `TB_SECTION("RX reassembly, MSB first")
    //-----------------------------------------------------------------
    fork
        drive_beat(pattern, keeppat, 1'b1, 1'b0, -1);
        begin @(posedge uut.rx_valid_word); rx_done = cyc; end
    join
    repeat (2) @(negedge clk);

    `CHECK_EQ(uut.rx_data_word, pattern, "512-bit beat reassembled in MSB-first order")
    `CHECK_EQ(uut.rx_keep_word, keeppat, "tkeep reassembled alongside the data")
    `CHECK_EQ(uut.rx_last_word, 1'b1,    "tlast latched onto the assembled beat")
    `CHECK_EQ(uut.rx_error_word,1'b0,    "tuser_error latched low")
    $display("    [INFO] RX latency: %0d cycles (first chunk -> beat presented to parser)",
             rx_done - rx_first);
    `CHECK_EQ(rx_done - rx_first, NCHUNKS, "RX latency equals one cycle per chunk")

    //-----------------------------------------------------------------
    `TB_SECTION("RX error flag propagates")
    //-----------------------------------------------------------------
    drive_beat(pattern, keeppat, 1'b1, 1'b1, -1);
    repeat (2) @(negedge clk);
    `CHECK_EQ(uut.rx_error_word, 1'b1, "tuser_error latched onto the beat")

    //-----------------------------------------------------------------
    `TB_SECTION("RX tolerates idle gaps mid-beat")
    //-----------------------------------------------------------------
    // tvalid drops for several cycles part way through a beat, with X
    // driven on the data pins. The assembled beat must be unaffected.
    drive_beat(pattern, keeppat, 1'b1, 1'b0, 3);
    repeat (2) @(negedge clk);
    `CHECK_EQ(uut.rx_data_word, pattern, "beat still correct after an idle gap mid-stream")
    `CHECK_EQ(uut.rx_keep_word, keeppat, "tkeep still correct after an idle gap")

    //-----------------------------------------------------------------
    `TB_SECTION("RX resynchronises across consecutive beats")
    //-----------------------------------------------------------------
    begin : two_beats
        reg [511:0] p2;
        p2 = ~pattern;
        drive_beat(pattern, keeppat, 1'b0, 1'b0, -1);
        drive_beat(p2,      keeppat, 1'b1, 1'b0, -1);
        repeat (2) @(negedge clk);
        `CHECK_EQ(uut.rx_data_word, p2, "second back-to-back beat assembled correctly")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("TX serialization, MSB first")
    //-----------------------------------------------------------------
    @(negedge clk);
    force uut.order_tx_tdata  = pattern;
    force uut.order_tx_tkeep  = keeppat;
    force uut.order_tx_tlast  = 1'b1;
    force uut.order_tx_tvalid = 1'b1;
    tx_idx = 0; tx_errs = 0; tx_first = -1;
    tx_sb_on = 1;
    tx_tready_chunk = 1'b1;
    tx_start = cyc;

    @(posedge clk);            // serializer loads the beat
    @(negedge clk);
    force uut.order_tx_tvalid = 1'b0;

    // Drain, stalling part way through to prove backpressure works.
    repeat (2) @(posedge clk);
    @(negedge clk);
    tx_tready_chunk = 1'b0;
    begin : tx_stall
        reg [CW-1:0] held;
        @(negedge clk);
        held = tx_tdata_chunk;
        repeat (3) @(negedge clk);
        `CHECK_EQ(tx_tdata_chunk, held, "TX chunk held stable while tready is low")
        `CHECK_EQ(tx_tvalid_chunk, 1'b1, "tvalid stays asserted through the stall")
    end
    @(negedge clk);
    tx_tready_chunk = 1'b1;

    repeat (NCHUNKS + 6) @(posedge clk);
    tx_sb_on = 0;
    release uut.order_tx_tdata;  release uut.order_tx_tkeep;
    release uut.order_tx_tlast;  release uut.order_tx_tvalid;

    `CHECK_EQ(tx_idx,  NCHUNKS, "all chunks transferred")
    `CHECK_EQ(tx_errs, 0,       "every chunk carried the right data and tkeep, in MSB-first order")
    $display("    [INFO] TX latency: %0d cycles to first chunk, %0d to last (incl. one stall)",
             tx_first - tx_start, tx_last_c - tx_start);

    //-----------------------------------------------------------------
    `TB_SECTION("TX idles cleanly after the beat")
    //-----------------------------------------------------------------
    repeat (4) @(negedge clk);
    `CHECK_EQ(tx_tvalid_chunk, 1'b0, "tvalid low once the beat has drained")
    `CHECK_EQ(uut.order_tx_tready, 1'b1, "serializer ready for the next beat")

    `TB_SUMMARY("tb_serdes")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_serdes.vcd");
        $dumpvars(0, tb_serdes);
    end
end

endmodule
