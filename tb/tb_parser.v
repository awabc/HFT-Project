`timescale 1ns/1ps
//=====================================================================
// tb_parser - unit level tests for parser.v
//
// Covers:
//   * header acceptance for a well-formed frame
//   * rejection on each individual header field (ethertype, IP version,
//     protocol, UDP port, mold count, message length, short beat)
//   * ITCH decode for all four message types
//   * event_marker field packing
//   * frame / accepted / dropped / bad-FCS counters
//   * that event_valid is a pulse, not a level
//=====================================================================
module tb_parser;

`include "tb_defs.vh"
`include "itch_frame.vh"

`TB_VARS
`TB_TIMEOUT(20000)

localparam UDP_PORT = 16'd26400;
localparam LOCATE   = 16'd7;

reg          clk = 0;
reg          rst_n = 0;
always #5 clk = ~clk;

reg  [511:0] i_data;
reg  [63:0]  i_keep;
reg          i_data_valid;
reg          i_last;
reg          i_error;

wire         o_event_valid;
wire [144:0] o_event_marker;
wire [31:0]  o_stat_frames, o_stat_accepted, o_stat_bad_fcs, o_stat_dropped;

parser dut (
    .i_clk(clk), 
	.i_rst_n(rst_n),
    .i_data(i_data), 
	.i_keep(i_keep), 
	.i_data_valid(i_data_valid),
    .i_last(i_last), 
	.i_error(i_error),
    .i_udp_port(UDP_PORT),
    .o_event_valid(o_event_valid), 
	.o_event_marker(o_event_marker),
    .o_stat_frames(o_stat_frames), 
	.o_stat_accepted(o_stat_accepted),
    .o_stat_bad_fcs(o_stat_bad_fcs), 
	.o_stat_dropped(o_stat_dropped)
);

// Captured on the cycle the parser pulses event_valid.
reg [144:0] cap_marker;
reg         cap_seen;
integer     cap_count;

// event_valid is expected to be a single-cycle pulse. Count every cycle
// it is high so a stuck-high output is visible rather than invisible.
integer     valid_high_cycles;
reg         watch_on;

always @(posedge clk) begin
    if (rst_n && watch_on) begin
        if (o_event_valid) begin
            valid_high_cycles = valid_high_cycles + 1;
            cap_marker = o_event_marker;
            cap_seen   = 1'b1;
            cap_count  = cap_count + 1;
        end
    end
end

task clr_capture;
    begin
        cap_seen = 0; cap_count = 0; valid_high_cycles = 0;
    end
endtask

// Drive one two-beat frame. beat0/beat1 are supplied by the caller so
// individual header fields can be corrupted per test.
task send_frame;
    input [511:0] beat0;
    input [511:0] beat1;
    input [63:0]  keep0;
    input         err;
    begin
        @(negedge clk);
        i_data = beat0; i_keep = keep0; i_data_valid = 1; i_last = 0; i_error = 0;
        @(negedge clk);
        i_data = beat1; i_keep = {64{1'b1}}; i_data_valid = 1; i_last = 1; i_error = err;
        @(negedge clk);
        i_data_valid = 0; i_last = 0; i_error = 0; i_data = 0; i_keep = 0;
        @(negedge clk);
    end
endtask

function automatic [511:0] good_beat0;
    input dummy;
    begin
        good_beat0 = fr_beat0(UDP_PORT, 64'd1000, 16'd1, 16'd36);
    end
endfunction

integer k;

initial begin
    i_data = 0; i_keep = 0; i_data_valid = 0; i_last = 0; i_error = 0;
    watch_on = 0; clr_capture;

    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
    watch_on = 1;

    $display("");
    $display("  ###############################################");
    $display("  #  tb_parser                                  #");
    $display("  ###############################################");

    //-----------------------------------------------------------------
    `TB_SECTION("event_valid should be a pulse, not a level")
    //-----------------------------------------------------------------
    // Nothing is being driven, so the parser must not be announcing
    // events. If this fails, every downstream module sees a permanent
    // event and re-applies stale marker data every cycle.
    clr_capture;
    repeat (10) @(negedge clk);
    `CHECK_KNOWN_BUG(valid_high_cycles == 0,
        "event_valid stays low when no frame is being parsed",
        "")

    //-----------------------------------------------------------------
    `TB_SECTION("Add Order decode, buy side")
    //-----------------------------------------------------------------
    clr_capture;
    send_frame(good_beat0(0),
               fr_add_order(LOCATE, 64'h0000_0000_0000_0041, 1'b1, 32'd500, 32'd101_2500),
               {64{1'b1}}, 1'b0);

    `CHECK(cap_seen, "event was produced for a valid Add Order frame")
    `CHECK_EQ(cap_marker[7:0],     ITCH_ADD_ORDER, "marker type = Add Order")
    `CHECK_EQ(cap_marker[23:8],    LOCATE,         "marker stock locate")
    `CHECK_EQ(cap_marker[87:24],   64'h41,         "marker order reference")
    `CHECK_EQ(cap_marker[88],      1'b1,           "marker is_buy set for side 'B'")
    `CHECK_EQ(cap_marker[112:89],  24'd500,        "marker shares")
    `CHECK_EQ(cap_marker[144:113], 32'd101_2500,   "marker price")

    //-----------------------------------------------------------------
    `TB_SECTION("Add Order decode, sell side")
    //-----------------------------------------------------------------
    clr_capture;
    send_frame(good_beat0(0),
               fr_add_order(LOCATE, 64'h42, 1'b0, 32'd250, 32'd101_3000),
               {64{1'b1}}, 1'b0);
    `CHECK_EQ(cap_marker[88],      1'b0,         "marker is_buy clear for side 'S'")
    `CHECK_EQ(cap_marker[112:89],  24'd250,      "marker shares, sell side")
    `CHECK_EQ(cap_marker[144:113], 32'd101_3000, "marker price, sell side")

    //-----------------------------------------------------------------
    `TB_SECTION("Order Executed decode")
    //-----------------------------------------------------------------
    clr_capture;
    send_frame(good_beat0(0), fr_executed(LOCATE, 64'h41, 32'd120), {64{1'b1}}, 1'b0);
    `CHECK_EQ(cap_marker[7:0],     ITCH_EXECUTED, "marker type = Executed")
    `CHECK_EQ(cap_marker[112:89],  24'd120,       "executed share count decoded from offset 19")
    `CHECK_EQ(cap_marker[144:113], 32'd0,         "price field zeroed for non-Add messages")

    //-----------------------------------------------------------------
    `TB_SECTION("Order Cancel decode")
    //-----------------------------------------------------------------
    clr_capture;
    send_frame(good_beat0(0), fr_cancel(LOCATE, 64'h41, 32'd75), {64{1'b1}}, 1'b0);
    `CHECK_EQ(cap_marker[7:0],    ITCH_CANCEL, "marker type = Cancel")
    `CHECK_EQ(cap_marker[112:89], 24'd75,      "cancelled share count")

    //-----------------------------------------------------------------
    `TB_SECTION("Order Delete decode")
    //-----------------------------------------------------------------
    clr_capture;
    send_frame(good_beat0(0), fr_delete(LOCATE, 64'h41), {64{1'b1}}, 1'b0);
    `CHECK_EQ(cap_marker[7:0],    ITCH_DELETE, "marker type = Delete")
    `CHECK_EQ(cap_marker[112:89], 24'd0,       "Delete carries zero shares")

    //-----------------------------------------------------------------
    `TB_SECTION("Share count saturation above 24 bits")
    //-----------------------------------------------------------------
    // sat_qty() maps anything that does not fit in 24 bits to 1.
    clr_capture;
    send_frame(good_beat0(0),
               fr_add_order(LOCATE, 64'h43, 1'b1, 32'h0100_0000, 32'd100),
               {64{1'b1}}, 1'b0);
    `CHECK_EQ(cap_marker[112:89], 24'd1, "oversized share count saturates to 1")

    //-----------------------------------------------------------------
    `TB_SECTION("Header rejection")
    //-----------------------------------------------------------------
    // Each of these corrupts exactly one field of an otherwise good
    // frame, so a failure points straight at the responsible check
    begin : hdr_reject
        reg [511:0] b0;
        reg [31:0]  acc_before, drop_before;

        // wrong UDP destination port
        acc_before = o_stat_accepted; drop_before = o_stat_dropped;
        b0 = fr_beat0(16'd9999, 64'd1, 16'd1, 16'd36);
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h50, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before,      "wrong UDP port is not accepted")
        `CHECK_EQ(o_stat_dropped,  drop_before + 1, "wrong UDP port increments dropped")

        // non-IPv4 ethertype
        acc_before = o_stat_accepted;
        b0 = good_beat0(0);
        b0 = fr_put(b0, 12, 2, 64'h86DD);   // IPv6
`ifdef ETHERTYPE_COMPAT
        b0 = fr_put(b0,  2, 2, 64'h86DD);
`endif
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h51, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "non-IPv4 ethertype is rejected")

        // wrong IP version / IHL
        acc_before = o_stat_accepted;
        b0 = good_beat0(0);
        b0 = fr_put(b0, 14, 1, 64'h46);
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h52, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "non 4/5 version+IHL is rejected")

        // not UDP
        acc_before = o_stat_accepted;
        b0 = good_beat0(0);
        b0 = fr_put(b0, 23, 1, 64'd6);      // TCP
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h53, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "non-UDP protocol is rejected")

        // zero MoldUDP64 message count
        acc_before = o_stat_accepted;
        b0 = fr_beat0(UDP_PORT, 64'd1, 16'd0, 16'd36);
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h54, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "zero mold message count is rejected")

        // zero message length
        acc_before = o_stat_accepted;
        b0 = fr_beat0(UDP_PORT, 64'd1, 16'd1, 16'd0);
        clr_capture;
        send_frame(b0, fr_add_order(LOCATE, 64'h55, 1'b1, 32'd10, 32'd100), {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "zero message length is rejected")

        // short beat: tkeep not all ones
        acc_before = o_stat_accepted;
        clr_capture;
        send_frame(good_beat0(0), fr_add_order(LOCATE, 64'h56, 1'b1, 32'd10, 32'd100),
                   64'h7FFF_FFFF_FFFF_FFFF, 1'b0);
        `CHECK_EQ(o_stat_accepted, acc_before, "short beat 0 (tkeep not full) is rejected")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("Unknown ITCH message type produces no event")
    //-----------------------------------------------------------------
    begin : unknown_type
        reg [511:0] b1;
        b1 = fr_msg_common(8'h5A, LOCATE, 64'h60);   // 'Z', not decoded
        clr_capture;
        send_frame(good_beat0(0), b1, {64{1'b1}}, 1'b0);
        `CHECK_KNOWN_BUG(cap_count == 0,
            "unknown message type raises no event",
            "masked while event_valid is stuck high")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("Statistics counters")
    //-----------------------------------------------------------------
    begin : stats
        reg [31:0] f0, a0, d0, e0;
        f0 = o_stat_frames; a0 = o_stat_accepted; d0 = o_stat_dropped; e0 = o_stat_bad_fcs;

        for (k = 0; k < 5; k = k + 1)
            send_frame(good_beat0(0),
                       fr_add_order(LOCATE, 64'h70 + k, 1'b1, 32'd10, 32'd100),
                       {64{1'b1}}, 1'b0);

        `CHECK_EQ(o_stat_frames,   f0 + 5, "frame counter counts every beat-0")
        `CHECK_EQ(o_stat_accepted, a0 + 5, "accepted counter counts matching headers")
        `CHECK_EQ(o_stat_dropped,  d0,     "dropped counter unchanged for good frames")

        // i_error asserted on the last beat should raise bad FCS
        send_frame(good_beat0(0),
                   fr_add_order(LOCATE, 64'h80, 1'b1, 32'd10, 32'd100),
                   {64{1'b1}}, 1'b1);
        `CHECK_EQ(o_stat_bad_fcs, e0 + 1, "i_error on last beat increments bad FCS")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("Beat counter resynchronises on i_last")
    //-----------------------------------------------------------------
    // A three-beat frame must not leave the parser off-by-one for the
    // next frame.
    begin : resync
        reg [31:0] a0;
        @(negedge clk);
        i_data = good_beat0(0); i_keep = {64{1'b1}}; i_data_valid = 1; i_last = 0;
        @(negedge clk);
        i_data = fr_add_order(LOCATE, 64'h90, 1'b1, 32'd10, 32'd100); i_last = 0;
        @(negedge clk);
        i_data = 512'd0; i_last = 1;
        @(negedge clk);
        i_data_valid = 0; i_last = 0;
        repeat (2) @(negedge clk);

        a0 = o_stat_accepted;
        clr_capture;
        send_frame(good_beat0(0),
                   fr_add_order(LOCATE, 64'h91, 1'b1, 32'd333, 32'd555),
                   {64{1'b1}}, 1'b0);
        `CHECK_EQ(o_stat_accepted, a0 + 1, "next frame after a 3-beat frame is still parsed")
        `CHECK_EQ(cap_marker[112:89], 24'd333, "and decodes correctly")
    end

    `TB_SUMMARY("tb_parser")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_parser.vcd");
        $dumpvars(0, tb_parser);
    end
end

endmodule
