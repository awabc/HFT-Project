`timescale 1ns/1ps
//=====================================================================
// tb_order_tx - unit level tests for order_tx.v
//
// Checks the generated order packet byte by byte against the Ethernet /
// IPv4 / UDP layout it claims to build, including a recomputed IPv4
// header checksum, then exercises the AXI4-Stream handshake.
//
// Covers:
//   * full header field check (MACs, ethertype, IPv4, UDP)
//   * IPv4 header checksum actually validates
//   * payload: magic, order id, price, shares, side
//   * tvalid/tlast/tkeep handshake behaviour and backpressure
//   * order id increments per order, and which value ships in the packet
//   * order counter
//   * overrun flag when a fire arrives while the previous beat is stuck
//=====================================================================
module tb_order_tx;

`include "tb_defs.vh"
`include "itch_frame.vh"

`TB_VARS
`TB_TIMEOUT(20000)

reg         clk = 0;
reg         rst_n = 0;
always #5 clk = ~clk;

reg         i_fire;
reg  [31:0] i_fire_price, i_fire_shares;
reg         i_fire_is_buy;
reg         i_tready;

wire [511:0] o_tdata;
wire [63:0]  o_tkeep;
wire         o_tvalid, o_tlast;
wire [63:0]  o_order_id;
wire [31:0]  o_stat_orders;
wire         o_stat_overrun;

order_tx dut (
    .i_clk(clk), 
	.i_rst_n(rst_n),
    .i_fire(i_fire), 
	.i_fire_price(i_fire_price),
    .i_fire_shares(i_fire_shares), 
	.i_fire_is_buy(i_fire_is_buy),
    .o_tdata(o_tdata), 
	.o_tkeep(o_tkeep), 
	.o_tvalid(o_tvalid), 
	.o_tlast(o_tlast),
    .i_tready(i_tready),
    .o_order_id(o_order_id), 
	.o_stat_orders(o_stat_orders),
    .o_stat_overrun(o_stat_overrun)
);

// Captured packet at the accepting handshake.
reg [511:0] pkt;
reg [63:0]  pkt_keep;
reg         pkt_seen;
integer     pkt_count;
reg         watch_on;

always @(posedge clk) begin
    if (rst_n && watch_on && o_tvalid && i_tready) begin
        pkt       = o_tdata;
        pkt_keep  = o_tkeep;
        pkt_seen  = 1'b1;
        pkt_count = pkt_count + 1;
    end
end

task clr; begin pkt_seen = 0; pkt_count = 0; end endtask

// One-cycle fire pulse
task fire;
    input [31:0] price;
    input [31:0] shares;
    input        is_buy;
    begin
        @(negedge clk);
        i_fire = 1'b1; i_fire_price = price; i_fire_shares = shares; i_fire_is_buy = is_buy;
        @(negedge clk);
        i_fire = 1'b0;
    end
endtask

// Standard IPv4 header checksum over bytes 14..33 of the beat
function automatic [15:0] ip_checksum;
    input [511:0] d;
    reg   [31:0]  acc;
    integer j;
    begin
        acc = 32'd0;
        for (j = 14; j < 34; j = j + 2)
            acc = acc + {16'd0, d[8*j +: 8], d[8*(j+1) +: 8]};
        acc = (acc & 32'hFFFF) + (acc >> 16);
        acc = (acc & 32'hFFFF) + (acc >> 16);
        ip_checksum = ~acc[15:0];
    end
endfunction

task do_reset;
    begin
        rst_n = 0;
        i_fire = 0; i_fire_price = 0; i_fire_shares = 0; i_fire_is_buy = 0;
        i_tready = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
    end
endtask

integer n;

initial begin
    watch_on = 0; clr;
    do_reset;
    watch_on = 1;

    $display("");
    $display("  ###############################################");
    $display("  #  tb_order_tx                                #");
    $display("  ###############################################");

    //-----------------------------------------------------------------
    `TB_SECTION("Reset state")
    //-----------------------------------------------------------------
    `CHECK_EQ(o_tvalid,       1'b0,  "tvalid low out of reset")
    `CHECK_EQ(o_stat_orders,  32'd0, "order counter zeroed")
    `CHECK_EQ(o_order_id,     64'd0, "order id zeroed")
    `CHECK_EQ(o_stat_overrun, 1'b0,  "overrun flag clear")

    //-----------------------------------------------------------------
    `TB_SECTION("A fire produces exactly one beat")
    //-----------------------------------------------------------------
    i_tready = 1'b1;
    clr;
    fire(32'd101_2500, 32'd250, 1'b1);
    repeat (3) @(negedge clk);
    `CHECK_EQ(pkt_count, 1,    "exactly one beat transferred")
    `CHECK_EQ(pkt_keep, {64{1'b1}}, "tkeep marks all 64 bytes valid")
    `CHECK_EQ(o_tvalid, 1'b0,  "tvalid deasserts after the handshake")

    //-----------------------------------------------------------------
    `TB_SECTION("Ethernet header")
    //-----------------------------------------------------------------
    `CHECK_EQ(fr_get(pkt,  0, 6), 64'h00_0A_35_02_9D_E5, "destination MAC")
    `CHECK_EQ(fr_get(pkt,  6, 6), 64'h00_0A_35_02_9D_E4, "source MAC")
    `CHECK_EQ(fr_get(pkt, 12, 2), 64'h0800,              "ethertype is IPv4")

    //-----------------------------------------------------------------
    `TB_SECTION("IPv4 header")
    //-----------------------------------------------------------------
    `CHECK_EQ(fr_get(pkt, 14, 1), 64'h45,       "version 4, IHL 5")
    `CHECK_EQ(fr_get(pkt, 16, 2), 64'd50,       "total length = 20 IP + 8 UDP + 22 payload")
    `CHECK_EQ(fr_get(pkt, 22, 1), 64'd64,       "TTL")
    `CHECK_EQ(fr_get(pkt, 23, 1), 64'd17,       "protocol = UDP")
    `CHECK_EQ(fr_get(pkt, 26, 4), 64'hC0A8010A, "source IP 192.168.1.10")
    `CHECK_EQ(fr_get(pkt, 30, 4), 64'hC0A80114, "destination IP 192.168.1.20")
    // The RTL ships a hardcoded checksum. Recompute it to confirm the
    // constant still matches the header it is protecting.
    `CHECK_EQ(ip_checksum(pkt), 16'd0,
        "IPv4 header checksum validates (sum over header incl. checksum = 0)")

    //-----------------------------------------------------------------
    `TB_SECTION("UDP header")
    //-----------------------------------------------------------------
    `CHECK_EQ(fr_get(pkt, 34, 2), 64'd41000, "source port")
    `CHECK_EQ(fr_get(pkt, 36, 2), 64'd41001, "destination port")
    `CHECK_EQ(fr_get(pkt, 38, 2), 64'd30,    "UDP length = 8 header + 22 payload")
    `CHECK_EQ(fr_get(pkt, 40, 2), 64'd0,     "UDP checksum disabled")

    //-----------------------------------------------------------------
    `TB_SECTION("Order payload")
    //-----------------------------------------------------------------
    `CHECK_EQ(fr_get(pkt, 42, 4), 64'h4157_4142, "magic 'AWAB'")
    `CHECK_EQ(fr_get(pkt, 54, 4), 64'd101_2500,  "price field")
    `CHECK_EQ(fr_get(pkt, 58, 4), 64'd250,       "shares field")
    `CHECK_EQ(fr_get(pkt, 62, 1), 64'h42,        "side byte 'B' for buy")
    // patched[] is built from the pre-increment order_id, so the first
    // packet on the wire carries id 0 while o_order_id reads 1.
    `CHECK_EQ(fr_get(pkt, 46, 8), 64'd0,  "first packet carries order id 0")
    `CHECK_EQ(o_order_id,         64'd1,  "order id register incremented to 1")

    //-----------------------------------------------------------------
    `TB_SECTION("Sell side encoding")
    //-----------------------------------------------------------------
    clr;
    fire(32'd99_0000, 32'd77, 1'b0);
    repeat (3) @(negedge clk);
    `CHECK_EQ(fr_get(pkt, 62, 1), 64'h53,      "side byte 'S' for sell")
    `CHECK_EQ(fr_get(pkt, 54, 4), 64'd99_0000, "sell price field")
    `CHECK_EQ(fr_get(pkt, 58, 4), 64'd77,      "sell shares field")
    `CHECK_EQ(fr_get(pkt, 46, 8), 64'd1,       "second packet carries order id 1")

    //-----------------------------------------------------------------
    `TB_SECTION("Order counter and id sequence")
    //-----------------------------------------------------------------
    begin : seq
        reg [31:0] o0;
        reg [63:0] id0;
        o0 = o_stat_orders; id0 = o_order_id;
        for (n = 0; n < 4; n = n + 1) begin
            fire(32'd100 + n, 32'd10, 1'b1);
            repeat (3) @(negedge clk);
        end
        `CHECK_EQ(o_stat_orders, o0 + 4,  "order counter incremented once per fire")
        `CHECK_EQ(o_order_id,    id0 + 4, "order id incremented once per fire")
    end

    //-----------------------------------------------------------------
    `TB_SECTION("Backpressure: beat is held until tready")
    //-----------------------------------------------------------------
    do_reset;
    watch_on = 1;
    i_tready = 1'b0;
    clr;
    fire(32'd123_4567, 32'd99, 1'b1);
    repeat (5) @(negedge clk);
    `CHECK_EQ(o_tvalid, 1'b1, "tvalid stays asserted while tready is low")
    `CHECK_EQ(o_tlast,  1'b1, "tlast held with the stalled beat")
    `CHECK_EQ(pkt_count, 0,   "no transfer occurred while stalled")

    begin : stable
        reg [511:0] held;
        held = o_tdata;
        repeat (4) @(negedge clk);
        `CHECK_EQ(o_tdata, held, "tdata stays stable across the stall")
    end

    @(negedge clk);
    i_tready = 1'b1;
    @(negedge clk);
    @(negedge clk);
    i_tready = 1'b0;
    `CHECK_EQ(pkt_count, 1,   "beat transfers once tready is asserted")
    `CHECK_EQ(o_tvalid,  1'b0,"tvalid drops after the delayed handshake")
    `CHECK_EQ(fr_get(pkt, 54, 4), 64'd123_4567, "stalled beat carried the right price")

    //-----------------------------------------------------------------
    `TB_SECTION("Overrun when a fire arrives during a stall")
    //-----------------------------------------------------------------
    do_reset;
    watch_on = 1;
    i_tready = 1'b0;
    clr;
    fire(32'd500, 32'd10, 1'b1);       // first order, will stall
    repeat (2) @(negedge clk);
    `CHECK_EQ(o_stat_overrun, 1'b0, "no overrun yet")

    fire(32'd600, 32'd20, 1'b0);       // second fire while the first is stuck
    repeat (2) @(negedge clk);
    `CHECK_EQ(o_stat_overrun, 1'b1, "overrun flagged when a fire is dropped")
    `CHECK_EQ(o_stat_orders,  32'd1, "the dropped order was not counted")

    // Drain and confirm the surviving beat is the first order.
    @(negedge clk);
    i_tready = 1'b1;
    repeat (2) @(negedge clk);
    i_tready = 1'b0;
    `CHECK_EQ(fr_get(pkt, 54, 4), 64'd500, "the first order survived, the second was lost")

    //-----------------------------------------------------------------
    `TB_SECTION("Overrun flag is sticky")
    //-----------------------------------------------------------------
    repeat (4) @(negedge clk);
    `CHECK_EQ(o_stat_overrun, 1'b1, "overrun stays latched after the queue drains")

    `TB_SUMMARY("tb_order_tx")
    $finish;
end

initial begin
    if ($test$plusargs("dump")) begin
        $dumpfile("tb_order_tx.vcd");
        $dumpvars(0, tb_order_tx);
    end
end

endmodule
