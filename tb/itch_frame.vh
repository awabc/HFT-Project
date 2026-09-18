//=====================================================================
// itch_frame.vh - builds the two 512-bit beats of a MoldUDP64/ITCH
// market data frame, byte-for-byte as parser.v expects to see them.
//
// Byte ordering: byte N of the frame lives at bits [8*N +: 8] of the
// beat, matching parser.v's be_field().
//
// Wire layout
//   beat 0 (bytes 0..63)
//     0..5    dst MAC
//     6..11   src MAC
//     12..13  ethertype (0x0800)
//     14..33  IPv4 header   (14 = version/IHL, 23 = protocol)
//     34..41  UDP header    (36..37 = dst port)
//     42..51  MoldUDP64 session
//     52..59  MoldUDP64 sequence number
//     60..61  MoldUDP64 message count
//     62..63  message 0 length
//   beat 1 (bytes 64..127) = ITCH message, so message offset == beat offset
//
//=====================================================================
`ifndef ITCH_FRAME_VH
`define ITCH_FRAME_VH

localparam ITCH_ADD_ORDER = 8'h41; // 'A'
localparam ITCH_EXECUTED  = 8'h45; // 'E'
localparam ITCH_CANCEL    = 8'h58; // 'X'
localparam ITCH_DELETE    = 8'h44; // 'D'
localparam ITCH_SIDE_BUY  = 8'h42; // 'B'
localparam ITCH_SIDE_SELL = 8'h53; // 'S'

// Place an n-byte big-endian field at byte offset `off`.
function automatic [511:0] fr_put;
    input [511:0] d;
    input integer off;
    input integer n;
    input [63:0]  v;
    reg   [511:0] r;
    integer j;
    begin
        r = d;
        for (j = 0; j < n; j = j + 1)
            r[8*(off+j) +: 8] = v[8*(n-1-j) +: 8];
        fr_put = r;
    end
endfunction

// Read an n-byte big-endian field back out (for checking TX packets).
function automatic [63:0] fr_get;
    input [511:0] d;
    input integer off;
    input integer n;
    reg   [63:0]  r;
    integer j;
    begin
        r = 64'd0;
        for (j = 0; j < n; j = j + 1)
            r = (r << 8) | {56'd0, d[8*(off+j) +: 8]};
        fr_get = r;
    end
endfunction

//---------------------------------------------------------------------
// beat 0 : Ethernet + IPv4 + UDP + MoldUDP64 headers
//---------------------------------------------------------------------
function automatic [511:0] fr_beat0;
    input [15:0] udp_dport;
    input [63:0] mold_seq;
    input [15:0] mold_count;
    input [15:0] msg0_len;
    reg   [511:0] b;
    begin
        b = 512'd0;

        // Ethernet
        b = fr_put(b,  0, 6, 64'h00_0A_35_02_9D_E5);  // dst MAC
        b = fr_put(b,  6, 6, 64'h00_0A_35_02_9D_E4);  // src MAC
        b = fr_put(b, 12, 2, 64'h0800);               // ethertype, correct offset
`ifdef ETHERTYPE_COMPAT
        b = fr_put(b,  2, 2, 64'h0800);               // workaround, see header
`endif

        // IPv4
        b = fr_put(b, 14, 1, 64'h45);                 // version 4 / IHL 5
        b = fr_put(b, 15, 1, 64'h00);                 // DSCP/ECN
        b = fr_put(b, 16, 2, 64'd78);                 // total length
        b = fr_put(b, 18, 2, 64'h0000);               // identification
        b = fr_put(b, 20, 2, 64'h4000);               // flags: DF
        b = fr_put(b, 22, 1, 64'd64);                 // TTL
        b = fr_put(b, 23, 1, 64'd17);                 // protocol = UDP
        b = fr_put(b, 24, 2, 64'h0000);               // header checksum (not checked by parser)
        b = fr_put(b, 26, 4, 64'hC0A8_010A);          // src IP 192.168.1.10
        b = fr_put(b, 30, 4, 64'hC0A8_0114);          // dst IP 192.168.1.20

        // UDP
        b = fr_put(b, 34, 2, 64'd41000);              // src port
        b = fr_put(b, 36, 2, {48'd0, udp_dport});     // dst port
        b = fr_put(b, 38, 2, 64'd58);                 // length
        b = fr_put(b, 40, 2, 64'h0000);               // checksum disabled

        // MoldUDP64 downstream header
        b = fr_put(b, 42, 8, 64'h5345_5353_494F_4E31); // session "SESSION1"
        b = fr_put(b, 50, 2, 64'h3130);                // session, remaining 2 bytes
        b = fr_put(b, 52, 8, mold_seq);                // sequence number
        b = fr_put(b, 60, 2, {48'd0, mold_count});     // message count
        b = fr_put(b, 62, 2, {48'd0, msg0_len});       // message 0 length

        fr_beat0 = b;
    end
endfunction

//---------------------------------------------------------------------
// beat 1 : ITCH messages. Common prefix for all four types:
//   0      message type
//   1..2   stock locate
//   3..4   tracking number
//   5..10  timestamp (48 bit)
//   11..18 order reference number
//---------------------------------------------------------------------
function automatic [511:0] fr_msg_common;
    input [7:0]  mtype;
    input [15:0] locate;
    input [63:0] order_ref;
    reg   [511:0] b;
    begin
        b = 512'd0;
        b = fr_put(b,  0, 1, {56'd0, mtype});
        b = fr_put(b,  1, 2, {48'd0, locate});
        b = fr_put(b,  3, 2, 64'h0001);          // tracking number
        b = fr_put(b,  5, 6, 64'h0000_1234_5678); // timestamp
        b = fr_put(b, 11, 8, order_ref);
        fr_msg_common = b;
    end
endfunction

// Add Order: side at 19, shares at 20..23, stock at 24..31, price at 32..35
function automatic [511:0] fr_add_order;
    input [15:0] locate;
    input [63:0] order_ref;
    input        is_buy;
    input [31:0] shares;
    input [31:0] price;
    reg   [511:0] b;
    begin
        b = fr_msg_common(ITCH_ADD_ORDER, locate, order_ref);
        b = fr_put(b, 19, 1, {56'd0, is_buy ? ITCH_SIDE_BUY : ITCH_SIDE_SELL});
        b = fr_put(b, 20, 4, {32'd0, shares});
        b = fr_put(b, 24, 8, 64'h4D53_4654_2020_2020);  // stock symbol "MSFT    "
        b = fr_put(b, 32, 4, {32'd0, price});
        fr_add_order = b;
    end
endfunction

// Order Executed: executed shares at 19..22
function automatic [511:0] fr_executed;
    input [15:0] locate;
    input [63:0] order_ref;
    input [31:0] shares;
    reg   [511:0] b;
    begin
        b = fr_msg_common(ITCH_EXECUTED, locate, order_ref);
        b = fr_put(b, 19, 4, {32'd0, shares});
        fr_executed = b;
    end
endfunction

// Order Cancel: cancelled shares at 19..22
function automatic [511:0] fr_cancel;
    input [15:0] locate;
    input [63:0] order_ref;
    input [31:0] shares;
    reg   [511:0] b;
    begin
        b = fr_msg_common(ITCH_CANCEL, locate, order_ref);
        b = fr_put(b, 19, 4, {32'd0, shares});
        fr_cancel = b;
    end
endfunction

// Order Delete: no shares field, the whole order is removed
function automatic [511:0] fr_delete;
    input [15:0] locate;
    input [63:0] order_ref;
    begin
        fr_delete = fr_msg_common(ITCH_DELETE, locate, order_ref);
    end
endfunction

`endif
