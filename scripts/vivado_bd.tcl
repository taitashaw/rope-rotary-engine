# -----------------------------------------------------------------------------
# scripts/vivado_bd.tcl — Build an end-to-end SoC block design around the
#                         RoPE Rotary Engine and generate a bootable bitstream.
#
# Topology:
#     [ PS DDR ] <--AXI HP0--> [ SmartConnect ] <--AXI-- [ AXI-DMA ]
#                                      ^                     |  ^
#                                      | (control via HPM0)  |  |
#                                      |                   AXIS-MM2S
#                                      |                     |  AXIS-S2MM
#                                      |                     v  |
#                                      |               [ rope_engine_axis ]
#
# Target: ZCU104 (xczu7ev-ffvc1156-2-e) — Vivado ML Standard free license.
# Usage:
#     cd build
#     vivado -mode batch -source ../scripts/vivado_bd.tcl
# -----------------------------------------------------------------------------

# ----- Args / defaults -----
set part  xczu7ev-ffvc1156-2-e
set board "xilinx.com:zcu104:part0:1.1"
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -exact -- [lindex $argv $i] {
        --part  { incr i; set part  [lindex $argv $i] }
        --board { incr i; set board [lindex $argv $i] }
    }
}
puts "INFO: part  = $part"
puts "INFO: board = $board"

set here [file normalize [file dirname [info script]]]
set root [file normalize $here/..]
set rtl_dir $root/rtl
set xdc_dir $root/constraints
set vec_dir $root/tb/vectors

# ----- Project -----
create_project rope_soc . -force -part $part
set_property board_part $board [current_project]

# Register RTL sources — both .sv (core engine) and .v (wrapper for BD
# module reference). Vivado requires the top of a module reference to be
# of file_type=Verilog, which is why rope_engine_axis is .v not .sv.
add_files -fileset sources_1 [glob $rtl_dir/*.sv $rtl_dir/*.v]
add_files -fileset constrs_1 [glob $xdc_dir/*.xdc]

# $readmemh in rope_sincos_lut_bank.sv reads cos/sin tables at elaboration.
foreach f [glob $vec_dir/*.hex] { file copy -force $f [pwd] }

# -----------------------------------------------------------------------------
# Block design
# -----------------------------------------------------------------------------
create_bd_design rope_soc

# Zynq UltraScale+ PS (ps_0)
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 ps_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps_0]

# Enable only the PS ports we need; disable HPM1 so it doesn't dangle.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] [get_bd_cells ps_0]

# AXI DMA (128-bit data path matching rope_engine's AXIS width)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_0
set_property -dict [list \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_sg_length_width         {26} \
    CONFIG.c_mm2s_burst_size         {16} \
    CONFIG.c_s2mm_burst_size         {16} \
    CONFIG.c_m_axi_mm2s_data_width   {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_m_axi_s2mm_data_width   {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
] [get_bd_cells dma_0]

# RoPE engine (AXI-Stream wrapped, Verilog-2001 top for BD module-ref)
create_bd_cell -type module -reference rope_engine_axis rope_0

# Processor system reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0

# Clock + reset wiring
connect_bd_net [get_bd_pins ps_0/pl_clk0]   [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps_0/pl_resetn0] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins ps_0/pl_clk0]   [get_bd_pins rope_0/clk]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins rope_0/rst_n]

# AXI-MM wiring (SmartConnects auto-inferred by apply_bd_automation)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/ps_0/M_AXI_HPM0_FPD" Clk "Auto"} \
    [get_bd_intf_pins dma_0/S_AXI_LITE]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/dma_0/M_AXI_MM2S" Clk "Auto"} \
    [get_bd_intf_pins ps_0/S_AXI_HP0_FPD]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/dma_0/M_AXI_S2MM" Clk "Auto"} \
    [get_bd_intf_pins ps_0/S_AXI_HP0_FPD]

# AXI4-Stream wiring
connect_bd_intf_net \
    [get_bd_intf_pins dma_0/M_AXIS_MM2S] [get_bd_intf_pins rope_0/S_AXIS]
connect_bd_intf_net \
    [get_bd_intf_pins rope_0/M_AXIS] [get_bd_intf_pins dma_0/S_AXIS_S2MM]

# Close out address assignment (MM2S + S2MM into PS DDR window)
assign_bd_address

regenerate_bd_layout
validate_bd_design
save_bd_design

# -----------------------------------------------------------------------------
# Wrapper + synth + impl + bitstream
# -----------------------------------------------------------------------------
make_wrapper -files [get_files rope_soc.bd] -top -import
set_property top rope_soc_wrapper [current_fileset]

launch_runs synth_1 -jobs 8
wait_on_run  synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run  impl_1

puts "========== BITSTREAM READY =========="
puts [get_property DIRECTORY [get_runs impl_1]]
