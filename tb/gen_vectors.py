#!/usr/bin/env python3
"""
gen_vectors.py - constrained-random stimulus generator for the HFT
pipeline regression.

Emits three files consumed by tb_regression.v via $readmemh:

  stim_beats.hex     one 128-hex-digit line per beat (512 bits), two
                     lines per frame
  stim_ctrl.hex      one line per frame: {keep_full, error, is_last_of_stream}
  expected.hex       one line per frame with the golden BBO after that
                     frame, plus any order the strategy should emit

and expected_summary.txt for debugging.

The stimulus mixes well-formed frames with deliberately malformed ones
(bad ethertype, wrong port, non-UDP, short beat, unknown message type)
so the header filter and the drop counters are exercised, not just the
happy path.

Usage:
    python3 gen_vectors.py --out ../vectors --frames 200 --seed 1
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import itch_model as M


def hex512(buf):
    return "%0128x" % M.beat_to_int(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="vectors", help="output directory")
    ap.add_argument("--frames", type=int, default=200, help="number of frames")
    ap.add_argument("--seed", type=int, default=1, help="random seed")
    ap.add_argument("--udp-port", type=int, default=26400)
    ap.add_argument("--locate", type=int, default=7)
    ap.add_argument("--buy-below", type=int, default=9500)
    ap.add_argument("--sell-above", type=int, default=11000)
    ap.add_argument("--quantity", type=int, default=250)
    ap.add_argument("--bad-rate", type=float, default=0.15,
                    help="fraction of frames that are deliberately malformed")
    ap.add_argument("--ethertype-compat", action="store_true",
                    help="mirror the ethertype into byte 2 to work around "
                         "the parser offset bug")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    pipe = M.Pipeline(args.udp_port, args.locate, True,
                      args.buy_below, args.sell_above, args.quantity)
    pipe.arm()

    beats, ctrls, exps, notes = [], [], [], []
    live_refs = []

    for n in range(args.frames):
        # Re-arm before every frame if the strategy is disarmed. This is
        # unconditional so the Verilog testbench can mirror it exactly by
        # pulsing i_arm before each frame - any randomness here would
        # desynchronise the model from the DUT.
        if not pipe.strategy.armed:
            pipe.arm()

        make_bad = rng.random() < args.bad_rate
        keep_full = True
        error = False
        kind = "good"

        b0_kwargs = dict(udp_port=args.udp_port,
                         ethertype_compat=args.ethertype_compat)

        if make_bad:
            which = rng.randrange(6)
            if which == 0:
                b0_kwargs["udp_port"] = rng.randrange(1, 60000)
                kind = "bad-port"
            elif which == 1:
                b0_kwargs["ethertype"] = 0x86DD
                kind = "bad-ethertype"
            elif which == 2:
                b0_kwargs["ip_proto"] = 6
                kind = "bad-proto"
            elif which == 3:
                b0_kwargs["ip_vihl"] = 0x46
                kind = "bad-ipver"
            elif which == 4:
                keep_full = False
                kind = "short-beat"
            else:
                error = True
                kind = "fcs-error"

        b0 = M.build_beat0(mold_seq=1000 + n, **b0_kwargs)

        # Choose a message. Reductions only make sense against something
        # already resting, so bias towards adds early on.
        choices = ["add"]
        if live_refs:
            choices += ["exec", "cancel", "delete", "add", "add"]
        if rng.random() < 0.05:
            choices = ["unknown"]
        what = rng.choice(choices)

        locate = args.locate if rng.random() < 0.85 else rng.randrange(1, 50)

        if what == "add":
            ref = rng.randrange(1, 4096)
            is_buy = rng.random() < 0.5
            shares = rng.randrange(1, 5000)
            price = rng.randrange(8000, 13000)
            b1 = M.build_add_order(locate, ref, is_buy, shares, price)
            if locate == args.locate:
                live_refs.append(ref)
                if len(live_refs) > 40:
                    live_refs.pop(0)
            note = "add ref=%d %s %d@%d" % (ref, "B" if is_buy else "S", shares, price)
        elif what == "exec":
            ref = rng.choice(live_refs)
            shares = rng.randrange(1, 3000)
            b1 = M.build_executed(locate, ref, shares)
            note = "exec ref=%d %d" % (ref, shares)
        elif what == "cancel":
            ref = rng.choice(live_refs)
            shares = rng.randrange(1, 3000)
            b1 = M.build_cancel(locate, ref, shares)
            note = "cancel ref=%d %d" % (ref, shares)
        elif what == "delete":
            ref = rng.choice(live_refs)
            b1 = M.build_delete(locate, ref)
            note = "delete ref=%d" % ref
        else:
            b1 = M._msg_common(0x5A, locate, rng.randrange(1, 4096))
            note = "unknown-type"

        orders_before = len(pipe.orders)
        pipe.feed_frame(b0, b1, keep_full=keep_full, error=error)
        fired = len(pipe.orders) > orders_before

        bk = pipe.book
        if fired:
            _, is_buy, price, shares = pipe.orders[-1]
        else:
            is_buy, price, shares = 0, 0, 0

        beats.append(hex512(b0))
        beats.append(hex512(b1))
        ctrls.append("%x" % ((1 if keep_full else 0) |
                             ((1 if error else 0) << 1)))

        # expected line, MSB..LSB:
        #   [1:0]     reserved
        #   [2]       bbo bid valid
        #   [3]       bbo ask valid
        #   [4]       order fired
        #   [5]       order is_buy
        #   [37:6]    best bid
        #   [69:38]   best ask
        #   [93:70]   best bid qty
        #   [117:94]  best ask qty
        #   [149:118] order price
        #   [181:150] order shares
        val = 0
        val |= (1 if bk.best_bid_valid else 0) << 2
        val |= (1 if bk.best_ask_valid else 0) << 3
        val |= (1 if fired else 0) << 4
        val |= (1 if is_buy else 0) << 5
        val |= (bk.best_bid & 0xFFFFFFFF) << 6
        val |= (bk.best_ask & 0xFFFFFFFF) << 38
        val |= (bk.best_bid_qty & 0xFFFFFF) << 70
        val |= (bk.best_ask_qty & 0xFFFFFF) << 94
        val |= (price & 0xFFFFFFFF) << 118
        val |= (shares & 0xFFFFFFFF) << 150
        exps.append("%046x" % val)

        notes.append(
            "frame %4d  %-14s %-28s | bid %s%-6d x%-6d  ask %s%-6d x%-6d | %s"
            % (n, kind, note,
               "*" if bk.best_bid_valid else " ", bk.best_bid, bk.best_bid_qty,
               "*" if bk.best_ask_valid else " ", bk.best_ask, bk.best_ask_qty,
               ("ORDER %s %d@%d" % ("BUY" if is_buy else "SELL", shares, price))
               if fired else ""))

    def write(name, lines):
        with open(os.path.join(args.out, name), "w") as f:
            f.write("\n".join(lines) + "\n")

    write("stim_beats.hex", beats)
    write("stim_ctrl.hex", ctrls)
    write("expected.hex", exps)
    write("expected_summary.txt", notes)

    with open(os.path.join(args.out, "config.vh"), "w") as f:
        f.write("// generated by gen_vectors.py - do not edit\n")
        f.write("`define REG_NUM_FRAMES  %d\n" % args.frames)
        f.write("`define REG_UDP_PORT    16'd%d\n" % args.udp_port)
        f.write("`define REG_LOCATE      16'd%d\n" % args.locate)
        f.write("`define REG_BUY_BELOW   32'd%d\n" % args.buy_below)
        f.write("`define REG_SELL_ABOVE  32'd%d\n" % args.sell_above)
        f.write("`define REG_QUANTITY    32'd%d\n" % args.quantity)

    print("generated %d frames into %s/" % (args.frames, args.out))
    print("  parser : %d frames, %d accepted, %d dropped, %d bad fcs"
          % (pipe.parser.frames, pipe.parser.accepted,
             pipe.parser.dropped, pipe.parser.bad_fcs))
    print("  book   : final bid %d x%d (valid=%s), ask %d x%d (valid=%s)"
          % (pipe.book.best_bid, pipe.book.best_bid_qty, pipe.book.best_bid_valid,
             pipe.book.best_ask, pipe.book.best_ask_qty, pipe.book.best_ask_valid))
    print("  strategy: %d fires, %d orders emitted"
          % (pipe.strategy.fires, len(pipe.orders)))


if __name__ == "__main__":
    main()
