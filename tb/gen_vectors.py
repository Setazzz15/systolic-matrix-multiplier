#!/usr/bin/env python3
"""Generate test vectors for tb_systolic_controller.sv.

NumPy is the reference model. For every job this script picks the operands,
computes the expected result with NumPy, and writes both to a .mem file that
the SystemVerilog testbench loads with $readmemh. The testbench drives the
RTL with the operands and compares every output word with the NumPy result.

One file per array size N:  <out>/vec_n<N>.mem
All values are 32-bit hex words, one per line.

File header (3 words):   N, K_MAX, NUM_TESTS
Then NUM_TESTS records, each:
    k_len                 terms per dot product, 1..K_MAX
    gap                   idle clocks before start (0 = start right after done)
    flags                 bit0: first try a start with an illegal k_len
                          bit1: pulse start again in the middle of the job
                          bit2: reset in the middle of the job, then run it again
    poke                  which clock of the job bit1/bit2 act on
    bad_k                 the illegal k_len used by bit0
    A[i][k]               N * K_MAX words, i outer, k inner
    B[k][j]               K_MAX * N words, k outer, j inner
    C[i][j]               N * N words, expected result, two's complement

A and B are always filled to K_MAX. Entries at k >= k_len are random and must
not affect the result: the expected C uses only the first k_len terms.

    C = A[:, :k_len] @ B[:k_len, :]        (int8 operands, int32 result)

Usage:  python gen_vectors.py [--seed 1] [--tests 200] [--sizes 1 2 3 4 8]
"""
import argparse
import pathlib

import numpy as np

FLAG_INVALID_START = 1
FLAG_POKE_START = 2
FLAG_RESET_ABORT = 4


def reference(a, b, k_len):
    """The reference model: a plain NumPy matrix product over the first k_len terms."""
    return a[:, :k_len].astype(np.int64) @ b[:k_len, :].astype(np.int64)


def directed_jobs(n, k_max):
    """Corner cases that random data is unlikely to hit. Returns (k_len, A, B) tuples."""
    jobs = []

    def full(value_a, value_b):
        return (np.full((n, k_max), value_a, dtype=np.int64),
                np.full((k_max, n), value_b, dtype=np.int64))

    # A true N x N by N x N product (k_len = N), with A = identity so C must equal B.
    k = min(n, k_max)
    a = np.zeros((n, k_max), dtype=np.int64)
    b = np.zeros((k_max, n), dtype=np.int64)
    a[:, :k] = np.eye(n, k, dtype=np.int64)
    b[:k, :] = np.arange(1, k * n + 1).reshape(k, n) - (k * n) // 2
    jobs.append((k, a, b))

    # A single term: the shortest legal job.
    a, b = full(-7, 9)
    jobs.append((1, a, b))

    # Longest job, largest positive sum: K_MAX * (-128 * -128).
    a, b = full(-128, -128)
    jobs.append((k_max, a, b))

    # Longest job, most negative sum: K_MAX * (-128 * 127).
    a, b = full(-128, 127)
    jobs.append((k_max, a, b))

    # Longest job, all +127.
    a, b = full(127, 127)
    jobs.append((k_max, a, b))

    # All zeros.
    a, b = full(0, 0)
    jobs.append((k_max, a, b))
    return jobs


def make_file(path, n, k_max, tests, rng):
    k_width = int(k_max).bit_length()            # same as $clog2(K_MAX + 1)
    illegal = [0] + list(range(k_max + 1, 2 ** k_width))
    directed = directed_jobs(n, k_max)
    words = [n, k_max, tests]
    flag_counts = {FLAG_INVALID_START: 0, FLAG_POKE_START: 0, FLAG_RESET_ABORT: 0}

    for t in range(tests):
        if t < len(directed):
            k_len, a, b = directed[t]
            gap, flags = 2, 0
        else:
            k_len = int(rng.integers(1, k_max + 1))
            a = rng.integers(-128, 128, size=(n, k_max), dtype=np.int64)
            b = rng.integers(-128, 128, size=(k_max, n), dtype=np.int64)
            gap = 0 if rng.random() < 0.5 else int(rng.integers(1, 6))
            flags = 0
            roll = rng.random()
            if roll < 0.10:
                flags |= FLAG_POKE_START
            elif roll < 0.20:
                flags |= FLAG_RESET_ABORT
            if rng.random() < 0.10:
                flags |= FLAG_INVALID_START
                gap = max(gap, 1)                # the illegal start needs an idle clock
        # A job is busy for k_len + 2N - 1 clocks. Act strictly inside that window.
        last_busy = k_len + 2 * n - 2
        poke = int(rng.integers(1, last_busy + 1)) if last_busy >= 1 else 0
        if poke == 0:
            flags &= ~(FLAG_POKE_START | FLAG_RESET_ABORT)
        bad_k = int(rng.choice(illegal))
        for f in flag_counts:
            flag_counts[f] += bool(flags & f)

        c = reference(a, b, k_len)
        assert np.all(np.abs(c) < 2 ** 31)
        words += [k_len, gap, flags, poke, bad_k]
        words += [int(v) for v in a.reshape(-1)]         # A[i][k], i outer
        words += [int(v) for v in b.reshape(-1)]         # B[k][j], k outer
        words += [int(v) for v in c.reshape(-1)]         # C[i][j], i outer

    with open(path, "w", newline="\n") as fh:
        fh.write("\n".join(f"{w & 0xFFFFFFFF:08x}" for w in words))
        fh.write("\n")
    return flag_counts


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--tests", type=int, default=200, help="jobs per array size")
    ap.add_argument("--kmax", type=int, default=75)
    ap.add_argument("--sizes", type=int, nargs="+", default=[1, 2, 3, 4, 8])
    ap.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent / "vectors"))
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    lines = [f"seed={args.seed} tests={args.tests} kmax={args.kmax} numpy={np.__version__}"]
    for n in args.sizes:
        counts = make_file(out / f"vec_n{n}.mem", n, args.kmax, args.tests, rng)
        lines.append(f"N={n}: {args.tests} jobs, illegal-start={counts[FLAG_INVALID_START]} "
                     f"start-while-busy={counts[FLAG_POKE_START]} reset-mid-job={counts[FLAG_RESET_ABORT]}")
    (out / "manifest.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"wrote {len(args.sizes)} files to {out}")


if __name__ == "__main__":
    main()
