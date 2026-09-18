#=====================================================================
# HFT pipeline verification suite
#
#   make              run every testbench, print a summary
#   make parser       run one testbench (parser|book|strategy|
#                                        order_tx|serdes|hft_top|regression)
#   make regress FRAMES=500 SEED=7     regenerate vectors and rerun
#   make wave TB=hft_top               rerun with VCD dumping enabled
#   make compat=1                      build with ETHERTYPE_COMPAT
#   make clean
#
# compat=1 works around the open parser ethertype offset bug so the
# rest of the suite can be exercised. See README.md.
#=====================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
STD      ?= -g2012

RTL_DIR  ?= ../rtl
COMMON   := common
VECTORS  := vectors
BUILD    := build

RTL      := $(wildcard $(RTL_DIR)/*.v)

FRAMES   ?= 300
SEED     ?= 1

INCLUDES := -I $(COMMON) -I $(VECTORS)

ifeq ($(compat),1)
DEFS := -DETHERTYPE_COMPAT
GENFLAGS := --ethertype-compat
else
DEFS :=
GENFLAGS :=
endif

UNIT_TBS := parser book strategy order_tx
INT_TBS  := serdes hft_top
ALL_TBS  := $(UNIT_TBS) $(INT_TBS) regression

.PHONY: all clean vectors $(ALL_TBS) list

all: $(ALL_TBS)
	@echo ""
	@echo "==================== SUITE SUMMARY ===================="
	@grep -h "TB_RESULT" $(BUILD)/*.log 2>/dev/null | sed 's/^ *//' || true
	@echo "======================================================="
	@if grep -qh "TB_RESULT: FAIL" $(BUILD)/*.log 2>/dev/null; then \
		echo "SUITE: FAIL"; exit 1; \
	else \
		echo "SUITE: PASS"; \
	fi

$(BUILD):
	@mkdir -p $(BUILD)

# --- unit and integration testbenches -------------------------------
$(UNIT_TBS) $(INT_TBS): | $(BUILD)
	@echo ">>> tb_$@"
	@$(IVERILOG) $(STD) $(INCLUDES) $(DEFS) -o $(BUILD)/tb_$@.out \
		tb_$@.v $(RTL) 2> $(BUILD)/tb_$@.cerr || \
		(echo "COMPILE FAILED:"; cat $(BUILD)/tb_$@.cerr; exit 1)
	@$(VVP) $(BUILD)/tb_$@.out > $(BUILD)/tb_$@.log 2>&1 || true
	@cat $(BUILD)/tb_$@.log

# --- python-driven random regression --------------------------------
vectors:
	@echo ">>> generating $(FRAMES) frames (seed $(SEED))"
	@mkdir -p $(VECTORS)
	@cd py && python3 gen_vectors.py --out ../$(VECTORS) \
		--frames $(FRAMES) --seed $(SEED) $(GENFLAGS)

regression: vectors | $(BUILD)
	@echo ">>> tb_regression"
	@$(IVERILOG) $(STD) $(INCLUDES) $(DEFS) -o $(BUILD)/tb_regression.out \
		tb_regression.v $(RTL) 2> $(BUILD)/tb_regression.cerr || \
		(echo "COMPILE FAILED:"; cat $(BUILD)/tb_regression.cerr; exit 1)
	@$(VVP) $(BUILD)/tb_regression.out > $(BUILD)/tb_regression.log 2>&1 || true
	@cat $(BUILD)/tb_regression.log

# Alias so `make regress FRAMES=.. SEED=..` reads naturally.
.PHONY: regress
regress: regression

# --- waveform dumping ------------------------------------------------
TB ?= hft_top
.PHONY: wave
wave: | $(BUILD)
	@$(IVERILOG) $(STD) $(INCLUDES) $(DEFS) -o $(BUILD)/tb_$(TB).out \
		tb_$(TB).v $(RTL)
	@$(VVP) $(BUILD)/tb_$(TB).out +dump
	@echo "wrote tb_$(TB).vcd"

list:
	@echo "testbenches: $(ALL_TBS)"

clean:
	@rm -rf $(BUILD) $(VECTORS) *.vcd
	@echo "cleaned"
