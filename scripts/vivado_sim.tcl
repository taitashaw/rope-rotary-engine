# -----------------------------------------------------------------------------
# scripts/vivado_sim.tcl — Run the self-checking testbench under XSim
#                          and write a .wdb waveform that opens in the Vivado
#                          GUI waveform viewer.
#
# Usage (from the repo root):
#     make vectors           # emit hex files + config.vh
#     mkdir -p build/sim && cd build/sim
#     cp ../../tb/vectors/*.hex .
#     cp ../../tb/vectors/config.vh .
#     vivado -mode batch -source ../../scripts/vivado_sim.tcl
#
# Or simply:
#     make xsim              # (added in Makefile)
#
# Outputs (in build/sim/):
#     xsim.dir/              — XSim compiled artifacts
#     rope_engine_tb.wdb     — waveform database (open in Vivado)
#     xsim_run.log           — console log including RESULT line
# -----------------------------------------------------------------------------

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/..]

# Compile SystemVerilog sources
puts "========== xvlog =========="
exec xvlog -sv \
    -i $root/tb \
    $root/rtl/rope_rotate_pe.sv \
    $root/rtl/rope_sincos_lut_bank.sv \
    $root/rtl/rope_engine.sv \
    $root/tb/rope_engine_tb.sv \
    >@stdout

# Elaborate with debug symbols so every signal dumps to the WDB
puts "========== xelab =========="
exec xelab -debug typical -top rope_engine_tb -snapshot rope_tb_sim \
    >@stdout

# Run
puts "========== xsim =========="
open_wave_database rope_engine_tb.wdb
# Simpler: use xsim CLI with a run-all + exit script
set runf [open xsim_run.tcl w]
puts $runf "log_wave -recursive *"
puts $runf "run all"
puts $runf "quit"
close $runf

exec xsim rope_tb_sim -t xsim_run.tcl -wdb rope_engine_tb.wdb >@stdout

puts "========== DONE =========="
puts "Waveform: [pwd]/rope_engine_tb.wdb"
puts "Open in Vivado: File -> Open Waveform Database -> rope_engine_tb.wdb"
