//=====================================================================
// tb_defs.vh - shared self-checking infrastructure
//
// Include inside a testbench module, then call `TB_VARS once at module
// scope. Every check funnels through the same counters so each
// testbench can end with a single machine-readable verdict line that
// the Makefile greps 
//=====================================================================
`ifndef TB_DEFS_VH
`define TB_DEFS_VH

// Module-scope bookkeeping. Declare once per testbench.
`define TB_VARS                                                        \
    integer tb_pass  = 0;                                              \
    integer tb_fail  = 0;                                              \
    integer tb_total = 0;                                              \
    reg [1023:0] tb_section = "start";

// Section banner - groups checks in the log.
`define TB_SECTION(name)                                               \
    begin                                                              \
        tb_section = name;                                             \
        $display("");                                                  \
        $display("  --- %0s ---", name);                               \
    end

// Boolean check.
`define CHECK(cond, msg)                                               \
    begin                                                              \
        tb_total = tb_total + 1;                                       \
        if (cond) begin                                                \
            tb_pass = tb_pass + 1;                                     \
            $display("    [PASS] %0s", msg);                           \
        end else begin                                                 \
            tb_fail = tb_fail + 1;                                     \
            $display("    [FAIL] %0s   (t=%0t)", msg, $time);          \
        end                                                            \
    end

// Equality check. Uses === so X/Z mismatches are caught rather than
// silently comparing as unknown - important here because book.v leaves
// its order table unreset.
`define CHECK_EQ(got, exp, msg)                                        \
    begin                                                              \
        tb_total = tb_total + 1;                                       \
        if ((got) === (exp)) begin                                     \
            tb_pass = tb_pass + 1;                                     \
            $display("    [PASS] %0s", msg);                           \
        end else begin                                                 \
            tb_fail = tb_fail + 1;                                     \
            $display("    [FAIL] %0s : got=%0h expected=%0h  (t=%0t)", \
                     msg, got, exp, $time);                            \
        end                                                            \
    end

// Explicitly flag a known-open RTL bug. Counted separately so an open
// bug does not mask a regression elsewhere, and so the suite does not
// go green while the bug is still there.
`define CHECK_KNOWN_BUG(cond, msg, note)                               \
    begin                                                              \
        tb_total = tb_total + 1;                                       \
        if (cond) begin                                                \
            tb_pass = tb_pass + 1;                                     \
            $display("    [PASS] %0s", msg);                           \
        end else begin                                                 \
            tb_fail = tb_fail + 1;                                     \
            $display("    [FAIL] %0s   (t=%0t)", msg, $time);          \
            $display("           ^^ KNOWN RTL BUG: %0s", note);        \
        end                                                            \
    end

// Final verdict. The "TB_RESULT:" line is the Makefile's hook.
`define TB_SUMMARY(name)                                               \
    begin                                                              \
        $display("");                                                  \
        $display("  =========================================");        \
        $display("   %0s : %0d/%0d checks passed, %0d failed",          \
                 name, tb_pass, tb_total, tb_fail);                     \
        if (tb_fail == 0)                                               \
            $display("   TB_RESULT: PASS  (%0s)", name);                \
        else                                                            \
            $display("   TB_RESULT: FAIL  (%0s)", name);                \
        $display("  =========================================");        \
        $display("");                                                   \
    end

// Watchdog - any testbench that hangs fails loudly instead of running
// until the simulator gives up. The parentheses around (cycles) matter:
// the argument is often an expression.
`define TB_TIMEOUT(cycles)                                             \
    initial begin                                                      \
        #((cycles) * 10);                                              \
        $display("    [FAIL] TIMEOUT after %0d cycles", (cycles));     \
        $display("   TB_RESULT: FAIL (timeout)");                      \
        $finish;                                                       \
    end

`endif
