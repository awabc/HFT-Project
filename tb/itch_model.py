"""
itch_model.py - frame builder and behavioural golden model for the HFT
pipeline.

Two jobs:

  1. Build MoldUDP64/ITCH frames byte-for-byte the way parser.v expects
     them, so the Verilog testbench and the model agree on the wire.

  2. Model parser -> book -> strategy -> order_tx at the transaction
     level (no clock cycles, just cause and effect), producing the
     expected BBO and the expected sequence of outbound orders.
"""

# ---------------------------------------------------------------------
# Wire layout constants (must match parser.v / itch_frame.vh)
# ---------------------------------------------------------------------
ETHERTYPE_IPV4 = 0x0800
IP_V4_IHL5     = 0x45
IP_PROTO_UDP   = 17

OFF_ETHERTYPE  = 12    
OFF_IP_VIHL    = 14
OFF_IP_PROTO   = 23
OFF_UDP_DPORT  = 36
OFF_MOLD_SEQ   = 52
OFF_MOLD_COUNT = 60
OFF_MSG0_LEN   = 62

ITCH_ADD_ORDER = 0x41    # 'A'
ITCH_EXECUTED  = 0x45    # 'E'
ITCH_CANCEL    = 0x58    # 'X'
ITCH_DELETE    = 0x44    # 'D'
SIDE_BUY       = 0x42    # 'B'
SIDE_SELL      = 0x53    # 'S'

BEAT_BYTES     = 64
ORDER_INDEX_W  = 6
BOOK_DEPTH     = 1 << ORDER_INDEX_W


# ---------------------------------------------------------------------
# Frame construction
# ---------------------------------------------------------------------
def _put(buf, off, n, value):
    """Place an n-byte big-endian field at byte offset off."""
    for j in range(n):
        buf[off + j] = (value >> (8 * (n - 1 - j))) & 0xFF


def beat_to_int(buf):
    """Pack a 64-byte beat into the 512-bit integer the RTL sees.

    Byte N lives at bits [8N +: 8], matching parser.v's be_field().
    """
    v = 0
    for i, b in enumerate(buf):
        v |= (b & 0xFF) << (8 * i)
    return v


def build_beat0(udp_port, mold_seq=5000, mold_count=1, msg_len=36,
                ethertype=ETHERTYPE_IPV4, ip_vihl=IP_V4_IHL5,
                ip_proto=IP_PROTO_UDP, ethertype_compat=False):
    """Ethernet + IPv4 + UDP + MoldUDP64 header beat.
    """
    b = bytearray(BEAT_BYTES)

    _put(b, 0, 6, 0x000A35029DE5)          # dst MAC
    _put(b, 6, 6, 0x000A35029DE4)          # src MAC
    _put(b, OFF_ETHERTYPE, 2, ethertype)
    if ethertype_compat:
        _put(b, 2, 2, ethertype)

    _put(b, OFF_IP_VIHL, 1, ip_vihl)
    _put(b, 15, 1, 0x00)
    _put(b, 16, 2, 78)                     # total length
    _put(b, 18, 2, 0x0000)
    _put(b, 20, 2, 0x4000)                 # DF
    _put(b, 22, 1, 64)                     # TTL
    _put(b, OFF_IP_PROTO, 1, ip_proto)
    _put(b, 24, 2, 0x0000)
    _put(b, 26, 4, 0xC0A8010A)             # 192.168.1.10
    _put(b, 30, 4, 0xC0A80114)             # 192.168.1.20

    _put(b, 34, 2, 41000)                  # UDP src port
    _put(b, OFF_UDP_DPORT, 2, udp_port)
    _put(b, 38, 2, 58)
    _put(b, 40, 2, 0x0000)

    _put(b, 42, 8, 0x53455353494F4E31)     # "SESSION1"
    _put(b, 50, 2, 0x3130)
    _put(b, OFF_MOLD_SEQ, 8, mold_seq)
    _put(b, OFF_MOLD_COUNT, 2, mold_count)
    _put(b, OFF_MSG0_LEN, 2, msg_len)
    return b


def _msg_common(mtype, locate, order_ref):
    b = bytearray(BEAT_BYTES)
    _put(b, 0, 1, mtype)
    _put(b, 1, 2, locate)
    _put(b, 3, 2, 0x0001)                  # tracking number
    _put(b, 5, 6, 0x000012345678)          # timestamp
    _put(b, 11, 8, order_ref)
    return b


def build_add_order(locate, order_ref, is_buy, shares, price):
    b = _msg_common(ITCH_ADD_ORDER, locate, order_ref)
    _put(b, 19, 1, SIDE_BUY if is_buy else SIDE_SELL)
    _put(b, 20, 4, shares)
    _put(b, 24, 8, 0x4D53465420202020)     # "MSFT    "
    _put(b, 32, 4, price)
    return b


def build_executed(locate, order_ref, shares):
    b = _msg_common(ITCH_EXECUTED, locate, order_ref)
    _put(b, 19, 4, shares)
    return b


def build_cancel(locate, order_ref, shares):
    b = _msg_common(ITCH_CANCEL, locate, order_ref)
    _put(b, 19, 4, shares)
    return b


def build_delete(locate, order_ref):
    return _msg_common(ITCH_DELETE, locate, order_ref)


# ---------------------------------------------------------------------
# Golden model
# ---------------------------------------------------------------------
def sat_qty(v):
    """parser.v clamps anything wider than 24 bits to 1."""
    return 1 if (v >> 24) else (v & 0xFFFFFF)


class Event:
    """The 145-bit event marker parser.v emits."""

    __slots__ = ("mtype", "locate", "order_ref", "is_buy", "shares", "price")

    def __init__(self, mtype, locate, order_ref, is_buy, shares, price):
        self.mtype = mtype
        self.locate = locate
        self.order_ref = order_ref
        self.is_buy = is_buy
        self.shares = shares
        self.price = price

    def packed(self):
        m = 0
        m |= (self.mtype & 0xFF)
        m |= (self.locate & 0xFFFF) << 8
        m |= (self.order_ref & 0xFFFFFFFFFFFFFFFF) << 24
        m |= (1 if self.is_buy else 0) << 88
        m |= (self.shares & 0xFFFFFF) << 89
        m |= (self.price & 0xFFFFFFFF) << 113
        return m


class Parser:
    """Header filtering and ITCH decode."""

    def __init__(self, udp_port):
        self.udp_port = udp_port
        self.frames = 0
        self.accepted = 0
        self.dropped = 0
        self.bad_fcs = 0

    def header_ok(self, b0, keep_full=True):
        def be(off, n):
            v = 0
            for j in range(n):
                v = (v << 8) | b0[off + j]
            return v

        return (keep_full
                and be(OFF_ETHERTYPE, 2) == ETHERTYPE_IPV4
                and b0[OFF_IP_VIHL] == IP_V4_IHL5
                and b0[OFF_IP_PROTO] == IP_PROTO_UDP
                and be(OFF_UDP_DPORT, 2) == self.udp_port
                and be(OFF_MOLD_COUNT, 2) != 0
                and be(OFF_MSG0_LEN, 2) != 0)

    def feed(self, b0, b1, keep_full=True, error=False):
        """Consume one frame, return an Event or None."""
        def be(buf, off, n):
            v = 0
            for j in range(n):
                v = (v << 8) | buf[off + j]
            return v

        self.frames += 1
        ok = self.header_ok(b0, keep_full)
        if ok:
            self.accepted += 1
        else:
            self.dropped += 1
        if error:
            self.bad_fcs += 1
        if not ok:
            return None

        mtype = b1[0]
        if mtype not in (ITCH_ADD_ORDER, ITCH_EXECUTED, ITCH_CANCEL, ITCH_DELETE):
            return None

        locate = be(b1, 1, 2)
        ref = be(b1, 11, 8)

        if mtype == ITCH_ADD_ORDER:
            shares = sat_qty(be(b1, 20, 4))
            price = be(b1, 32, 4)
            is_buy = (b1[19] == SIDE_BUY)
        elif mtype == ITCH_DELETE:
            shares, price, is_buy = 0, 0, (b1[19] == SIDE_BUY)
        else:
            shares = sat_qty(be(b1, 19, 4))
            price, is_buy = 0, (b1[19] == SIDE_BUY)

        return Event(mtype, locate, ref, is_buy, shares, price)


class Book:
    """Direct-mapped order table with best bid/offer tracking."""

    def __init__(self, locate):
        self.locate = locate
        self.valid = [False] * BOOK_DEPTH
        self.buy = [False] * BOOK_DEPTH
        self.price = [0] * BOOK_DEPTH
        self.shares = [0] * BOOK_DEPTH

        self.best_bid = 0
        self.best_bid_qty = 0
        self.best_bid_valid = False
        self.best_ask = 0
        self.best_ask_qty = 0
        self.best_ask_valid = False
        self.conflict = False

    def apply(self, ev):
        """Apply one event. Returns True if the BBO changed."""
        if ev is None or ev.locate != self.locate:
            return False

        idx = ev.order_ref & (BOOK_DEPTH - 1)

        if ev.mtype == ITCH_ADD_ORDER:
            self.valid[idx] = True
            self.buy[idx] = ev.is_buy
            self.price[idx] = ev.price
            self.shares[idx] = ev.shares

            if ev.is_buy:
                if (not self.best_bid_valid) or ev.price > self.best_bid:
                    self.best_bid = ev.price
                    self.best_bid_qty = ev.shares
                    self.best_bid_valid = True
                    return True
                if ev.price == self.best_bid:
                    self.best_bid_qty += ev.shares
                    return True
            else:
                if (not self.best_ask_valid) or ev.price < self.best_ask:
                    self.best_ask = ev.price
                    self.best_ask_qty = ev.shares
                    self.best_ask_valid = True
                    return True
                if ev.price == self.best_ask:
                    self.best_ask_qty += ev.shares
                    return True
            return False

        if ev.mtype in (ITCH_EXECUTED, ITCH_CANCEL, ITCH_DELETE):
            if not self.valid[idx]:
                return False

            is_delete = (ev.mtype == ITCH_DELETE)
            resting = self.shares[idx]
            use_all = is_delete or ev.shares > resting
            take = resting if use_all else ev.shares
            remainder = 0 if use_all else resting - ev.shares

            was_buy = self.buy[idx]
            was_price = self.price[idx]
            self.shares[idx] = remainder
            self.valid[idx] = not use_all

            if was_buy and self.best_bid_valid and was_price == self.best_bid:
                if self.best_bid_qty > take:
                    self.best_bid_qty -= take
                else:
                    self.best_bid_qty = 0
                    self.best_bid_valid = False
                return True
            if (not was_buy) and self.best_ask_valid and was_price == self.best_ask:
                if self.best_ask_qty > take:
                    self.best_ask_qty -= take
                else:
                    self.best_ask_qty = 0
                    self.best_ask_valid = False
                return True
        return False


class Strategy:
    """Single-shot threshold strategy."""

    def __init__(self, enable, buy_below, sell_above, quantity):
        self.enable = enable
        self.buy_below = buy_below
        self.sell_above = sell_above
        self.quantity = quantity
        self.armed = False
        self.fires = 0

    def arm(self):
        self.armed = True

    def evaluate(self, book, bbo_changed):
        """Return (is_buy, price, shares) if this triggers a fire."""
        if not (bbo_changed and self.enable and self.armed):
            return None

        # The RTL evaluates the buy branch first.
        if book.best_ask_valid and book.best_ask <= self.buy_below:
            self.armed = False
            self.fires += 1
            return (True, book.best_ask, self.quantity)
        if book.best_bid_valid and book.best_bid >= self.sell_above:
            self.armed = False
            self.fires += 1
            return (False, book.best_bid, self.quantity)
        return None


class Pipeline:
    """parser -> book -> strategy -> order_tx, end to end."""

    def __init__(self, udp_port, locate, enable, buy_below, sell_above, quantity):
        self.parser = Parser(udp_port)
        self.book = Book(locate)
        self.strategy = Strategy(enable, buy_below, sell_above, quantity)
        self.orders = []          # (order_id, is_buy, price, shares)
        self.next_order_id = 0

    def arm(self):
        self.strategy.arm()

    def feed_frame(self, b0, b1, keep_full=True, error=False):
        ev = self.parser.feed(b0, b1, keep_full, error)
        changed = self.book.apply(ev)
        fire = self.strategy.evaluate(self.book, changed)
        if fire is not None:
            is_buy, price, shares = fire
            self.orders.append((self.next_order_id, is_buy, price, shares))
            self.next_order_id += 1
        return ev
