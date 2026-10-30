# Xbrvdsp: the DSP extension

Xbrvdsp is BRV32P's own instruction-set extension for signal processing. It is built in steps, each measured on
the DSP benchmarks (`tests/bench`) and checked in lockstep against a Spike model of the extension. The ideas are
the standard DSP repertoire (a multiply-accumulate into a wide accumulator, address generators, a zero-overhead
loop), as surveyed in Zhang Zhiwei's *RISC-V Architecture and DSP Processor Design*; the encodings are this
project's own.

| Step | Adds | Status |
|---|---|---|
| 1 | Multiply-accumulate: `mac`, `dmac`, `msu`, accumulator access | **done** |
| 2 | Address generators: loads that step a pointer register (bit-reversed addressing comes with the FFT, step 5) | **done** |
| 3 | Two taps per `dmac` in the FIR, from aligned word loads (software only: no new hardware was needed) | **done** |
| 4 | Hardware loop: the loop-back folded into the body's last instruction (`dmac.lp`, `lp.end`) | **done** |
| 5a | Saturating add and subtract; biquad IIR and saturating-mix benchmarks | **done** |
| 5b | Bit-reversed addressing; radix-2 FFT benchmark | **done** |

## Step 1: the multiply-accumulate unit

### State

`acc`: a 40-bit signed accumulator, 8 guard bits over a 32-bit sum of products, so 256 full-scale Q15 products
can be summed without overflow. It is reset to 0. Arithmetic on it wraps at 40 bits.

### Instructions

All use the custom-0 major opcode (`0001011`) in the R-type format.

| Instruction | funct7 | funct3 | Fields | Operation |
|---|---|---|---|---|
| `mac rs1, rs2` | 0000000 | 000 | rd = 0 | acc += lo(rs1) × lo(rs2) |
| `dmac rs1, rs2` | 0000001 | 000 | rd = 0 | acc += lo(rs1) × lo(rs2) + hi(rs1) × hi(rs2) |
| `msu rs1, rs2` | 0000010 | 000 | rd = 0 | acc −= lo(rs1) × lo(rs2) |
| `acc.set rs1` | 0000100 | 000 | rd = 0, rs2 = 0 | acc = sext(rs1) |
| `acc.seth rs1` | 0000101 | 000 | rd = 0, rs2 = 0 | acc[39:32] = rs1[7:0] |
| `acc.rd rd, sh` | 0000000 | 001 | rs1 = 0; sh in the rs2 field | rd = sat32((acc + r) >> sh) |
| `acc.rdh rd, sh` | 0000000 | 010 | rs1 = 0; sh in the rs2 field | rd = sat16((acc + r) >> sh), sign-extended |
| `acc.rdl rd` | 0000000 | 011 | rs1 = rs2 = 0 | rd = acc[31:0] |
| `acc.rdx rd` | 0000001 | 011 | rs1 = rs2 = 0 | rd = sext(acc[39:32]) |

lo and hi are the signed 16-bit halves of a register. The products are exact (32 bits). r is the rounding
constant 2^(sh−1), or 0 when sh is 0: round half up, then an arithmetic shift. sat32 and sat16 clamp to the
signed range. Any other encoding in custom-0 is an illegal instruction.

`acc.rdh rd, 15` is the usual end of a Q15 filter tap sum: the shift, rounding and saturation take one
instruction. `acc.rdl` and `acc.rdx` read all 40 bits exactly, and `acc.set` then `acc.seth` restore them, which is
how a context switch saves the accumulator.

From C, the instructions are reached with `.insn` in inline asm (binutils supports it; no compiler change):

```c
static inline void mac(int32_t a, int32_t b)
{
  __asm__ volatile (".insn r CUSTOM_0, 0, 0, x0, %0, %1" :: "r" (a), "r" (b));
}
```

### Micro-architecture

`rtl/core/dsp_unit.v` holds `acc`, two 16×16 signed multipliers (one for `mac` and `msu`, both for `dmac`) and
the read path (round, shift, saturate). It sits in EX beside the ALU and takes the forwarded operands.

- **acc changes as the instruction moves from EX to MEM**, and only then: not while the pipeline is held, and not
  if a trap flushes the instruction in EX. An interrupt is taken at the instruction in EX and an exception in MEM
  flushes EX, so a squashed MAC never touches acc and interrupts stay precise.
- **Reads of acc happen in EX**, after every older MAC has updated it, so back-to-back MACs and an `acc.rd`
  straight after a MAC need no forwarding.
- **No CSRs for acc.** A CSR instruction acts in MEM, while a younger MAC in EX updates acc at the same clock
  edge, so the MAC would add to the value from before the write. Instructions that act in EX keep every access
  to acc in program order with no extra logic.
- The decoder accepts the encodings above; `acc.rd`, `acc.rdh`, `acc.rdl` and `acc.rdx` write rd through a new
  write-back select (`WB_DSP`).

### Verification

- `tools/spike_xbrvdsp/xbrvdsp.cc` is a Spike model of the extension, loaded with
  `spike --extlib=libxbrvdsp.so --extension=xbrvdsp`. `run_isa.sh` and `run_bench.sh` use it, so every program
  that uses the extension is compared with Spike instruction by instruction, including each value read from acc.
- `tests/directed/dsp_mac.S` covers every instruction, with:
  - rounding and both saturations;
  - sums beyond 32 bits, and a sum that wraps at 40 bits;
  - exact 40-bit readback, and a save and restore;
  - operands arriving by forwarding and after a load-use bubble;
  - back-to-back MACs.
- The DSP benchmarks check their results against Python-computed values, and run in lockstep with Spike.

## Step 2: address generators

### State

Four address registers, `ar0`–`ar3`. Each holds a 32-bit address and a signed 16-bit stride in bytes. Both
reset to 0.

### Instructions

All use the custom-1 major opcode (`0101011`). N is the register number, 0–3.

| Instruction | Format | Fields | Operation |
|---|---|---|---|
| `ar.set arN, rs1` | R | funct3 000, funct7 0000000, rd = N, rs2 = 0 | addr = rs1 |
| `ar.cfg arN, rs1` | R | funct3 000, funct7 0000001, rd = N, rs2 = 0 | stride = rs1[15:0] |
| `lh.a rd, arN` | I | funct3 001, rs1 = 0, imm = N | rd = sext(mem16[addr]); addr += stride |
| `lw.a rd, arN` | I | funct3 010, rs1 = 0, imm = N | rd = mem32[addr]; addr += stride |
| `lhu.a rd, arN` | I | funct3 101, rs1 = 0, imm = N | rd = zext(mem16[addr]); addr += stride |
| `ar.mode arN, rs1` | R | funct3 000, funct7 0000011, rd = N, rs2 = 0 | bit-reversed mode = rs1[0] (step 5b) |
| `ar.rd rd, arN` | I | funct3 011, rs1 = 0, imm = N | rd = addr |
| `ar.rds rd, arN` | I | funct3 011, rs1 = 0, imm = N + 4 | rd = sext(stride) |
| `ar.rdm rd, arN` | I | funct3 011, rs1 = 0, imm = N + 12 | rd = bit-reversed mode (step 5b) |

The load funct3 values are the base ISA's (`lh`, `lw`, `lhu`), so the decoder reuses the width and sign fields.
A misaligned access traps like a base load (mcause 4, mtval = the address) and leaves the address register
unchanged, so the load runs correctly again after the handler. Any other encoding in custom-1 is illegal.

Why address registers, not a post-increment form of the base loads: a post-increment load writes two registers
(the data and the pointer), and the register file has one write port. Dedicated registers need no second port,
and give bit-reversed and circular addressing a home later.

From C:

```c
#define AR_SET(n, p) __asm__ volatile (".insn r CUSTOM_1, 0, 0, x" #n ", %0, x0" :: "r" (p) : "memory")
#define LH_A(r, n)   __asm__ volatile (".insn i CUSTOM_1, 1, %0, x0, " #n : "=r" (r))
```

### Micro-architecture

`rtl/core/agu.v` holds the registers. It follows the accumulator's rules:
- **The registers change as the instruction moves from EX to MEM, and only then.** They don't change while
  the pipeline is held, if a trap flushes the instruction, or if the load is misaligned.
- **A load reads its address register in EX**, after every older update, so back-to-back loads on one register
  need no forwarding.

The load's address replaces the ALU result on the way to MEM. From there it is an ordinary load: the
same alignment check, the same D-cache access, the same load-use interlock.

### Verification

- The Spike model (`tools/spike_xbrvdsp`) implements the registers and instructions, so every test that uses
  them runs in lockstep.
- `tests/directed/dsp_agu.S` covers:
  - readback of both fields;
  - forward and backward strides, and stride 0;
  - sign and zero extension;
  - independence of the four registers;
  - back-to-back loads, and load-use;
  - `ar.set` from a value computed the cycle before;
  - misaligned `lw.a` and `lh.a`: the cause, the address, and that rd and the register are unchanged.
- `tests/directed/dsp_irq.S` takes timer interrupts in a loop of `lw.a`. Every pass must end exactly one table
  length on, and the sum must be exact.
- Each test fails against a mutant of the RTL with its rule removed (no `!flush_mem`, no `!misaligned_ex`).

### Result

| Kernel (warm caches) | Cycles per unit | Inner loop |
|---|---|---|
| FIR, plain C | 9.18 per tap | 2 loads, 2 pointer increments, `mul`, `add`, `bne` (and a mul-use bubble) |
| FIR, `mac` (step 1) | 7.80 per tap | 2 loads, 2 increments, `mac`, `bne`, and a load-use bubble |
| FIR, `lh.a` + `mac` | 6.93 per tap | `lh.a`, `lh.a`, `mac`, count, `bne`, and a load-use bubble |
| FIR, `lh.a` + `mac`, two taps per iteration | **4.93 per tap** | four `lh.a`, two `mac`, count, `bne`: no bubble |
| Energy, `dmac` (step 1) | 3.15 per sample | |
| Energy, `lw.a` + `dmac` | 2.66 per sample | |
| Energy, `lw.a` + `dmac`, four samples per iteration | **1.66 per sample** | |

The benchmarks are compiled with `-falign-loops=4`. With RV32C, a loop whose first instruction is 32-bit and
starts at 2 mod 4 costs a fetch bubble on every jump back (early straddle only helps fetch in sequence); in the
AGU kernels that was a bubble per iteration (961 cycles in the FIR). The flag affects the other kernels by under
1%. What the FIR still loses is the inner loop's exit mispredict (two cycles per output) and its count and
branch: the hardware loop of step 4.

## Step 3: two taps per `dmac` in the FIR

The plan was packed loads: one `lw.a` gives two Q15 samples, and `dmac` multiplies both pairs at once. The
energy kernel already did this; the FIR has a problem. Output y[n] needs the pairs (x[n+k], x[n+k+1]), which are
aligned words only for even n. Unaligned pair loads would need a second memory access, or a funnel register
that joins halves of two words.

Software alone avoids both. For odd n, start one sample early, at the aligned x[n−1], and use a copy of the
coefficients shifted by one place: hs = (0, h[0], h[1], …, h[15], 0, …). Then

  x[n−1]·hs[0] + x[n]·hs[1] + x[n+1]·hs[2] + … = 0 + x[n]·h[0] + x[n+1]·h[1] + …

which is y[n]. Every load is an aligned word, from both arrays. Odd outputs do one more pair (the shifted copy
is 17 taps, padded to 20). The copy is built once per call, inside the measured kernel. The input array is padded
with zeros, so the extra loads at the end read zeros.

| Kernel (warm caches) | Cycles per tap |
|---|---|
| FIR, `lh.a` + `mac`, two taps per iteration (step 2) | 4.93 |
| FIR, `lw.a` + `dmac`, four taps per iteration (`fir_q15_dmac`) | **3.75** |

The inner loop is four `lw.a`, two `dmac`, the count and the branch: 8 instructions for 4 taps (5 for odd
outputs). About a third of the cycles are now the per-output overhead: setting up the address registers,
reading the result, and the inner loop's exit mispredict. The hardware loop of step 4 removes the count, the
branch and the mispredict.

## Step 4: the hardware loop

### State and instructions

`lc`, the loop count, and `lp_start`, the address where the body begins. Both reset to 0.

| Instruction | Encoding | Operation |
|---|---|---|
| `lp.setup rs1` | custom-1, funct3 110, rd = 0, imm = 0 | lc = rs1; lp_start = pc + 4 (the body follows) |
| `mac.lp`, `dmac.lp`, `msu.lp rs1, rs2` | custom-0, funct3 000, funct7 = that of `mac`/`dmac`/`msu` with bit 6 set | the MAC, then the loop-end step |
| `lp.end` | custom-1, funct3 111, all other fields 0 | the loop-end step alone |
| `lp.set rs1` / `lp.sets rs1` | custom-1, funct3 000, funct7 0000010, rd = 0 / 1, rs2 = 0 | lc = rs1 / lp_start = rs1 |
| `lp.rd rd` / `lp.rds rd` | custom-1, funct3 011, rs1 = 0, imm = 8 / 9 | rd = lc / rd = lp_start |

**The loop-end step:** if lc > 1, then lc = lc − 1 and execution goes to lp_start. Otherwise lc = 0 and execution
falls through. So `lp.setup` with a count of n runs the body n times (once for n = 0 or 1), and `lp.end` outside
a loop does nothing. `lp.rd`, `lp.rds`, `lp.set` and `lp.sets` save and restore the loop (an interrupt handler
that uses a loop, or a nested loop). The body's last instruction must not itself be a branch or jump.

### Why the loop end is an instruction, not an address

The plan was a zero-overhead loop over an address range, with fetch jumping back after the instruction at
`lp_end`, whatever it is. Spike cannot model that. An extension library adds instructions; it has no hook that
runs after a base instruction. Without the model, the extension would lose its lockstep check. So the
loop-back is folded into the body's last instruction instead. A MAC ends almost every DSP inner loop, so
`dmac.lp` (or `mac.lp`, `msu.lp`) closes the loop at no cost; `lp.end` covers the other loops, at one instruction
per pass in place of a count and a branch. The design is also simpler. Fetch needs no `lp_end` comparator in the
next-PC path (the critical path), and there is no loop state in IF to repair after a flush.

### Micro-architecture

`rtl/core/loop_unit.v` holds `lc` and `lp_start`. EX treats a loop-end instruction as a branch: taken while
lc > 1, to lp_start. Everything else is the existing branch machinery:
- the branch predictor learns the loop-end instruction's address, and predicts it taken;
- the mispredict path corrects the first pass (if the predictor has not seen the loop yet) and the last;
- the loop costs 2 cycles at exit and nothing per pass.

`lc` and `lp_start` change as the instruction leaves EX, under the same rule as `acc` and the address registers.
So an interrupt taken at a `dmac.lp` neither adds nor counts down, and back-to-back loop ends need no forwarding.

### Verification

- The Spike model implements every instruction, so loops run in lockstep.
- `tests/directed/dsp_loop.S` covers:
  - counts of 0, 1, 2 and many;
  - a one-instruction body (`mac.lp` issuing every cycle);
  - `dmac.lp` over an address register, and `msu.lp`;
  - a body with a branch that alternates (so it mispredicts);
  - a compressed body starting at 2 mod 4;
  - `lp.end` with no loop;
  - save and restore around an inner loop: an outer loop of 4 passes each runs a 3-pass inner loop, and both
    complete.
- `tests/directed/dsp_irq.S` part 3 runs 40 hardware loops of `lw.a` and `dmac.lp` under timer interrupts. It
  requires interrupts at the `dmac.lp`, `lc` = 0 after every pass, and an exact sum. Without the flush gating, a
  mutant hangs it.

### Result

| Kernel (warm caches) | Cycles per unit | vs plain C |
|---|---|---|
| FIR, `lw.a` + `dmac`, software loop (step 3) | 3.75 per tap | 2.4× |
| **FIR, `lw.a` + `dmac.lp`** (`fir_q15_lp`) | **3.19 per tap** | **2.9×** |
| Energy, `lw.a` + `dmac`, software loop | 1.66 per sample | 6.7× |
| **Energy, `lw.a` + `dmac.lp`** (`energy_q15_lp`) | **1.15 per sample** | **9.7×** |

The FIR's inner loop is now six instructions for four taps at one per cycle. Its body is four `lw.a`, a `dmac` and a `dmac.lp`. Most of what
remains is per output (about 51 cycles per output, against 27 in the loop): setting up the two address
registers and the accumulator, reading and storing the result, the loop's exit mispredict, and a mispredict on
the even/odd test, which alternates. Each loop is a single inline-asm statement, so the compiler cannot place
anything between `lp.setup` and the body.

## Step 5a: saturating add and subtract

| Instruction | funct7 | funct3 | Operation |
|---|---|---|---|
| `sadd rd, rs1, rs2` | 0000000 | 100 | rd = sat32(rs1 + rs2) |
| `ssub rd, rs1, rs2` | 0000001 | 100 | rd = sat32(rs1 − rs2) |

Custom-0, R-type, computed in EX in `dsp_unit.v` (a 33-bit add, clamped), written through `WB_DSP`. They do not
touch `acc`. `tests/directed/dsp_mac.S` cases 12–14 cover:
- results in range, exactly at either limit, and beyond each;
- 0 − (−2³¹);
- a result forwarded into the next `sadd` and into a branch.

### Benchmarks

**Biquad IIR.** Two second-order sections in cascade (a 4th-order Butterworth low-pass, Q14 coefficients),
direct form I, 256 samples, rounded and saturated to Q15 per section. The C uses a 32-bit sum; `gen_data.py`
checks that no partial sum overflows it. With Xbrvdsp each output is:
- `acc.set`;
- three `mac` and two `msu`;
- one `acc.rdh rd, 14`, which rounds, shifts and saturates.

**Saturating mix.** z[i] = sat32(p[i] + q[i]) over 256 Q31 samples, of which 62 saturate. The C uses
`__builtin_add_overflow` and a branch; with Xbrvdsp it is one `sadd`.

| Kernel (warm caches) | Cycles | Per unit | Main remaining loss |
|---|---|---|---|
| biquad, plain C | 15,434 | 30.1 per sample per section | mispredicts: 1,032 cycles (the saturation tests) |
| **biquad, `mac`/`msu`/`acc.rdh`** | **7,749** | **15.1** (2.0×) | none to speak of: IPC 1.00 |
| mix, plain C | 5,742 | 22.4 per sample | D-cache misses: 1,664 cycles; mispredicts 284 |
| mix, `sadd` | 4,238 | 16.6 per sample | D-cache misses: 1,664 cycles |

The mix is memory-bound. Three 1 KB arrays stream through the 2 KB two-way D-cache, and they map onto the same
sets, so the loads keep missing. Without the D-cache waits, the kernels take 3,584 and 2,080 cycles (1.7×). The
biquad with Xbrvdsp retires one instruction every cycle. Packing the state for `dmac`, and a hardware loop over
the samples, would shorten it further.

## Step 5b: bit-reversed addressing

`ar.mode arN, rs1` sets an address register's bit-reversed mode (rs1[0]); `ar.rdm` reads it back. In that mode
a load steps the low 16 bits of the address by reverse-carry addition. The carry runs from high bits to low and
stops at the element size: the address bits below the element (bit 0 for `lh.a`/`lhu.a`, bits 1:0 for `lw.a`)
keep their value.

  addr[15:0] = rev16(rev16(addr[15:0]) + rev16(stride)), bits below the element unchanged

With stride = N/2 elements (in bytes), and the buffer aligned to its size, successive loads visit elements 0,
N/2, N/4, 3N/4, … in bit-reversed order, as an FFT's input needs, and wrap back to element 0. In hardware it is
two bit reversals (wiring), one 16-bit adder and a multiplexer.

The mode is a separate instruction, not a bit of `ar.cfg`'s operand. The first version put it in rs1[16], and
the existing test with a negative stride (−4, so rs1[16] = 1) turned it on by accident. The carry rule was
also found by the tests: without it, the step after the last element of a halfword table carried into bit 0
and gave an odd address. Spike's model has the same rule, so the lockstep check covers it too.

Tests (`tests/directed/dsp_agu.S` cases 11–14):
- 8 halfwords in the order 0 4 2 6 1 5 3 7, then the wrap back to 0;
- 4 words (0 2 1 3, then 0);
- the mode read back, kept by `ar.cfg` even with a negative stride, and cleared;
- all 1024 points of a 1024-element table, against a bit reversal computed in software.

### FFT benchmark

A 64-point complex radix-2 decimation-in-time FFT in Q15. Each sample is one word, with re in the low half and
im in the high half. A bit-reversed copy comes first, then 6 stages of 32 butterflies, halving each output.
`gen_data.py` runs the same integer algorithm in Python to produce the expected output.

With Xbrvdsp:
- **The copy** loads through an address register in bit-reversed mode.
- **Each half of the twiddle product t = b·w** is one `dmac` against a packed twiddle: (wr, −wi) gives
  br·wr − bi·wi, and (wi, wr) gives br·wi + bi·wr. `acc.rdh rd, 15` rounds and saturates it. The twiddles are
  clamped to ±32767, so −wi fits in 16 bits.

| Part (warm caches) | Plain C | Xbrvdsp |
|---|---|---|
| bit-reversed copy | 1,205 cycles (18.8 per point; Gold–Rader reverse counter) | **605** (9.5 per point) |
| 6 stages of butterflies | 10,536 cycles (54.9 per butterfly) | **8,412** (43.8) |
| whole FFT | 11,741 | **9,017** (1.3×) |

The butterfly gains little. Of its ~35 instructions in the inner loop, the twiddle product is now 8 (four
loads of operands and twiddles, two `acc.set`, two `dmac`, two `acc.rdh`). About 20 unpack the halves, add,
subtract, halve and repack. The next instructions worth adding are packed halving adds and subtracts on two
16-bit halves (as in the RISC-V P extension's `radd16`/`rsub16`): then a butterfly's outputs are one
instruction each.
