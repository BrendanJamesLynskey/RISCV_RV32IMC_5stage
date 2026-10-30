# Finite fields: CRCs, LFSRs and GF(2⁸)

CRCs, linear-feedback shift registers, Reed–Solomon codes and AES's MixColumns are all arithmetic on
polynomials with coefficients in GF(2), reduced modulo a fixed polynomial. Adding two of them is an XOR, and
multiplying them is a carry-less multiply. BRV32P already has the carry-less multiply: Zbkc's `clmul` and
`clmulh` ([crypto_extensions.md](crypto_extensions.md), step 3). This part measures how far that goes on its
own, and then adds a custom instruction for the case it does not cover well: many small multiplies in GF(2⁸).

| Step | What | Status |
|---|---|---|
| 1 | GF(2) in software with Zbkc: three more CRCs, an LFSR random-number generator and its jump ahead | **done** |
| 2 | A custom packed GF(2⁸) multiply, four byte lanes, the reduction polynomial programmable (part of Xbrvdsp) | **done** |
| 3 | Reed–Solomon (syndromes, Chien search) and AES InvMixColumns with it, against exp/log tables and packed C | **done** |

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

As measured at step 1 (the README's table is from the latest build). 256 bytes for each CRC, and 64 words (256 bytes) for each generator; warm caches. Every result is checked
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

## Step 2: a packed GF(2⁸) multiply

Carry-less multiply suits one wide polynomial. GF(2⁸), the field of Reed–Solomon codes, AES, QR codes and
RAID-6, needs the opposite: many independent byte products, each reduced modulo a degree-8 polynomial. One
`clmul` cannot do four of them, because their 15-bit products would overlap. Software uses exp/log tables
(a·b = exp[log a + log b]), which cost two or three dependent loads and a test for zero per product. Xbrvdsp
adds one instruction that does four, plus the two that set and read the field.

| Instruction | funct7 | funct3 | Operation |
|---|---|---|---|
| `gfmul4 rd, rs1, rs2` | 0000000 | 101 | each byte lane: rd[i] = rs1[i] · rs2[i] in GF(2⁸), modulo x⁸ + poly |
| `gf.cfg rs1` | 0000001 | 101 | poly = rs1[7:0] (rd and rs2 zero) |
| `gf.rd rd` | 0000010 | 101 | rd = poly (rs1 and rs2 zero): with `gf.cfg`, saves and restores the state |

All are custom-0 (opcode 0001011). `poly` is the field polynomial less its x⁸ term. It resets to 0x1D
(x⁸ + x⁴ + x³ + x² + 1, the usual Reed–Solomon field); AES's is 0x1B. Any value gives a well-defined product,
but only an irreducible polynomial gives a field. A register, not a fixed polynomial, because the
applications disagree: a fixed one would serve AES or Reed–Solomon, not both.

### Micro-architecture

`rtl/core/gf_unit.v`, combinational in EX like `zk_unit.v`. Each lane forms the 15-bit carry-less product of its
two bytes, an AND-XOR array. The seven bits above x⁷ are then folded back, each XORing in x⁸⁺ʲ mod P for j = 0..6.
Those seven bytes depend only on `poly`, so they come from the register, not from the operands, and stay off
the forwarding path. `gf.cfg` writes `poly` at the EX-to-MEM edge under the same condition as a MAC's update of
`acc`: not while the pipeline is held, and not if the instruction is flushed. So the `gfmul4` straight after it
already uses the new field, and a `gf.cfg` killed by a trap never takes effect.

### Cost

`gf_unit` is 186 LUTs and 8 registers. The design went from 10,669 to 11,077 LUTs; the rest is the wider result
select and placement noise. Fmax was 65.3 MHz (64.1 before), and the worst path was still fetch. The unit is
not on it.

### Verification

`tests/directed/gf.S` covers:
- the reset value;
- products in the Reed–Solomon field and in AES's (FIPS-197's 0x57 · 0x83 = 0xC1 and 0x57 · 0x13 = 0xFE), and
  an inverse pair (0x53 · 0xCA = 1);
- a `gf.cfg` immediately followed by the `gfmul4` that depends on it;
- `gf.cfg` keeping only rs1[7:0];
- all-ones operands, a zero operand, and a polynomial with bit 7 set;
- a dependent chain (forwarding);
- a `gf.cfg` behind a load that traps, which must leave `poly` unchanged.

The expected values come from a bit-serial multiply in Python. The run is also compared in lockstep with
Spike, whose model (`tools/spike_xbrvdsp/xbrvdsp.cc`) computes each lane bit-serially, not as the RTL does.
A mutant that lets a flushed `gf.cfg` update `poly` fails the trap case.

## Step 3: Reed–Solomon and InvMixColumns

RS(255,223) over 0x11D, as in CCSDS and many storage codes: 223 data bytes and 32 check bytes, correcting up to 16
byte errors. `gen_data.py` builds the test:
1. it encodes a codeword and checks that its syndromes are zero;
2. it makes 16 byte errors, and computes the received word's 32 syndromes;
3. it finds the error locator Λ(x), degree 16, by Berlekamp–Massey;
4. it checks that the Chien search finds exactly the 16 positions it corrupted.

The benchmark times the two kernels that run on every received word, or every corrupted one: the syndromes
and the Chien search. Berlekamp–Massey runs once per corrupted word on 32 bytes, and is left in Python.

- **Syndromes:** S_j = r(α^j) for j = 0..31, by Horner's rule over the 255 bytes: s ← s·α^j ⊕ r_k.
  - The table C does one syndrome at a time, with s·α^j = exp[log s + j] when s is non-zero.
  - With `gfmul4`, each of eight words holds four syndromes and is multiplied by (α^j..α^(j+3)) in one
    instruction. The byte is copied to all four lanes (a multiply by 0x01010101) and XORed in.
- **Chien search:** evaluate Λ at α^i for i = 1..255; an error at byte k makes Λ(α^(k+1)) = 0.
  - The table C keeps each term λ_m·α^(m·i) as a log that steps by m.
  - With `gfmul4`, the 16 terms sit in four words, each multiplied by (α^m..α^(m+3)) per point; the four words
    and their four lanes are XORed together.
- **InvMixColumns** (AES decryption, and the equivalent decryption key schedule). Each output byte is
  14·a_i ⊕ 11·a_(i+1) ⊕ 13·a_(i+2) ⊕ 9·a_(i+3).
  - The C is the fast constant-time form: it multiplies the column by 4 first, which leaves a MixColumns, with
    `xtime` done on four bytes at once.
  - With `gfmul4` it is FIPS-197's matrix directly: four `gfmul4` (by 0x0E, 0x0B, 0x0D and 0x09 in every lane),
    three rotates (Zbkb) and three XORs per column.
  - Zknd has no InvMixColumns on its own on RV32; its `aes32dsmi` includes it, with the inverse S-box.

| Kernel (warm caches) | Cycles | Per unit | |
|---|---|---|---|
| RS syndromes, exp/log tables | 90,783 | 356 per byte | a load-use bubble per product (8,097 cycles) |
| **RS syndromes, `gfmul4`** | **6,259** | **24.5 per byte** | **14.5×**: 32 products in 8 instructions |
| Chien search, exp/log tables | 50,941 | 200 per point | load-use bubbles and the term's mod-255 test |
| **Chien search, `gfmul4`** | **4,514** | **17.7 per point** | **11.3×** |
| InvMixColumns, packed C | 3,247 | 12.7 per byte | |
| **InvMixColumns, `gfmul4`** | **1,130** | **4.4 per byte** | **2.9×** |

The Reed–Solomon kernels gain most, because exp/log tables are the only software option for general products,
and each product costs dependent loads. InvMixColumns gains less, because its constants allow the packed `xtime`
trick, already constant-time, which `gfmul4` replaces with four instructions.

### Timing against the data

The table syndromes test each value for zero (log 0 is undefined), so their time depends on the data. The
benchmark runs both versions on two received words: the first, and a second from an all-zero message with 16
other errors. It uses `timed()` in `dsp.c` (the same check as for AES; [crypto_extensions.md](crypto_extensions.md),
step 4):

| | received word 1 | received word 2 |
|---|---|---|
| syndromes, exp/log tables | 89,847 cycles | 88,489 cycles |
| syndromes, `gfmul4` | **6,221** | **6,221** |

`bench_report.py` fails if the `gfmul4` times ever differ.
