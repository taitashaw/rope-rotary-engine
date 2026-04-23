# Roadmap

The v1 engine is a correct, synthesizable, testable reference implementation. These are the optimizations and variants that belong on the roadmap but are *not* in the v1 scope.

## Short-term (1-week tasks)

- **YaRN / NTK-aware scaling**: Regenerate the LUT with scaled frequencies; no RTL change. Adds support for context windows >>4k on models trained with `base = 500000`.
- **CORDIC variant**: Replace the BRAM LUT with a CORDIC iterator. Trades BRAM for LUTs/FFs; useful on low-end FPGAs (Artix-7, Zynq-7000) where BRAM is the bottleneck.
- **AXIS wrapper**: Add `rope_axis_wrap.sv` that adapts the wide parallel interface to a standard 128/256-bit AXI4-Stream with TUSER for position. Makes the Vivado block-design drop-in cleaner.
- **Cocotb testbench**: Add a Python-side cocotb driver to run the golden model as a co-simulation checker (vs the current $readmemh-based SV testbench).

## Medium-term (2–4 week tasks)

- **Fused Q/K rotation**: Many inference kernels apply RoPE to Q and K in the same cycle. Duplicate the PE bank and share the LUT bank output to halve LUT accesses.
- **BF16 / FP16 datapath**: Replace Q1.15 with BF16 for better numerical headroom on long sequences. Requires swapping the integer multiply for a floating-point DSP primitive.
- **Multi-head broadcast**: Share a single LUT across H heads by broadcasting cos/sin with a one-cycle register chain. Cuts BRAM by H×.
- **On-the-fly frequency computation**: For very long contexts, compute `θ_i = base^(−2i/d)` incrementally (`θ_{i+1} = θ_i × base^(−2/d)`) instead of storing the full table. Log reduction in BRAM at cost of a startup latency.

## Long-term (research-flavored)

- **Axial RoPE for vision transformers** (split embedding into x/y axes with independent rotations — see Heo et al., ECCV 2024). Two engines in parallel with a concat at the tail.
- **RoME integration** (Rotary Matrix Embedding — the matrix-fused reformulation from this month's arXiv paper). Requires reworking the PE into a 2×2 matmul primitive with shared operand broadcast.
- **ASIC port**: The design is intentionally FPGA-friendly (inferred DSP + BRAM), but the PEs are fully parameterized and synthesizable to a standard-cell flow. Intended path for an IP license to an AI silicon team.

## Known limitations (v1)

- Interleaved-pair convention only. The "half-rotation" convention used by some HuggingFace models (swap halves instead of pairs) is a pure reindexing and can be handled with a byte-shuffle in front of the engine; a compile-time switch is a candidate for v1.1.
- No back-pressure on the slave interface (`s_ready` is tied high). Callers that need back-pressure should insert a FIFO upstream; a native elastic input is on the short-term list.
- `MAX_SEQ_LEN` is a synthesis-time parameter, not runtime. Runtime reconfiguration would require switching to a CORDIC or on-the-fly frequency generator (see medium-term).
