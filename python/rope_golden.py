"""
rope_golden.py — Bit-accurate Python golden model for the RoPE Rotary Engine.

Reference implementation of Rotary Position Embedding (Su et al., 2021) in
Q1.15 signed fixed-point, matching the RTL datapath exactly.

This is the *product*. The RTL is just the implementation.

Variant: interleaved-pairs (original paper form).
    pair i = (x[2i], x[2i+1]),  i in [0, head_dim/2)
    x'[2i]   = x[2i] * cos(m*theta_i) - x[2i+1] * sin(m*theta_i)
    x'[2i+1] = x[2i] * sin(m*theta_i) + x[2i+1] * cos(m*theta_i)

Frequencies: theta_i = base^(-2i/head_dim), base = 10000.

Usage:
    python rope_golden.py                # self-check against float reference
    python rope_golden.py --gen-vectors  # emit hex vectors for RTL testbench
"""
from __future__ import annotations
import argparse
import os
import sys
import numpy as np

# ---------------------------------------------------------------------------
# Fixed-point primitives (Q1.15 signed, 16-bit)
# ---------------------------------------------------------------------------
Q_FRAC = 15
Q_ONE  = 1 << Q_FRAC          # 32768
Q_MIN  = -(1 << 15)           # -32768
Q_MAX  =  (1 << 15) - 1       #  32767


def float_to_q15(x):
    """Convert float in [-1, 1) to Q1.15 signed int16. Saturates."""
    q = np.round(np.asarray(x) * Q_ONE)
    q = np.clip(q, Q_MIN, Q_MAX)
    return q.astype(np.int16)


def q15_to_float(x):
    return np.asarray(x, dtype=np.float64) / Q_ONE


def fp_mul(a, b):
    """Q1.15 * Q1.15 -> Q1.15 with truncation toward -inf (arith >>).

    Matches an RTL `signed($signed(a) * $signed(b)) >>> 15` (arithmetic
    right-shift of the 32-bit signed product)."""
    a = np.int64(a)
    b = np.int64(b)
    # arithmetic right shift on signed 64-bit
    return (a * b) >> Q_FRAC


def sat16(x):
    """Saturate an integer or array to signed 16-bit range."""
    return np.clip(x, Q_MIN, Q_MAX).astype(np.int16)


# ---------------------------------------------------------------------------
# RoPE frequency table
# ---------------------------------------------------------------------------
def compute_sincos_tables(head_dim: int, max_seq_len: int, base: float = 10000.0):
    """Precompute (cos, sin) tables in Q1.15.

    Returns
    -------
    cos_q, sin_q : int16 arrays, shape = (max_seq_len, head_dim // 2)
    """
    assert head_dim % 2 == 0, "head_dim must be even"
    n_pairs = head_dim // 2
    i       = np.arange(n_pairs, dtype=np.float64)
    theta   = np.power(base, -2.0 * i / head_dim)                 # (n_pairs,)
    m       = np.arange(max_seq_len, dtype=np.float64)[:, None]   # (seq, 1)
    angles  = m * theta                                           # (seq, n_pairs)
    return float_to_q15(np.cos(angles)), float_to_q15(np.sin(angles))


# ---------------------------------------------------------------------------
# Core rotation (matches RTL PE exactly)
# ---------------------------------------------------------------------------
def rotate_pair(x_even, x_odd, cos_q, sin_q):
    """One rotation PE. All inputs/outputs Q1.15.

    Datapath (identical to RTL):
        p0 = x_even * cos      (Q2.30)
        p1 = x_odd  * sin
        p2 = x_even * sin
        p3 = x_odd  * cos
        new_even_wide = (p0 - p1) >>> 15   (Q1.15)
        new_odd_wide  = (p2 + p3) >>> 15
        saturate -> int16
    """
    p0 = np.int64(x_even) * np.int64(cos_q)
    p1 = np.int64(x_odd)  * np.int64(sin_q)
    p2 = np.int64(x_even) * np.int64(sin_q)
    p3 = np.int64(x_odd)  * np.int64(cos_q)
    new_even = (p0 - p1) >> Q_FRAC
    new_odd  = (p2 + p3) >> Q_FRAC
    return sat16(new_even), sat16(new_odd)


def apply_rope_vec(x_q: np.ndarray, position: int,
                   cos_tbl: np.ndarray, sin_tbl: np.ndarray) -> np.ndarray:
    """Apply RoPE to a full head vector at `position`.

    x_q      : int16, shape (head_dim,)
    returns  : int16, shape (head_dim,)
    """
    head_dim = x_q.shape[0]
    n_pairs  = head_dim // 2
    out      = np.empty_like(x_q)
    for i in range(n_pairs):
        e, o = rotate_pair(x_q[2 * i], x_q[2 * i + 1],
                           cos_tbl[position, i], sin_tbl[position, i])
        out[2 * i]     = e
        out[2 * i + 1] = o
    return out


# ---------------------------------------------------------------------------
# Float reference (for accuracy check)
# ---------------------------------------------------------------------------
def apply_rope_float(x_f: np.ndarray, position: int, base: float = 10000.0):
    head_dim = x_f.shape[0]
    n_pairs  = head_dim // 2
    i = np.arange(n_pairs)
    theta  = np.power(base, -2.0 * i / head_dim)
    angle  = position * theta
    c, s   = np.cos(angle), np.sin(angle)
    out    = np.empty_like(x_f)
    out[0::2] = x_f[0::2] * c - x_f[1::2] * s
    out[1::2] = x_f[0::2] * s + x_f[1::2] * c
    return out


# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------
def self_check():
    rng = np.random.default_rng(42)
    head_dim, seq_len, base = 128, 2048, 10000.0
    cos_tbl, sin_tbl = compute_sincos_tables(head_dim, seq_len, base)

    # Use inputs bounded by 0.45 so |out| <= 0.9 (no Q1.15 saturation); saturation
    # is exercised separately in gen_vectors edge cases.
    max_abs_err = 0.0
    for _ in range(64):
        position = int(rng.integers(0, seq_len))
        x_f = rng.uniform(-0.45, 0.45, size=head_dim)
        x_q = float_to_q15(x_f)

        y_q = apply_rope_vec(x_q, position, cos_tbl, sin_tbl)
        y_ref = apply_rope_float(x_f, position, base)

        err = np.max(np.abs(q15_to_float(y_q) - y_ref))
        max_abs_err = max(max_abs_err, err)

    # Q1.15 LSB is 2^-15 ~= 3.05e-5. With rounding of two products + sat, expect
    # error on the order of a few LSBs per output (<< 1e-3).
    assert max_abs_err < 2e-3, f"accuracy regressed: {max_abs_err:.2e}"
    print(f"[PASS] Q1.15 golden model vs float reference: max_abs_err = {max_abs_err:.2e}")


# ---------------------------------------------------------------------------
# Test-vector generator (consumed by rope_engine_tb.sv)
# ---------------------------------------------------------------------------
def write_hex16(path, arr):
    with open(path, "w") as f:
        for v in arr.astype(np.int16):
            f.write(f"{(int(v) & 0xFFFF):04x}\n")


def gen_vectors(out_dir: str,
                head_dim: int = 128, max_seq_len: int = 2048,
                base: float = 10000.0, n_tests: int = 16,
                seed: int = 0, pairs_per_cycle: int = 4):
    os.makedirs(out_dir, exist_ok=True)
    cos_tbl, sin_tbl = compute_sincos_tables(head_dim, max_seq_len, base)
    n_pairs = head_dim // 2
    assert n_pairs % pairs_per_cycle == 0, \
        f"n_pairs ({n_pairs}) must be divisible by pairs_per_cycle ({pairs_per_cycle})"

    # 1a. Full-depth LUTs (legacy path / simple testbench).
    write_hex16(os.path.join(out_dir, "cos_lut.hex"), cos_tbl.flatten())
    write_hex16(os.path.join(out_dir, "sin_lut.hex"), sin_tbl.flatten())

    # 1b. Banked LUTs for synthesis.
    # Bank g contains pair indices {g, g+PPC, g+2*PPC, ...}. Within a bank,
    # entries are laid out row-major: position-major, local-pair-minor.
    #     local_pairs_per_bank = n_pairs / pairs_per_cycle
    #     bank_g[pos, lp] = cos_tbl[pos, g + lp*pairs_per_cycle]
    local_pairs = n_pairs // pairs_per_cycle
    for g in range(pairs_per_cycle):
        cos_bank = cos_tbl[:, g::pairs_per_cycle]  # (seq, local_pairs)
        sin_bank = sin_tbl[:, g::pairs_per_cycle]
        assert cos_bank.shape == (max_seq_len, local_pairs)
        write_hex16(os.path.join(out_dir, f"cos_lut_bank{g}.hex"), cos_bank.flatten())
        write_hex16(os.path.join(out_dir, f"sin_lut_bank{g}.hex"), sin_bank.flatten())

    # 2. Generate stimulus + expected streams.
    rng = np.random.default_rng(seed)
    stim, expected, positions = [], [], []

    # Deterministic edge cases
    edge_positions = [0, 1, 2, max_seq_len // 2, max_seq_len - 1]
    edge_vectors = [
        np.full(head_dim,  Q_MAX, dtype=np.int16),           # all max-positive
        np.full(head_dim,  Q_MIN, dtype=np.int16),           # all max-negative
        np.zeros(head_dim, dtype=np.int16),                  # all zero
        np.tile(np.array([Q_MAX, Q_MIN], dtype=np.int16), head_dim // 2),  # alternating
    ]
    for idx in range(n_tests):
        if idx < len(edge_vectors):
            x_q = edge_vectors[idx]
            pos = edge_positions[idx % len(edge_positions)]
        else:
            x_q = float_to_q15(rng.uniform(-0.85, 0.85, head_dim))
            pos = int(rng.integers(0, max_seq_len))
        y_q = apply_rope_vec(x_q, pos, cos_tbl, sin_tbl)
        stim.append(x_q); expected.append(y_q); positions.append(pos)

    # Flat streams: one int16 per line, all tests concatenated.
    write_hex16(os.path.join(out_dir, "stim.hex"),     np.concatenate(stim))
    write_hex16(os.path.join(out_dir, "expected.hex"), np.concatenate(expected))
    with open(os.path.join(out_dir, "positions.hex"), "w") as f:
        for p in positions:
            f.write(f"{p:04x}\n")

    meta = os.path.join(out_dir, "config.vh")
    with open(meta, "w") as f:
        f.write("// Auto-generated by rope_golden.py — do not edit\n")
        f.write(f"`define CFG_HEAD_DIM         {head_dim}\n")
        f.write(f"`define CFG_MAX_SEQ_LEN      {max_seq_len}\n")
        f.write(f"`define CFG_N_TESTS          {n_tests}\n")
        f.write(f"`define CFG_DATA_WIDTH       16\n")
        f.write(f"`define CFG_POS_WIDTH        16\n")
        f.write(f"`define CFG_PAIRS_PER_CYCLE  {pairs_per_cycle}\n")
        f.write(f"`define CFG_LOCAL_PAIRS      {local_pairs}\n")
    print(f"[OK] wrote {n_tests} tests to {out_dir}/")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gen-vectors", action="store_true")
    ap.add_argument("--out-dir", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "tb", "vectors"))
    ap.add_argument("--head-dim",    type=int, default=128)
    ap.add_argument("--max-seq-len", type=int, default=2048)
    ap.add_argument("--n-tests",     type=int, default=16)
    args = ap.parse_args()

    self_check()
    if args.gen_vectors:
        gen_vectors(args.out_dir,
                    head_dim=args.head_dim,
                    max_seq_len=args.max_seq_len,
                    n_tests=args.n_tests)


if __name__ == "__main__":
    sys.exit(main())
