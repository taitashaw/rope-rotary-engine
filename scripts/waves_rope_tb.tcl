# -----------------------------------------------------------------------------
# scripts/waves_rope_tb.tcl
#
# Curated signal set for the baseline (no-backpressure) testbench.
# Paste into the Vivado Tcl Console after the simulation opens:
#
#     source [file normalize scripts/waves_rope_tb.tcl]
#
# Organizes 22 signals into four logical groups that together tell the
# end-to-end story of the RoPE engine.
# -----------------------------------------------------------------------------

# Clean slate
remove_wave [get_waves *]

# ----- Group 1: AXI4-Stream protocol (input + output handshakes) -----
set g1 [add_wave_group -into [current_wave_config] "1. AXI-Stream Protocol"]
add_wave -into $g1 -radix bin      {/rope_engine_tb/clk}
add_wave -into $g1 -radix bin      {/rope_engine_tb/rst_n}
add_wave -into $g1 -radix bin      {/rope_engine_tb/s_valid}
add_wave -into $g1 -radix bin      {/rope_engine_tb/s_ready}
add_wave -into $g1 -radix bin      {/rope_engine_tb/s_last}
add_wave -into $g1 -radix bin      {/rope_engine_tb/m_valid}
add_wave -into $g1 -radix bin      {/rope_engine_tb/m_last}

# ----- Group 2: Controller & eff_position bypass (the bug-fix story) -----
set g2 [add_wave_group -into [current_wave_config] "2. Controller (eff_position bypass)"]
add_wave -into $g2 -radix bin      {/rope_engine_tb/dut/s_fire}
add_wave -into $g2 -radix bin      {/rope_engine_tb/dut/pair_first}
add_wave -into $g2 -radix udecimal {/rope_engine_tb/dut/beat_cnt}
add_wave -into $g2 -radix udecimal {/rope_engine_tb/dut/cur_position}
add_wave -into $g2 -radix udecimal {/rope_engine_tb/dut/eff_position}

# ----- Group 3: Datapath — lane 0 slice (input → LUT → PE → output) -----
set g3 [add_wave_group -into [current_wave_config] "3. Datapath (lane 0)"]
add_wave -into $g3 -radix udecimal {/rope_engine_tb/s_position}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/s_data}
add_wave -into $g3 -radix udecimal {/rope_engine_tb/dut/g_lut[0].b0.u_lut/rd_addr}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/dut/g_lut[0].b0.u_lut/cos_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/dut/g_lut[0].b0.u_lut/sin_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/dut/g_pe[0].u_pe/x_even_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/dut/g_pe[0].u_pe/x_odd_out}
add_wave -into $g3 -radix sdecimal {/rope_engine_tb/m_data}

# ----- Group 4: Scoreboard (what verification cares about) -----
set g4 [add_wave_group -into [current_wave_config] "4. Scoreboard"]
add_wave -into $g4 -radix udecimal {/rope_engine_tb/beats_collected}
add_wave -into $g4 -radix udecimal {/rope_engine_tb/tokens_collected}
add_wave -into $g4 -radix udecimal {/rope_engine_tb/errors}

# Zoom to fit the full 753 ns simulation
wave_zoom_full
