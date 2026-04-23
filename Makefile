# -----------------------------------------------------------------------------
# RoPE Rotary Engine — top-level Makefile
# -----------------------------------------------------------------------------
# Targets
#   make vectors   — run python golden, emit test vectors + banked LUT hex
#   make sim       — compile + run the self-checking testbench (Icarus)
#   make waves     — open VCD in GTKWave
#   make synth     — run Vivado synth + impl (needs vivado on PATH)
#   make bd        — build SoC block design + bitstream (Vivado)
#   make clean     — scrub build artifacts
# -----------------------------------------------------------------------------

SHELL := /bin/bash

PY        ?= python3
IVERILOG  ?= iverilog
VVP       ?= vvp
GTKWAVE   ?= gtkwave
VIVADO    ?= vivado

RTL       := rtl/rope_skid_fifo.sv rtl/rope_rotate_pe.sv rtl/rope_sincos_lut_bank.sv rtl/rope_engine.sv
TB        := tb/rope_engine_tb.sv
TB_BP     := tb/rope_engine_bp_tb.sv
VECS      := tb/vectors

SIM_EXE    := sim_rope_tb
SIM_BP_EXE := sim_rope_bp_tb
VCD        := $(VECS)/rope_engine_tb.vcd

.PHONY: all vectors sim sim_bp xsim waves synth bd clean check

all: check

# -----------------------------------------------------------------------------
vectors:
	@$(PY) python/rope_golden.py --gen-vectors

# -----------------------------------------------------------------------------
$(SIM_EXE): $(RTL) $(TB) vectors
	@$(IVERILOG) -g2012 -I tb -o $@ $(RTL) $(TB)

$(SIM_BP_EXE): $(RTL) $(TB_BP) vectors
	@$(IVERILOG) -g2012 -I tb -o $@ $(RTL) $(TB_BP)

sim: $(SIM_EXE)
	@cd $(VECS) && $(VVP) ../../$(SIM_EXE) | tee sim.log
	@grep -q "RESULT: PASS" $(VECS)/sim.log

sim_bp: $(SIM_BP_EXE)
	@cd $(VECS) && $(VVP) ../../$(SIM_BP_EXE) | tee sim_bp.log
	@grep -q "RESULT: PASS" $(VECS)/sim_bp.log

# Run under Vivado XSim and drop a .wdb waveform openable in Vivado GUI
XSIM_DIR := build/sim
xsim: vectors
	@mkdir -p $(XSIM_DIR)
	@cp $(VECS)/*.hex $(VECS)/config.vh $(XSIM_DIR)/
	@cd $(XSIM_DIR) && $(VIVADO) -mode batch -source ../../scripts/vivado_sim.tcl \
	    -log xsim.log -journal xsim.jou

# Project-based Vivado sim with GUI (waveform viewer auto-opens).
# Default: baseline testbench.  Use `make xsim_gui_bp` for backpressure.
XSIM_GUI_DIR := build/sim_gui
xsim_gui: vectors
	@mkdir -p $(XSIM_GUI_DIR)
	@cd $(XSIM_GUI_DIR) && $(VIVADO) -mode gui \
	    -source ../../scripts/vivado_sim_project.tcl

xsim_gui_bp: vectors
	@mkdir -p $(XSIM_GUI_DIR)
	@cd $(XSIM_GUI_DIR) && $(VIVADO) -mode gui \
	    -source ../../scripts/vivado_sim_project.tcl \
	    -tclargs --top bp

waves: sim
	@$(GTKWAVE) $(VCD) &

# -----------------------------------------------------------------------------
# Smoke-check invoked by CI — exits non-zero on any test mismatch
check: sim sim_bp
	@echo ""
	@echo "====================================================="
	@echo "All tests passed:"
	@echo "  - sim     : 16/16 (no backpressure)"
	@echo "  - sim_bp  : 16/16 (60% s_valid, 60% m_ready — data preserved)"
	@echo "====================================================="

# -----------------------------------------------------------------------------
BUILD := build
synth: vectors
	@mkdir -p $(BUILD)
	@cd $(BUILD) && $(VIVADO) -mode batch -source ../scripts/vivado_synth.tcl \
	    -log synth.log -journal synth.jou

bd: vectors
	@mkdir -p $(BUILD)
	@cd $(BUILD) && $(VIVADO) -mode batch -source ../scripts/vivado_bd.tcl \
	    -log bd.log -journal bd.jou

# -----------------------------------------------------------------------------
clean:
	@rm -rf $(SIM_EXE) $(SIM_BP_EXE) $(VCD) $(VECS)/sim.log $(VECS)/sim_bp.log $(BUILD)
	@rm -f  $(VECS)/*.hex $(VECS)/config.vh
	@find . -name "*.jou" -o -name "*.log" -o -name "*.backup.*" | xargs rm -f 2>/dev/null || true
