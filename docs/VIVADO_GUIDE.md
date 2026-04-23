# Vivado / XSim — End-to-End Guide

Step-by-step, zero ambiguity. Assumes Vivado 2022.2 or newer on Ubuntu.

## 0. One-time setup

```bash
# source the Vivado environment (adjust version/path)
source /tools/Xilinx/Vivado/2023.2/settings64.sh

# confirm
which vivado && vivado -version | head -2
```

Clone the repo and generate the golden vectors:

```bash
git clone https://github.com/taitashaw/rope-rotary-engine.git
cd rope-rotary-engine
make vectors
# => [PASS] Q1.15 golden model vs float reference: max_abs_err = 5.58e-05
# => [OK] wrote 16 tests to tb/vectors/
```

---

## 1. Behavioral simulation with XSim + waveforms in Vivado GUI

### 1a. One-shot from the command line

```bash
make xsim
```

This:

1. Regenerates vectors (idempotent).
2. Copies `tb/vectors/*.hex` + `config.vh` into `build/sim/` so `$readmemh` finds them.
3. Runs `xvlog` → `xelab` → `xsim` in batch mode.
4. Writes `build/sim/rope_engine_tb.wdb` (the waveform database).
5. Prints `RESULT: PASS (16/16 tests, 0 bit-errors)`.

### 1b. Opening the waveform in Vivado GUI

```bash
vivado &
```

Then in the Vivado GUI:

1. `File → Open Waveform Database…`
2. Navigate to `build/sim/rope_engine_tb.wdb` and open.
3. Vivado opens the Waveform Viewer with every signal recorded.
4. In the **Scope** pane, drill into `rope_engine_tb → dut`.
5. Drag these signals into the wave window (in order):
   - `clk`, `rst_n`
   - `s_valid`, `s_data`, `s_position`, `s_last`, `s_fire`, `pair_first`, `beat_cnt`
   - `eff_position` *(this is where the bug fix lives — watch it bypass on the first beat of each vector)*
   - `g_lut[0].b0.u_lut.rd_addr`
   - `cos_arr[0]`, `sin_arr[0]`
   - `s1_valid`, `s1_data`
   - `g_pe[0].u_pe.s3_even_acc`, `g_pe[0].u_pe.s3_odd_acc`
   - `m_valid`, `m_data`, `m_last`
6. Zoom to fit (`F6`) — the 16 test vectors span ~750 ns.

### 1c. Interactive XSim from the Vivado GUI (alternative to 1a)

If you'd rather drive simulation from the GUI:

1. `File → Project → New…` — name it `rope_engine_sim`, type `RTL`.
2. `Add Sources → Add or Create Design Sources` — point at `rtl/*.sv` and `tb/rope_engine_tb.sv`. Enable "Copy sources into project" if you want.
3. `Add Sources → Add or Create Constraints` — `constraints/rope_engine.xdc`.
4. `Project Manager → Simulation Settings` — set **Simulation Top** to `rope_engine_tb`.
5. Copy the hex/config files into the sim runtime dir:
   ```bash
   cp tb/vectors/*.hex tb/vectors/config.vh \
      rope_engine_sim/rope_engine_sim.sim/sim_1/behav/xsim/
   ```
6. Click **Run Simulation → Run Behavioral Simulation**.
7. The Waveform Viewer opens live; the console prints `RESULT: PASS (16/16 …)`.

---

## 2. Out-of-context synthesis (get utilization + timing, no bitstream)

This is the fastest way to see real numbers for the IP on any device. No block design needed.

### 2a. Flagship Zynq UltraScale+ (default — ZU19EG, HTG-937 class)

```bash
make synth
```

Equivalent manual form:

```bash
mkdir -p build && cd build
vivado -mode batch -source ../scripts/vivado_synth.tcl \
       -tclargs --part xczu19eg-ffvd1760-2-e
```

Outputs in `build/`:

| File | What to look at |
|---|---|
| `rope_engine_utilization.rpt` | CLB LUT / FF / BRAM / DSP counts |
| `rope_engine_timing.rpt` | Look for the **WNS** (Worst Negative Slack) line. Positive WNS = closing 400 MHz. |
| `rope_engine_impl.dcp` | Post-route checkpoint. Open in Vivado for device view. |

### 2b. Flagship Virtex UltraScale+ (Alveo U250 / VCU118 silicon)

```bash
cd build && vivado -mode batch -source ../scripts/vivado_synth.tcl \
                   -tclargs --part xcvu9p-flga2104-2L-e
```

### 2c. HBM flagship Virtex (VCU128 — xcvu37p)

```bash
cd build && vivado -mode batch -source ../scripts/vivado_synth.tcl \
                   -tclargs --part xcvu37p-fsvh2892-2-e
```

### 2d. Baseline Zynq (ZCU104/106)

```bash
cd build && vivado -mode batch -source ../scripts/vivado_synth.tcl \
                   -tclargs --part xczu7ev-ffvc1156-2-e
```

After any of the above, inspect the timing report:

```bash
grep -E "WNS|TNS|Worst Negative" build/rope_engine_timing.rpt | head -5
```

A line like `WNS = 0.352` means you have 352 ps of positive slack — **400 MHz closes.** Put that number on the LinkedIn post.

---

## 3. Block design + bitstream generation

For a bootable bitstream on Zynq UltraScale+. Ideal for the "this IP drops into a real silicon platform" demo.

### 3a. Default (flagship: ZU19EG on HTG-937)

```bash
make bd
```

### 3b. Override to any Zynq US+ board

```bash
cd build && vivado -mode batch -source ../scripts/vivado_bd.tcl \
                   -tclargs --part xczu7ev-ffvc1156-2-e \
                            --board xilinx.com:zcu104:part0:1.1
```

### 3c. What gets built

The TCL script (`scripts/vivado_bd.tcl`) does this end-to-end without touching the GUI:

1. Creates a Vivado project `rope_soc/` in `build/`.
2. Instantiates the Zynq UltraScale+ PS block (Processing System) with default preset.
3. Instantiates AXI-DMA (scatter-gather off, 128-bit TDATA on both directions).
4. Adds `rope_engine` as a module reference.
5. Adds `proc_sys_reset` and ties the PS clocks/resets.
6. Runs `apply_bd_automation` for the three AXI connections:
   - PS `M_AXI_HPM0_FPD` → DMA `S_AXI_LITE` (control plane)
   - DMA `M_AXI_MM2S` → PS `S_AXI_HP0_FPD` (ingress reads from DDR)
   - DMA `M_AXI_S2MM` → PS `S_AXI_HP0_FPD` (egress writes to DDR)
7. Validates the block design, saves it, wraps it with `make_wrapper`.
8. Launches `synth_1` and `impl_1 → write_bitstream`.

**Output:**

```
build/rope_soc/rope_soc.runs/impl_1/rope_soc_wrapper.bit
```

Total wall time on a decent workstation: 15–30 min depending on target.

### 3d. Manual GUI walkthrough (if you prefer)

If you'd rather build the BD by hand to screenshot for the LinkedIn post:

1. `File → Project → New` — name `rope_soc`, type `RTL`. Part: `xczu19eg-ffvd1760-2-e` (or your choice).
2. Add `rtl/*.sv` as design sources.
3. `IP Integrator → Create Block Design` — name `rope_soc`.
4. Drop in these IPs (`+` button):
   - **Zynq UltraScale+ MPSoC** → run board-preset automation.
   - **AXI Direct Memory Access** → set `Include SG = off`, `MM2S/S2MM Burst = 16`, widths 128-bit.
   - **Processor System Reset**.
5. Right-click in the canvas → `Add Module` → pick `rope_engine`.
6. Click **Run Connection Automation** to auto-wire AXI.
7. Manually wire the streams (AXIS-in adapter → `rope_0/s_*`, `rope_0/m_*` → AXIS-out adapter).
8. `Validate Design` (F6). Save.
9. `Sources → rope_soc.bd` right-click → `Create HDL Wrapper`.
10. `Flow → Run Synthesis → Run Implementation → Generate Bitstream`.

### 3e. Viewing the finished block design

Once built (either path):

```bash
vivado build/rope_soc/rope_soc.xpr
```

In the GUI: `IP Integrator → Open Block Design`. The finished topology matches the diagram in the root `README.md`. Screenshot that canvas for the LinkedIn post — it does more work than any paragraph.

---

## 4. Sanity checks after the run

```bash
# Did synthesis succeed?
grep -E "synth_design completed successfully" build/*.log

# What's the WNS?
grep -A1 "Worst Negative Slack" build/rope_engine_timing.rpt | head -4

# Utilization summary (LUT, FF, BRAM, DSP)
grep -E "CLB LUTs|CLB Registers|Block RAM Tile|DSPs " \
    build/rope_engine_utilization.rpt | head -20

# Bitstream actually produced?
ls -lh build/rope_soc/rope_soc.runs/impl_1/*.bit
```

---

## 5. Device-tier cheat sheet

| Use case | Recommended part | Board preset | Bitstream? |
|---|---|---|---|
| Real board, quick demo | `xczu7ev-ffvc1156-2-e` | `xilinx.com:zcu104:part0:1.1` | ✅ |
| Flagship Zynq SoC (default) | `xczu19eg-ffvd1760-2-e` | `htg.com:htg-zrf8-zu19eg:part0:1.0` | ✅ |
| RFSoC | `xczu49dr-ffvf1760-2-e` | `xilinx.com:zcu216:part0:1.3` | ✅ |
| Datacenter (F1/Alveo U250) | `xcvu9p-flga2104-2L-e` | `xilinx.com:vcu118:part0:2.4` | OOC only by default |
| HBM flagship | `xcvu37p-fsvh2892-2-e` | `xilinx.com:vcu128:part0:1.0` | OOC only by default |

"OOC only by default" means the included BD script targets Zynq PS. Datacenter bitstreams need XDMA shell integration — listed in `docs/roadmap.md`. Until then, use those parts for OOC synth (utilization + timing) only.

---

## 6. Troubleshooting

**`$readmemh` fails to find hex files.**
The simulator/synthesis cwd must contain the hex files. `make xsim` / `make synth` / `make bd` handle this. If running manually, `cp tb/vectors/*.hex <your_run_dir>/` first.

**XSim warnings about `PE_LATENCY` shift register.**
Harmless — XSim sometimes flags parameter-sized shift registers with `[PE_LATENCY-1:0]` indexing. The Icarus run confirms correctness bit-for-bit.

**Vivado synth reports "BRAM not inferred".**
Check that `MAX_SEQ_LEN` ≥ 1024 for your part. Small LUTs map to distributed RAM (LUT6) instead of BRAM. For the default `MAX_SEQ_LEN=2048` this shouldn't happen.

**Timing fails (`WNS < 0`).**
The default XDC targets 400 MHz (`2.500 ns`). Relax to 300 MHz for conservative closure on lower-speed-grade devices:
```bash
sed -i 's/2\.500/3.333/' constraints/rope_engine.xdc
```
Or increase `PAIRS_PER_CYCLE` from 4 to 2 to shorten the per-beat LUT address path.
