# Scalar cryptography: Zbkb, Zbkc, Zbkx, Zknh, Zkne and Zknd

BRV32P implements part of the **ratified** RISC-V scalar cryptography extensions (Zk), unlike Xbrvdsp, which is
custom. The standard encodings bring three benefits:
- GCC already emits them (`-march=..._zbkb_zknh`), and has builtins for the SHA-2 instructions;
- Spike already implements them, so the lockstep check needs no model of ours;
- they are the same instructions other cores implement, so programs and results are comparable.

| Step | Extensions | Status |
|---|---|---|
| 1 | **Zbkb** (bit manipulation for cryptography) and **Zknh** (SHA-256 and SHA-512) | **done** |
| 2 | **Zkne** and **Zknd** (AES rounds, `aes32*`) | **done** |
| 3 | **Zbkc** (carry-less multiply) and **Zbkx** (crossbar permutations) | **done** |
| 4 | Zkt (data-independent timing): a measured check that AES with these instructions takes the same cycles whatever the key and data | **done** |

## Step 1: Zbkb and Zknh

| Instruction | Operation (RV32) |
|---|---|
| `ror`, `rol`, `rori` | rotate right/left by rs2[4:0] or an immediate |
| `andn`, `orn`, `xnor` | rs1 & ~rs2, rs1 \| ~rs2, ~(rs1 ^ rs2) |
| `pack`, `packh` | {rs2[15:0], rs1[15:0]}; {16'b0, rs2[7:0], rs1[7:0]} |
| `brev8`, `rev8` | reverse the bits in each byte; reverse the bytes |
| `zip`, `unzip` | interleave the two halves bit by bit (bit 2i = rs1[i], bit 2i+1 = rs1[i+16]), and the inverse |
| `sha256sig0`, `sha256sig1`, `sha256sum0`, `sha256sum1` | SHA-256's σ0, σ1, Σ0, Σ1 of rs1 |
| `sha512sig0l/h`, `sha512sig1l/h`, `sha512sum0r`, `sha512sum1r` | SHA-512's σ and Σ functions, on a 64-bit word held as two 32-bit halves (rs1, rs2) |

### Implementation

`rtl/core/zk_unit.v` computes all 22 in one cycle in EX, from the forwarded operands. It holds no state, and is
fixed wiring (rotations by constants, bit permutations) plus XORs, except the rotates by a register, which are
barrel shifts. The decoder recognises the encodings, which sit in the OP and OP-IMM major opcodes alongside the
base instructions. The result reaches EX's result through the write-back select the DSP unit uses.

### Cost

About 730 LUTs (the whole design went from 8,886 to 9,613), with no registers and no change to the worst path
(67.4 MHz in that run). The first version had separate rotators for `ror` and `rol` and cost about 1,140.
Rotating left by n is rotating right by (32 − n) mod 32, so one rotator serves both. Vivado merges this purely
combinational unit into its neighbours, so the hierarchy report does not show it on its own. The number is the
change in the total.

### Verification

`tests/directed/zk.S` runs every instruction on the same operands:
- the expected values were computed in Python from the specification's formulas;
- the run is compared with Spike's own implementation in lockstep (Spike runs with `--isa=..._zbkb_zknh`);
- each result is used by the very next instruction (forwarding);
- `zip`/`unzip`, `brev8` and `rev8` are checked as their own inverses;
- rotates by 0 and 31, and a rotate by 33, of which only rs2[4:0] counts.

### SHA-256 benchmark

The same C source (`tests/bench/sha256_impl.h`) is built twice:
- `sha256.c`, plain RV32IMC, with the σ/Σ functions written as rotates and shifts;
- `sha256_zk.c`, built with `zbkb_zknh`, using GCC's `__builtin_riscv_sha256*` for σ/Σ. GCC also turns the
  remaining rotates into `rori`, and one `~e & g` into `andn`.

The plain kernels stay plain: only `sha256_zk.c` is compiled with the extensions. The test message is 256 bytes
(four blocks, then a fifth for the padding), and the digest is checked against Python's `hashlib`.

| Kernel (warm caches) | Cycles | Per byte | IPC |
|---|---|---|---|
| SHA-256, plain RV32IMC | 26,269 | 102.6 | 0.98 |
| **SHA-256, Zbkb + Zknh** | **14,336** | **56.0** (1.83×) | 0.97 |

In plain RV32 each σ or Σ function is 9 to 11 instructions: two or three rotates at three each (two shifts and
an OR), σ's extra shift, and the XORs. With Zknh each is one instruction. The rest of a round is unchanged, which
bounds the gain: the additions, Ch and Maj, and the message schedule's loads and stores. The big-endian word
loads are four byte loads and shifts in both builds.

## Step 2: Zkne and Zknd (AES)

| Instruction | Operation (RV32; bs = 0–3, an immediate in bits 31:30) |
|---|---|
| `aes32esi rd, rs1, rs2, bs` | rd = rs1 ^ rol(SubBytes(rs2.byte[bs]), 8·bs): a final encryption round |
| `aes32esmi rd, rs1, rs2, bs` | the same with that byte's column of MixColumns, (2s, s, s, 3s): a middle round |
| `aes32dsi`, `aes32dsmi` | the same with the inverse S-box, and InvMixColumns' column (14, 9, 13, 11) |

Each instruction does one state byte's work for a round:
- its S-box;
- its contribution to a MixColumns column;
- the XOR into the new column.

So a round is 16 instructions on four 32-bit column words, and ShiftRows costs nothing: it is the choice of
which word each byte comes from. In `zk_unit.v` these are a forward and an inverse S-box (256-entry case tables,
generated from the S-box's definition), multiplications by constants in GF(2⁸) (xtime chains), the rotate by
bs, and an XOR.

Tests (`tests/directed/zk.S`): each of the four instructions with each byte select. The expected values come
from a Python model, and the run is compared with Spike in lockstep. GCC 13's `__builtin_riscv_aes32*` reject
the byte-select operand, so the benchmark uses inline asm.

### AES-128 benchmark

Encryption of 256 bytes (16 blocks, ECB) with expanded round keys. The expected ciphertext comes from a Python
AES that is first checked against the FIPS-197 example (69c4e0d8…c55a).

| Kernel (warm caches) | Cycles | Per byte | Main loss |
|---|---|---|---|
| AES-128, byte-oriented C (FIPS-197's form: S-box table, ShiftRows, xtime) | 102,864 | 401.8 | mispredicts 4,590, load-use 2,561 |
| AES-128, one 1 KB T-table C (the usual fast software form) | 23,775 | 92.9 | D-cache waits 3,965 |
| **AES-128, Zkne (`aes32esmi`/`aes32esi`)** | **5,031** | **19.7** | — (IPC 0.97) |

Zkne is 4.7× the T-table code and 20× the byte-oriented code. The T-table version is the fair comparison. Four
1 KB tables would save its rotates but not fit the 2 KB D-cache, and even the single table conflicts in it.
Its loads also depend on the key and data, which is the cache-timing leak AES instructions remove. The
instruction version reads only the state, the round keys and the input, at addresses that do not depend on the
data.

Cost: 489 LUTs (the design went from 9,613 to 10,102) for the two S-boxes, the constant multiplies and the
selection. There are no registers. The worst path is unchanged in kind: the next-PC loop, at 65.3 MHz in that run.

## Step 3: Zbkc and Zbkx

| Instruction | Operation (RV32) |
|---|---|
| `clmul rd, rs1, rs2` | the low word of the carry-less (GF(2)[x]) product of rs1 and rs2 |
| `clmulh rd, rs1, rs2` | the high word of it |
| `xperm4 rd, rs1, rs2` | each nibble of rs2 selects a nibble of rs1 (an index past 7 gives 0) |
| `xperm8 rd, rs1, rs2` | each byte of rs2 selects a byte of rs1 (an index past 3 gives 0) |

`zk_unit.v` forms the full 63-bit carry-less product as an AND-XOR array, in one cycle; `clmul` and `clmulh` take
its halves. `xperm4` and `xperm8` are multiplexers. Tests (`zk.S`) cover:
- products of all-ones operands, and of the end bits (bits 0 and 31), which reach bit 62;
- permutes with in-range indexes, out-of-range indexes and a mix.

All are checked against Python and against Spike.

### CRC-32 benchmark

zlib's CRC-32 of 256 bytes. The plain C is the usual table-driven form: one 1 KB table, one lookup per byte.
With Zbkc it goes a word at a time, by Barrett reduction (2 carry-less multiplies and an XOR per word).
The CRC is bit-reflected and Zbkc has no reflected multiply, so the kernel works in the normal domain. Each
little-endian word is bit-reversed with Zbkb's `rev8` and `brev8`, and then

  x = crc ⊕ w,  q = clmulh(x, μ) ⊕ x,  crc = clmul(q, P)

with P = 0x04C11DB7 and μ = ⌊x⁶⁴ / P(x)⌋ = 0x1_04D101DF (`clmulh` takes its low word; the ⊕ x adds its x³²
term). `gen_data.py` checks this formula against `zlib.crc32` before the benchmark is built.

| Kernel (warm caches) | Cycles | Per byte |
|---|---|---|
| CRC-32, table-driven C | 2,834 | 11.1 (a load-use bubble per byte) |
| **CRC-32, Zbkc** | **681** | **2.66** (4.2×) |

Its inner loop is 10 instructions per 4 bytes, about 10.6 cycles:
- the load, `rev8` and `brev8`;
- an XOR, `clmulh`, another XOR and `clmul`;
- two increments and the branch.

It needs no table, so it keeps no 1 KB of data in the D-cache.

Cost: 567 LUTs (10,102 → 10,669), almost all of it the 32×32 AND-XOR array. The worst path was fetch, at 64.1 MHz.

## Step 4: timing against the data (Zkt)

Zkt is a promise about latency. It says that the listed instructions take a time that does not depend on their
operands:
- the Zbkb, Zbkc and Zbkx instructions, and the AES and SHA ones;
- the base ALU instructions, and the multiply.

In BRV32P each of these is one cycle in EX, or two for a multiply in MEM. None of them has an early exit, a
data-dependent stall or a shortcut. The divider (not in Zkt's list) always takes 32 steps.

The benchmark checks the consequence end to end. It runs the AES kernels, warm, on two different keys and
plaintexts through the very same call, so that only the data differs:

| AES-128, 256 bytes (warm caches) | key and plaintext 1 | key and plaintext 2 |
|---|---|---|
| one-table T-table C | 21,079 cycles | 24,044 cycles (D-cache waits 1,287 against 4,264) |
| Zkne | **5,013** | **5,013** |

**The harness, corrected.** That first check called each kernel through one call site, but reached it by
different paths through `main` for the two inputs. Adding the finite-field kernels
([finite_fields.md](finite_fields.md)) moved the code, and the Zkne runs then took 5,014 and 5,016 cycles: two
more mispredicts on the second key, from branch-predictor state left by the harness, not from the data. A
second attempt still differed, by one I-cache miss: GCC unrolls the cold-then-warm loop, so the first warm run
fetched the warm path's code for the first time. The check now goes through `timed()` in `dsp.c`:
- it copies each input (and round keys) into the same buffers;
- it runs the kernel cold, then warm between one marker pair;
- it is called once on the second input as a warm-up, then on each input.

The two measured calls of one kernel follow exactly the same path and touch the same addresses, so only the
data differs. With it (latest build):

| 256 bytes, warm caches | input 1 | input 2 |
|---|---|---|
| AES-128, one-table T-table C | 20,836 cycles | 20,979 cycles |
| **AES-128, Zkne** | **5,018** | **5,018** |
| Reed–Solomon syndromes, exp/log tables | 89,847 | 88,489 |
| **Reed–Solomon syndromes, `gfmul4`** | **6,221** | **6,221** |

The T-table gap is smaller than before, because the copies put the plaintexts and keys at the same addresses;
what remains comes from the table lookups. The log-table syndromes branch on a zero value, which the mostly
zero second word hits more often. `gfmul4` is Xbrvdsp's, not Zkt's, but it is one cycle with no shortcut, like
the instructions Zkt lists.

The T-table version's loads go to addresses chosen by the key and the data. So its D-cache conflicts, and
its time, depend on them. That is the cache-timing channel AES instructions exist to close. The Zkne version
loads only the input, the round keys and the output, at fixed addresses, and runs in exactly the same number of
cycles. `bench_report.py` checks the equality on every benchmark run, including in CI, and fails if it breaks.

This is one kernel and two inputs, not a proof. A fuller check would vary the inputs widely and cover every Zkt
instruction in isolation; the pipeline trace makes both straightforward.
