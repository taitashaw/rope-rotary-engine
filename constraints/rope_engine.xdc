# -----------------------------------------------------------------------------
# rope_engine.xdc — Timing constraints for the RoPE Rotary Engine.
#
# Target device: Zynq UltraScale+ xczu7ev-ffvc1156-2-e  (ZCU104 / ZCU106).
# Target clock:  400 MHz (2.5 ns). DSP48E2 @ -2 speed grade handles a
# 16b*16b multiply + 32b add in well under 2.5 ns; the four-stage rotate PE
# and the BRAM output register are the only pipeline stages in the datapath.
#
# For the IP-Integrator (block-design) flow, the clock is driven by the Zynq
# PS clk_pl_0 — we do NOT create the clock here in that case; Vivado
# auto-creates it from the PS IP. The create_clock below is for standalone
# synthesis of rope_engine as a top-level.
# -----------------------------------------------------------------------------

# Uncomment for standalone top-level synthesis (no block design):
# create_clock -name clk -period 3.125 [get_ports clk]

# False-path the async reset (standard for synchronous-deassert design)
# (When wrapped in a block design the PS-reset IP handles synchronization.)
# set_false_path -from [get_ports rst_n]

# Bitstream generation options
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property CONFIG_VOLTAGE 1.8         [current_design]
set_property CFGBVS GND                 [current_design]
