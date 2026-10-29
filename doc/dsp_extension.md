# Xbrvdsp: the DSP extension

Xbrvdsp is BRV32P's own instruction-set extension for signal processing. It is built in steps, each measured on
the DSP benchmarks (`tests/bench`) and checked in lockstep against a Spike model of the extension. The ideas are
the standard DSP repertoire (a multiply-accumulate into a wide accumulator, address generators, a zero-overhead
loop), as surveyed in Zhang Zhiwei's *RISC-V Architecture and DSP Processor Design*; the encodings are this
project's own.

| Step | Adds | Status |
|---|---|---|
| 1 | Multiply-accumulate: `mac`, `dmac`, `msu`, accumulator access | **done** |
| 2 | Address generators: loads with post-increment and bit-reversed addressing | planned |
| 3 | Packed loads for `dmac` in the FIR | planned |
| 4 | Zero-overhead hardware loop | planned |
| 5 | Saturating add and subtract; biquad IIR and radix-2 FFT benchmarks | planned |

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
