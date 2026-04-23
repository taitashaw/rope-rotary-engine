# -----------------------------------------------------------------------------
# scripts/vivado_sim_project.tcl — Project-based XSim flow that launches the
#                                   Vivado waveform GUI.
#
# Creates a Vivado project with both testbenches registered. User chooses
# which is the sim top via the Flow Navigator → Simulation Settings, or via
# the command line on re-invocation:
#
#     vivado -mode gui -source vivado_sim_project.tcl
#         (uses default — rope_engine_tb)
#
#     vivado -mode gui -source vivado_sim_project.tcl -tclargs --top bp
#         (switches to rope_engine_bp_tb)
# -----------------------------------------------------------------------------

# ----- CLI args -----
set sim_top "rope_engine_tb"
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        --top {
            incr i
            set arg [lindex $argv $i]
            if {$arg == "bp"} {
                set sim_top "rope_engine_bp_tb"
            } elseif {$arg == "base"} {
                set sim_top "rope_engine_tb"
            } else {
                set sim_top $arg
            }
        }
    }
}
puts "INFO: sim top = $sim_top"

# ----- Paths -----
set here [file normalize [file dirname [info script]]]
set root [file normalize $here/..]
set vec  $root/tb/vectors

# ----- Project -----
create_project rope_sim . -force -part xczu7ev-ffvc1156-2-e

# ----- Design sources -----
foreach f [glob $root/rtl/*.sv] { add_files -fileset sources_1 $f }

# ----- Simulation sources — both testbenches registered -----
add_files -fileset sim_1 $root/tb/rope_engine_tb.sv
add_files -fileset sim_1 $root/tb/rope_engine_bp_tb.sv

# ----- Include paths for config.vh -----
set_property include_dirs [list $vec $root/tb] [get_filesets sim_1]

# ----- Sim top (user-selected) -----
set_property top $sim_top [get_filesets sim_1]

# ----- Copy hex/config files where xsim will find them -----
set sim_run_dir [file normalize [pwd]/rope_sim.sim/sim_1/behav/xsim]
file mkdir $sim_run_dir
foreach f [glob $vec/*.hex] { file copy -force $f $sim_run_dir }
file copy -force $vec/config.vh $sim_run_dir

# Also copy next to project root (elaboration may run there)
foreach f [glob $vec/*.hex] { file copy -force $f [pwd] }
file copy -force $vec/config.vh [pwd]

puts "========== Project created. Sim top = $sim_top =========="
puts "To run simulation: Flow Navigator -> SIMULATION -> Run Simulation"
puts ""
puts "To load curated waveform view after sim opens, paste in Tcl Console:"
if {$sim_top == "rope_engine_bp_tb"} {
    puts "  source $root/scripts/waves_rope_bp_tb.tcl"
} else {
    puts "  source $root/scripts/waves_rope_tb.tcl"
}
