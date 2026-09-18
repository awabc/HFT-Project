# Verification suite

Self-checking testbenches for the HFT tick-to-trade pipeline. Every
testbench prints a machine-readable `TB_RESULT: PASS|FAIL` line, and the
Makefile exits non-zero if any of them fail, so this drops straight into 
a regression script.

Requires Icarus Verilog 11+ and Python 3.

## Quick start

```sh
cd verif
make compat=1          # run everything (see "Known bugs" for compat=1)
make parser            # run a single testbench
make regress FRAMES=1000 SEED=7
make wave TB=hft_top   # rerun with VCD dumping, then open tb_hft_top.vcd
make clean
```

## Layout

```
tb/
├── Makefile              build + run driver, suite-level pass/fail
|-- tb_defs.vh            check macros, pass/fail counters, watchdog
│-- itch_frame.vh         Verilog frame + ITCH message builder
├── tb_parser.v           unit: header filtering, ITCH decode, stats
├── tb_book.v             unit: BBO tracking, reductions, conflicts
├── tb_strategy.v         unit: arm/fire logic and every guard condition
├── tb_order_tx.v         unit: packet construction, AXI handshake
├── tb_serdes.v           the 64-bit chunk SERDES at the top boundary
├── tb_hft_top.v          integration: frame in -> order packet out
├── tb_regression.v       randomized regression vs the Python model
│-- itch_model.py         frame builder + behavioural golden model
│-- gen_vectors.py        constrained-random stimulus generator
└── vectors/              generated, not checked in
```

## The four layers

**Unit testbenches** (`tb_parser`, `tb_book`, `tb_strategy`,
`tb_order_tx`) drive each module directly at its own interface. They are
where a failure tells you exactly which line is wrong. `tb_book` drives
packed event markers rather than going through the parser, so book
behaviour can be tested even while the parser is broken.

**SERDES testbench** (`tb_serdes`) tests only the chunking at the die
boundary: MSB-first ordering both ways, `tkeep` travelling with its
chunk, `tlast`/`tuser_error` latching, backpressure, idle gaps
mid-beat, and measured serialization latency. It reaches into
`parser_inst`'s input and forces `order_tx`'s output so the trading
pipeline never has to produce anything.

**Integration testbench** (`tb_hft_top`) is the only one that proves the
modules are wired together correctly. It drives real frames in on the
64-bit RX pins and reassembles the outbound order packet from the TX
pins, checking headers and payload. This is what catches offsets that
two modules disagree about, config that never reaches `strategy`, and
stats routed to the wrong output pin. 

**Randomized regression** (`tb_regression` + `py/`) `gen_vectors.py`
builds a constrained-random frame stream — mixing well-formed frames
with bad ports, bad ethertypes, non-UDP protocols, short beats, FCS
errors and unknown message types — runs it through the Python golden
model in `itch_model.py`, and writes both the stimulus and the expected
result as `$readmemh` vectors. `tb_regression.v` replays the stimulus
through the real chunk pins and compares the DUT's BBO and every emitted
order against the model, frame by frame.


Run several seeds:

```sh
for s in 1 2 3 4 5; do make regress FRAMES=500 SEED=$s || break; done
```

## Known bugs found by this suite

All three were found by running the suite against the RTL as delivered.
Each is a one-line fix, and with all three applied the entire suite —
including 900 randomized frames across three seeds — passes.

### 1. `parser.v`: ethertype read from the wrong offset

```verilog
localparam OFF_ETHERTYPE = 2;    // should be 12
```

### 2. `parser.v`: `event_valid` is stuck high

```verilog
end else begin
    event_valid <= 1'b1;    // should be 1'b0 - this is the default arm
```

### 3. `book.v`: order table is never reset

```verilog
reg order_valid[DEPTH];   // no reset anywhere
```
