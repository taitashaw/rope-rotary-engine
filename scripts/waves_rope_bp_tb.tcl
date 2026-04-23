# -----------------------------------------------------------------------------
# scripts/waves_rope_bp_tb.tcl
#
# Curated signal set for the backpressure testbench. Emphasizes what's
# different from the baseline: FIFO fill levels, s_ready / m_ready gating,
# and stall counters.
#
# Usage (from Vivado Tcl Console after sim opens):
#
#     source [file normalize scripts/waves_rope_bp_tb.tcl]
#
# Tells the story: even with 60% duty cycle on both handshakes, zero data
# is lost, and the scoreboard's error count stays at 0 across all 16 vectors.
# -----------------------------------------------------------------------------

remove_wave [get_waves *]

# ----- Group 1: Full AXI4-Stream handshakes (both sides active) -----
set g1 [add_wave_group -into [current_wave_config] "1. AXI-Stream Handshakes"]
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/clk}
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/rst_n}
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/s_valid}
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/s_ready}
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/m_valid}
add_wave -into $g1 -radix bin      {/rope_engine_bp_tb/m_ready}

# ----- Group 2: FIFO credit-based throttle (the backpressure mechanism) -----
set g2 [add_wave_group -into [current_wave_config] "2. Credit-based Throttle"]
add_wave -into $g2 -radix udecimal {/rope_engine_bp_tb/dut/fifo_free}
add_wave -into $g2 -radix udecimal {/rope_engine_bp_tb/dut/in_flight}
add_wave -into $g2 -radix bin      {/rope_engine_bp_tb/dut/out_fifo_ready}
add_wave -into $g2 -radix bin      {/rope_engine_bp_tb/dut/push_fire}
add_wave -into $g2 -radix bin      {/rope_engine_bp_tb/dut/pop_fire}

# ----- Group 3: Core datapath (same as baseline, lane 0) -----
set g3 [add_wave_group -into [current_wave_config] "3. Datapath (lane 0)"]
add_wave -into $g3 -radix udecimal {/rope_engine_bp_tb/dut/eff_position}
add_wave -into $g3 -radix udecimal {/rope_engine_bp_tb/dut/g_lut[0].b0.u_lut/rd_addr}
add_wave -into $g3 -radix sdecimal {/rope_engine_bp_tb/dut/g_lut[0].b0.u_lut/cos_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_bp_tb/dut/g_lut[0].b0.u_lut/sin_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_bp_tb/s_data}
add_wave -into $g3 -radix sdecimal {/rope_engine_bp_tb/m_data}

# ----- Group 4: Scoreboard + stall counters -----
set g4 [add_wave_group -into [current_wave_config] "4. Scoreboard + Stalls"]
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/beats_driven}
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/beats_collected}
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/tokens_collected}
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/stall_s_cycles}
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/stall_m_cycles}
add_wave -into $g4 -radix udecimal {/rope_engine_bp_tb/errors}

wave_zoom_full
