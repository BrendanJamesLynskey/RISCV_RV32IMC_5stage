# Scalar cryptography: Zbkb and Zknh

BRV32P implements part of the **ratified** RISC-V scalar cryptography extensions (Zk), unlike Xbrvdsp, which is
custom. The standard encodings bring three benefits:
- GCC already emits them (`-march=..._zbkb_zknh`), and has builtins for the SHA-2 instructions;
- Spike already implements them, so the lockstep check needs no model of ours;
- they are the same instructions other cores implement, so programs and results are comparable.

| Step | Extensions | Status |
|---|---|---|
| 1 | **Zbkb** (bit manipulation for cryptography) and **Zknh** (SHA-256 and SHA-512) | **done** |
| 2 | Zkne/Zknd (AES rounds, `aes32*`) | planned |
| 3 | Zbkc (carry-less multiply) and Zbkx (crossbar permutations) | planned |
| 4 | Zkt (data-independent timing): check that these instructions' cycle counts do not depend on the data | planned |

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
