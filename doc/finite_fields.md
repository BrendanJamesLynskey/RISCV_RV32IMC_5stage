# Finite fields: CRCs, LFSRs and GF(2⁸)

CRCs, linear-feedback shift registers, Reed–Solomon codes and AES's MixColumns are all arithmetic on
polynomials with coefficients in GF(2), reduced modulo a fixed polynomial. Adding two of them is an XOR, and
multiplying them is a carry-less multiply. BRV32P already has the carry-less multiply: Zbkc's `clmul` and
`clmulh` ([crypto_extensions.md](crypto_extensions.md), step 3). This part measures how far that goes on its
own, and then adds a custom instruction for the case it does not cover well: many small multiplies in GF(2⁸).

| Step | What | Status |
|---|---|---|
| 1 | GF(2) in software with Zbkc: three more CRCs, an LFSR random-number generator and its jump ahead | **done** |
| 2 | A custom packed GF(2⁸) multiply, four byte lanes, the reduction polynomial programmable | planned |
| 3 | Reed–Solomon (syndromes, Chien search) and AES MixColumns with it, against log/antilog tables | planned |

## One formula

Every kernel in step 1 is the same reduction. For a 32-bit word x (a polynomial of degree below 32), the
remainder of x·x³² modulo a degree-32 polynomial P is

  q = clmulh(x, μ) ⊕ x,  x·x³² mod P = clmul(q, P)

where P and μ = ⌊x⁶⁴ / P⌋ are both written without their x³² term (the ⊕ x puts μ's back). This is Barrett
reduction. Over GF(2) it is exact, because there are no carries to correct: q is exactly the quotient. Each
kernel is two carry-less multiplies and an XOR per 32 bits, plus whatever the data needs.

- **A CRC** feeds in a 32-bit chunk w of the message each time: crc ← (crc ⊕ w)·x³² mod P.
- **An LFSR** is the same with no data: 32 steps of a Galois LFSR multiply the state by x³² mod P.
- **A general product** a·b mod P is `clmul` and `clmulh` for the 64-bit product, then the reduction of its high
  word, XORed with its low word: six instructions.

### Any CRC up to 32 bits

A CRC of degree n below 32 uses the same loop with P′ = P·x³²⁻ⁿ, keeping the CRC left-aligned in the word:

  (C ⊕ w)·x³² mod P′ = x³²⁻ⁿ·((c·x³²⁻ⁿ ⊕ w)·xⁿ mod P),  where C = c·x³²⁻ⁿ

so the result is the next CRC, shifted up by 32 − n, and the final CRC is C shifted back down. Only P′ and μ
change between CRCs. `gen_data.py` derives them and checks the formula against a bitwise model of each CRC,
itself checked against the CRC's published check value (the CRC of `123456789`).

| CRC | P′ | μ | Reflected? |
|---|---|---|---|
| CRC-32 (zlib, Ethernet) | 0x04C11DB7 | 0x04D101DF | yes |
| CRC-32C (Castagnoli: iSCSI, ext4) | 0x1EDC6F41 | 0x1F91CAF6 | yes |
| CRC-16/XMODEM (CCITT polynomial) | 0x10210000 | 0x11303471 | no |
| CRC-8/SMBUS | 0x07000000 | 0x07156A16 | no |

Reflected CRCs process each byte from its least significant bit. Zbkc has no reflected multiply (Zbc's `clmulr`
is not in Zbkc), so the kernel bit-reverses each little-endian word with `rev8` and `brev8`, and the result at
the end. The others take each word big-endian, with `rev8` alone.

### The LFSR

The generator is a 32-bit Galois LFSR with P = x³² + x²² + x² + x + 1. `gen_data.py` checks that P is
primitive: x has order 2³² − 1 modulo P, so every non-zero state is visited before the sequence repeats. One
step is s ← s·x mod P: shift left, and XOR in P if a 1 fell off the top. Each output word is the state 32 steps
on, and is computed three ways:
- **a step at a time:** 32 iterations of shift, test and XOR;
- **a byte at a time:** s ← (s ≪ 8) ⊕ T[s ≫ 24], where T[b] = b·x³² mod P (a 1 KB table, as for a CRC);
- **32 steps at once:** the reduction above, two carry-less multiplies and an XOR.

An LFSR is not a cryptographic generator. Its output is linear: 64 consecutive output bits are enough for the
Berlekamp–Massey algorithm to recover P and the state. It is used where speed, reproducibility and a known
period matter, as in built-in self-test, scramblers, spreading codes and simulation.

### Jump ahead

Linearity has a useful side. The state N steps on is s·x^N mod P, so a generator can skip ahead without
stepping. x^N comes from square and multiply, about 2·log₂N products. This splits one sequence into
non-overlapping streams, one per core or per simulation run, each starting a fixed distance apart. zlib's
`crc32_combine`, which joins the CRCs of two blocks, is the same computation.

## Step 1 results

256 bytes for each CRC, and 64 words (256 bytes) for each generator; warm caches. Every result is checked
against `gen_data.py`'s, and the run against Spike in lockstep.

| Kernel | Cycles | Per unit | Data |
|---|---|---|---|
| CRC-32, a bit at a time, no table | 16,159 | 63.1 per byte | none |
| CRC-32, table-driven | 2,834 | 11.1 per byte | 1 KB |
| **CRC-32, Zbkc** | **681** | **2.66 per byte** | none |
| CRC-32C, table-driven | 2,863 | 11.2 per byte | 1 KB |
| **CRC-32C, Zbkc** | **682** | **2.66 per byte** | none |
| CRC-16/XMODEM, table-driven | 2,851 | 11.1 per byte | 512 B |
| **CRC-16, Zbkc** (the shared routine) | **644** | **2.52 per byte** | none |
| CRC-8/SMBUS, table-driven | 1,569 | 6.1 per byte | 256 B |
| **CRC-8, Zbkc** (the shared routine) | **630** | **2.46 per byte** | none |
| LFSR, a step at a time | 12,718 | 198.7 per word | none |
| LFSR, a byte at a time | 2,656 | 41.5 per word | 1 KB |
| **LFSR, Zbkc** | **432** | **6.75 per word** | none |
| xorshift32 (for comparison) | 607 | 9.48 per word | none |
| LFSR jump ahead 10⁶ steps, plain C | 9,861 | | none |
| **LFSR jump ahead 10⁶ steps, Zbkc** | **289** | | none |

What the numbers show:
- **One CRC loop serves every polynomial.** The two MSB-first CRCs share one routine, with P′, μ and n passed in;
  its loop is eight instructions per word (load, `rev8`, three for the reduction, the XOR, the increments
  and the branch). Tables cost a load-use bubble or more per byte and their memory, which grows with the CRC's
  width. The CRC-8 table is the cheapest because it needs no shift: one load and one XOR per byte. Even so,
  Zbkc is 2.5× faster.
- **The LFSR's 32 steps cost what one CRC word does.** That is 29× faster than stepping and 6× faster than the
  table. It also beats xorshift32, whose three shifts and three XORs per word are the usual fast software
  generator. `lfsr_table`'s inner loop starts at 2 mod 4 (`-falign-loops` aligned the outer loop), so it pays a
  straddle fetch per byte: 192 of its 2,656 cycles.
- **The jump ahead is 34× faster.** Each product in plain C is a 32-iteration shift-and-XOR loop; with Zbkc it is
  six instructions. For scale, stepping 10⁶ times would take about 6.2 million cycles a step at a time, or
  about 211,000 with the Zbkc kernel at 32 steps per iteration. The jump takes 289.

The extra kernels and tables pushed the benchmark program past the SoC's 32 KB of SRAM. `run_bench.sh` now
simulates 64 KB (the SRAM's depth is a parameter of `tb_isa.v`) and gives Spike the same. The ISA tests still run
in 32 KB. Moving the data shifted the memory-bound kernels by a few percent (the README's table is from the
latest build).
