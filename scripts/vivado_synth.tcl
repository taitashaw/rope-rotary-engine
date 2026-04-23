# -----------------------------------------------------------------------------
# scripts/vivado_synth.tcl — One-shot synth → impl → bitstream for the
#                            RoPE Rotary Engine (standalone IP / OOC).
#
# Usage:
#     cd build
#     vivado -mode batch -source ../scripts/vivado_synth.tcl \
#            -tclargs --part xczu7ev-ffvc1156-2-e
#
# Outputs land in build/:
#     rope_engine_synth.dcp          — post-synth checkpoint
#     rope_engine_impl.dcp           — post-route checkpoint
#     rope_engine_timing.rpt         — WNS/TNS
#     rope_engine_utilization.rpt    — LUT/FF/BRAM/DSP
#     rope_engine.bit                — bitstream (for standalone top only)
# -----------------------------------------------------------------------------

# ----- Args -----
# Default to flagship Zynq UltraScale+ (HTG-937 class). Override via --part.
# Example alternatives:
#   --part xczu7ev-ffvc1156-2-e    (ZCU104/106 — baseline, real board)
#   --part xczu19eg-ffvd1760-2-e   (HTG-937   — flagship Zynq, default)
#   --part xcvu9p-flga2104-2L-e    (VCU118 / Alveo U250 silicon — OOC only)
#   --part xcvu37p-fsvh2892-2-e    (VCU128    — HBM flagship, OOC only)
set part xczu7ev-ffvc1156-2-e
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        --part { incr i; set part [lindex $argv $i] }
    }
}
puts "INFO: target part = $part"

# ----- Paths -----
set here      [file normalize [file dirname [info script]]]
set root      [file normalize $here/..]
set rtl_dir   $root/rtl
set xdc_dir   $root/constraints
set vec_dir   $root/tb/vectors
set out_dir   [pwd]
puts "INFO: output directory = $out_dir"

# ----- In-memory project -----
create_project -in_memory -part $part

# ----- Read sources -----
read_verilog -sv [glob $rtl_dir/*.sv]
read_xdc     [glob $xdc_dir/*.xdc]

# $readmemh in rope_sincos_lut_bank.sv looks for hex files in the runtime cwd.
# Make them visible to Vivado by adding the vectors/ dir to the search path.

# Also copy the banked hex files into cwd so $readmemh finds them
foreach f [glob $vec_dir/*.hex] {
    file copy -force $f $out_dir
}

# ----- Generic top (synthesize the engine OOC) -----
set_property top rope_engine [current_fileset]

# ----- Synthesis -----
puts "========== SYNTHESIS =========="
synth_design -mode out_of_context -top rope_engine -flatten_hierarchy rebuilt
write_checkpoint -force rope_engine_synth.dcp
report_utilization -file rope_engine_utilization_synth.rpt

# ----- Post-synth timing -----
# Create a virtual clock to close timing on the OOC module.
create_clock -name clk -period 3.125 [get_ports clk]
set_input_delay  -clock clk -max 0.5 [all_inputs]
set_input_delay  -clock clk -min 0.1 [all_inputs]
set_output_delay -clock clk -max 0.5 [all_outputs]
set_output_delay -clock clk -min 0.1 [all_outputs]

# ----- Implementation -----
puts "========== IMPLEMENTATION =========="
opt_design
place_design
phys_opt_design
route_design

write_checkpoint  -force rope_engine_impl.dcp
report_timing_summary -file rope_engine_timing.rpt
report_utilization    -file rope_engine_utilization.rpt

# Bitstream is only generated when there is a full design with I/O ring.
# For OOC IP, the deliverable is the impl checkpoint + reports. Wrap the
# module in the block design (see scripts/vivado_bd.tcl) to generate a
# bitstream targeting a real board.
puts "========== DONE =========="
puts "INFO: synth + impl checkpoints + timing reports written to $out_dir"
puts "INFO: run scripts/vivado_bd.tcl to produce a bootable bitstream"
