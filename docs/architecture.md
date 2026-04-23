# Architecture — RoPE Rotary Engine

This document is the authoritative reference for engineers integrating, extending, or reviewing the RTL. The Python golden model (`python/rope_golden.py`) is the second reference; every design decision below is reflected there bit-for-bit.

## 1. Mathematical contract

Rotary Position Embedding (Su et al., 2021) encodes position by rotating pairs of embedding dimensions. For a token at position `m` and head dimension `d`, using the interleaved-pair convention:

```
    pair i = (x[2i], x[2i+1]),  i ∈ [0, d/2)
    x'[2i]   = x[2i] * cos(m·θ_i) − x[2i+1] * sin(m·θ_i)
    x'[2i+1] = x[2i] * sin(m·θ_i) + x[2i+1] * cos(m·θ_i)
```

Frequencies: `θ_i = base^(−2i/d)` with `base = 10000` (Llama/Qwen/DeepSeek default). For longer-context models (32k+), `base` is typically scaled to 500000; the engine supports this via LUT regeneration — no RTL change required.

## 2. Fixed-point format

All datapath values are **Q1.15 signed** (1 sign bit + 15 fraction bits, 16-bit total). Range: `[−1.0, +1.0)` with LSB = 2⁻¹⁵ ≈ 3.05 × 10⁻⁵.

| Signal | Format | Range |
|---|---|---|
| `x_even_in`, `x_odd_in`, `cos_in`, `sin_in` | Q1.15 | `[−1.0, +1.0)` |
| Internal products | Q2.30 | 32-bit signed |
| `x_even_out`, `x_odd_out` | Q1.15, saturating | `[−1.0, +1.0)` |

Self-check against float64: `max_abs_err = 5.58e-05` (< 2 LSBs, within theoretical bound for two independent Q1.15 products summed then truncated).

## 3. RTL hierarchy

```
rope_engine                  — top-level, streaming controller + PE bank
├─ rope_sincos_lut_bank (×4) — one banked LUT per PE
└─ rope_rotate_pe (×4)       — one 4-stage rotation PE per pair-lane
```

### 3.1 `rope_rotate_pe`
Pure datapath, no control logic. Four pipeline stages:

| Stage | Operation | Registers added |
|---|---|---|
| S1 | Latch inputs (`xe`, `xo`, `cos`, `sin`) | 4 × 16b |
| S2 | Four signed multiplies → `p_ec`, `p_os`, `p_es`, `p_oc` | 4 × 32b |
| S3 | `s3_even = p_ec − p_os`, `s3_odd = p_es + p_oc` (33-bit accumulator) | 2 × 33b |
| S4 | Arith shift right 15, saturate to 16b | 2 × 16b |

**Latency**: 4 cycles from `valid_in` to `valid_out`, fully pipelined (throughput = 1 pair / cycle / PE).

**DSP mapping (UltraScale+)**: 4 DSP48E2 slices per PE. With `PAIRS_PER_CYCLE = 4`, the bank consumes 16 DSPs total.

### 3.2 `rope_sincos_lut_bank`
Registered BRAM-backed ROM. Banked so that bank `g` only stores cos/sin for pair indices `{g, g+PPC, g+2·PPC, …}`:

```
depth_per_bank = MAX_SEQ_LEN × (HEAD_DIM/2) / PAIRS_PER_CYCLE
             = 2048 × 16 = 32768 entries
size_per_bank  = 32768 × 16b × 2 (cos+sin) = 1.0 Mb
```

At `PAIRS_PER_CYCLE = 4` the total LUT footprint is ~4.0 Mb — comfortably inside xczu7ev's 11 Mb of BRAM, with room to grow the LUT to `MAX_SEQ_LEN = 8192` if needed.

Initialization is from `cos_lut_bank{g}.hex` / `sin_lut_bank{g}.hex`, emitted by `python/rope_golden.py --gen-vectors`.

### 3.3 `rope_engine` (top)
Controller + glue. Pipeline map, cycle-by-cycle, for a single vector starting at cycle `T`:

| Cycle | Event |
|---|---|
| T | `s_valid=1`, `pair_first=1`. Combinational `eff_position = s_position`. LUT address issued. |
| T+1 | LUT output valid; `s1_data`, `s1_valid` registered from T. PE stage 1 latches. |
| T+2 | PE stage 2 multiply. |
| T+3 | PE stage 3 add/subtract. |
| T+4 | PE stage 4 shift+saturate. |
| T+5 | `m_valid=1`, `m_data` valid. |

**End-to-end latency**: 5 cycles per beat. **Throughput**: 1 beat / cycle = `PAIRS_PER_CYCLE × 2 × DATA_WIDTH` bits / cycle = 128 bits/cycle = 51.2 Gbps @ 400 MHz.

## 4. The one subtle bug worth calling out

On the first beat of a vector, `cur_position` still holds the *previous* vector's value (it updates on the posedge at the end of this beat). If the LUT address used `cur_position` directly, the first beat's cos/sin would come from the wrong position.

Fix (see `rope_engine.sv`, search for `eff_position`):

```systemverilog
wire [POS_WIDTH-1:0] eff_position =
    (s_fire && pair_first) ? s_position : cur_position;
```

This is the kind of bug the self-checking testbench catches on test #1 (first non-trivial vector) — exactly why we generate vectors from the Python golden rather than eyeball-comparing waveforms.

## 5. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 16 | Width of every datapath sample (Q1.15) |
| `HEAD_DIM` | 128 | Attention head dimension |
| `MAX_SEQ_LEN` | 2048 | Largest position the LUT can address |
| `PAIRS_PER_CYCLE` | 4 | Parallel rotation PEs; must divide `HEAD_DIM/2` |
| `POS_WIDTH` | 16 | Bits of position index on the stream |

Changing `HEAD_DIM` or `MAX_SEQ_LEN` requires a new hex file generation (`make vectors`). Changing `PAIRS_PER_CYCLE` rebalances DSP vs BRAM and requires a re-gen.

## 6. What this engine is not

- Not a KV-cache. It rotates on the fly; the rotated K's must still be stored by a downstream module.
- Not an extended-context RoPE variant (YaRN, NTK-aware scaling). Those are LUT-content changes, not RTL changes — see `docs/roadmap.md`.
- Not a fused attention kernel. Pair with [flashattn-softmax-engine](https://github.com/taitashaw/flashattn-softmax-engine) and [kvcache-compress-engine](https://github.com/taitashaw/kvcache-compress-engine) to cover the full hot path.
