# Lattice cryptography: arithmetic mod q for ML-KEM

ML-KEM (FIPS 203, the KEM standardised from Kyber) works on polynomials of degree below 256 with coefficients
modulo q = 3329, multiplied modulo X²⁵⁶ + 1. It multiplies them with a number-theoretic transform (NTT): seven
layers of 128 butterflies, then 128 small products, then the inverse transform. Each butterfly is a modular
multiply, an add and a subtract. On a plain RV32IM core, the reference C spends most of its time on reductions
mod q, not on the arithmetic itself. This part adds a packed unit for arithmetic mod q to Xbrvdsp and measures
what it does to the transform.

| Step | What | Status |
|---|---|---|
| 1 | Packed 2 × 16-bit arithmetic mod q, q in state, Montgomery multiplication, and butterfly instructions (part of Xbrvdsp) | **done** |
| 2 | The NTT, the inverse NTT, the base multiplication and a whole product a·b, against pq-crystals' reference C | **done** |
| 3 | A model of ML-KEM checked against NIST's ACVP vectors and C2SP CCTV's accumulated test vectors | **done** |
| 4 | The whole of ML-KEM (KeyGen, Encaps, Decaps, with Keccak) on the core, run in CI, checked against the same model | **done** |
| 5 | Power from simulated activity, not Vivado's vectorless default | next |

## The instructions

| Instruction | funct7 | Operation, per 16-bit lane |
|---|---|---|
| `mqmul2 rd, rs1, rs2` | 0000000 | mont(rs1 · rs2) |
| `mqadd2 rd, rs1, rs2` | 0000001 | addq(rs1, rs2) |
| `mqsub2 rd, rs1, rs2` | 0000010 | subq(rs1, rs2) |
| `ctadd2 rd, rs1, rs2` | 0000011 | addq(rs1, mont(ζ · rs2)) |
| `ctsub2 rd, rs1, rs2` | 0000100 | subq(rs1, mont(ζ · rs2)) |
| `gsmul2 rd, rs1, rs2` | 0001001 | mont(ζ · subq(rs2, rs1)) |
| `mq.cfg rs1` | 0000101 | q = rs1[15:0], q′ = rs1[31:16]; ζ = 0 (rd and rs2 zero) |
| `mq.zeta rs1` | 0000110 | ζ = rs1[15:0] (rd and rs2 zero) |
| `mq.rd rd` | 0000111 | rd = {q′, q} (rs1 and rs2 zero) |
| `mq.rdz rd` | 0001000 | rd = ζ (rs1 and rs2 zero) |

All are custom-0 (opcode 0001011), funct3 110. With R = 2¹⁶, and all arithmetic unsigned:

- mont(p): t = (p + ((p · q′) mod R) · q) / R, then t − q if t ≥ q. This is p · R⁻¹ mod q (Montgomery
  reduction), provided q′ = −q⁻¹ mod R.
- addq(a, b): a + b, less q if that is not below q.
- subq(a, b): a − b, plus q if a < b.

Each lane keeps bits [15:0]. With lanes below q the results are exact and below q. Every lane's arithmetic is
defined for any 16-bit value, so the Spike model matches the RTL bit for bit. q and q′ reset to ML-KEM's 3329
and 3327; ζ resets to 0.

- **q in state, not fixed.** The unit works for any odd q below 2¹⁵: ML-KEM's 3329, or Falcon's 12289 (the
  directed test uses both). A fixed q would make the multiplies by q and q′ shift-and-add, and cheaper. A
  register keeps the unit general, as `gf.cfg` does for GF(2⁸).
- **Montgomery, not Barrett.** pq-crystals' reference keeps its twiddle factors (ζ) in Montgomery form, so every
  product is mont(a · b). The instructions keep the same factors. Each function's result is then the
  reference's, reduced to [0, q), and the two can be compared directly.
- **Two lanes.** A word holds two coefficients. Each NTT layer pairs word j with word j + len/2: two butterflies
  with the same ζ, one in each lane.
- **Butterflies.** A Cooley–Tukey butterfly (the forward NTT) is (a + ζb, a − ζb): `ctadd2` and `ctsub2`, with ζ
  set once per block by `mq.zeta`. A Gentleman–Sande butterfly (the inverse) is (a + b, ζ(b − a)): `mqadd2` and
  `gsmul2`. Two instructions make two butterflies. With the multiply alone (`mqmul2` by {ζ, ζ}, then `mqadd2` and
  `mqsub2`) it takes three. A multiply by ζ alone is `ctadd2` with rs1 = x0.

### Micro-architecture

`rtl/core/mq_unit.v` spans EX and MEM, as the RV32M multiply does. The first version formed the products in EX
and the whole Montgomery reduction in MEM. That put two multipliers in series (p · q′, then m · q) and three
add-and-compare stages into the MEM-to-WB path: 21 ns, and Fmax fell from 65.3 to 47.5 MHz. The present
version has at most one multiplier in series in each stage:

- **The ζ instructions (`ctadd2`, `ctsub2`, `gsmul2`).** `mq.zeta` also stores ζq′ = ζ · q′ mod R. So in EX the
  unit forms both the product ζ · b and the Montgomery quotient m = (ζq′ · b) mod R, in parallel, from the
  forwarded operand. `gsmul2` first takes b − a mod q. In MEM it adds m · q, shifts, reduces, and adds or
  subtracts. `mq.cfg` clears ζ (and ζq′), which would otherwise be stale for the new q′.
- **`mqmul2`.** A general product has no precomputed quotient, so it takes two cycles in MEM. The first forms m
  from the registered product and holds the pipeline, as a D-cache wait does. The second finishes. Only the
  base multiplication needs it: 256 of them per product of two polynomials.

The hazard unit holds an instruction that uses a result for one cycle, as after a multiply. `mq.cfg` and
`mq.zeta` change state at the EX-to-MEM edge, under the same condition as a MAC's update of `acc`. An older
instruction still in MEM therefore reduces with the old q, a younger one in EX already uses the new ζ, and a
flushed `mq.cfg` never takes effect.

### Cost

On the Nexys A7's Artix-7 (out of context; `scripts/vivado_ooc.tcl`):

| | Before (main) | With `mq_unit` |
|---|---|---|
| LUTs | 11,077 | 11,889 (`mq_unit` 1,291) |
| Registers | 7,769 | 7,884 (`mq_unit` 97) |
| DSP48 slices | 7 | 16 (`mq_unit` 9) |
| Fmax | 65.3 MHz | 63.9 MHz |
| Power, vectorless (dynamic + static) | 192 mW (107 + 85) | 222 mW (137 + 85; `mq_unit` 14 of the 137) |

The worst path is now the accumulator readback (`acc.rd`'s rounding and saturation) into the EX result
register, not the new unit. The 2% is in the range placement varies by between builds: `gfmul4` moved Fmax
the other way, from 64.1 to 65.3 MHz.

Power is Vivado's vectorless estimate (`report_power`, default toggle rates, the clock constrained at 100 MHz).
It assumes every unit toggles all the time, whether or not the program uses it. So it compares designs; it
does not predict a program's power. On that basis the unit adds 30 mW of dynamic power (28%): 14 mW in
`mq_unit` itself, the rest in the core around it (the wider result select, and the change in placement). Code that does not use the unit would leave most of that idle: the operand and product registers load
only for an mq instruction. Step 5 replaces the default with activity from simulation, which will show it.

### Verification

`tests/directed/mq.S` covers:
- the reset state;
- a Montgomery product; add and subtract with wrap-around;
- `mq.zeta` straight before the `ctadd2` that uses it, then `ctsub2` and `gsmul2`;
- a dependent chain, each result used by the next instruction, stored, and branched on at once;
- lanes at 0xFFFF, outside the field, which still have defined results;
- an `mqmul2` straight before an `mq.cfg` (it must reduce with the old q) and one straight after (the new q,
  Falcon's 12289); `mq.cfg` clearing ζ;
- a multiply and an `mqmul2` feeding each other;
- an `mq.cfg` and an `mq.zeta` behind loads that trap, which must not take effect;
- `mqmul2`'s second MEM cycle with an independent `ctadd2`, a dependent `mqmul2`, a load that misses, and a
  store of the result straight behind it.

The expected values come from a Python model of the definitions above. The run is also compared in lockstep
with Spike, whose model (`tools/spike_xbrvdsp/xbrvdsp.cc`) computes them directly, not as the RTL splits them.
Three mutants each fail the test:
- **No `mqmul2` hold:** fails at case 3, on a wrong product.
- **No mq hazard:** fails at case 6.
- **A flushed `mq.cfg` taking effect:** fails at case 10.

## Step 2: the NTT

`tests/bench/mlkem.c` is pq-crystals' reference arithmetic (`ref/ntt.c`, `reduce.c`, `poly.c`): int16
coefficients, `fqmul` by Montgomery reduction, Barrett reduction in the inverse NTT and after the forward one.
`tests/bench/mlkem_x.c` uses the new instructions. Its coefficients are uint16 in [0, q), two to a word, and
every result is fully reduced, so there is no Barrett pass. Inputs are two random polynomials. Every result is
checked: against FIPS 203's NTT, its inverse (times R, as pq-crystals' `invntt` leaves it) and MultiplyNTTs
(times R⁻¹, as its `basemul` leaves it), and the product a·b against schoolbook multiplication.

| Kernel | Cycles | Per butterfly | vs reference | What it is |
|---|---|---|---|---|
| `mlkem_ntt` | 23,965 | 26.7 | | the reference forward NTT and its Barrett pass |
| `mlkem_ntt_mq` | 7,881 | 8.8 | 3.0× | `mqmul2` by {ζ, ζ}, `mqadd2`, `mqsub2`: three instructions per two butterflies |
| `mlkem_ntt_ct` | 7,055 | 7.9 | 3.4× | `ctadd2`, `ctsub2`: two |
| `mlkem_ntt_ct2` | 4,041 | 4.5 | 5.9× | the same, two layers per pass |
| `mlkem_invntt` | 34,335 | 38.3 | | the reference inverse NTT, Barrett in each butterfly, then × f |
| `mlkem_invntt_x` | 7,837 | 8.7 | 4.4× | `gsmul2`, `mqadd2`, then × f by `ctadd2` |
| `mlkem_invntt_x2` | 4,159 | 4.6 | 8.3× | the same, two layers per pass, × f folded into the last |
| `mlkem_basemul` | 11,808 | 92.3 per pair | | the reference: five `fqmul` per pair of coefficients |
| `mlkem_basemul_x` | 3,602 | 28.1 per pair | 3.3× | two `mqmul2`, a `ctadd2` with ζ = γ, an `mqadd2` and a `pack` per word |
| `mlkem_polymul` | 93,757 | | | a·b: two NTTs, `basemul`, the inverse NTT |
| `mlkem_polymul_x` | 15,427 | | 6.1× | the same with `ntt_ct2`, `basemul_x` and `invntt_x2` |

Cycles are warm (each kernel runs once before the measured run), from CI's full build.

### What limits it now: stores

With the arithmetic down to one instruction per butterfly pair, stores set the pace. The D-cache is
write-through, with a one-word write buffer, and a store waits while the one before it is still being
written: about four cycles each. In `mlkem_ntt_ct`, 2,165 of its 7,055 cycles are such waits. Its inner loop
is 4 loads, 4 butterfly instructions and 4 stores, and the stores come out back to back.

The software answer is the one pqm4 uses on Cortex-M4: merge layers. `mlkem_ntt_ct2` does two layers per
pass. It loads four words, j, j + h/2, j + h and j + 3h/2, runs both layers' butterflies on them in
registers (three ζ: one for the first layer, two for the second), and stores them once. That halves the loads
and stores. The stores are also spread between the last butterflies, each step's instructions scheduled by
hand in one asm statement, so most of a store's write overlaps other work. The NTT goes from 7,055 to 4,041
cycles. The inverse does the same, and also folds the final multiply by f = R²/128 into its last pass (a + b
multiplied by f, b − a by ζf instead of ζ). That saves a pass over the coefficients: 7,837 to 4,159.

D-cache waits are still about 30% of the product's cycles. The hardware answer would be a deeper write
buffer. That would change every benchmark in the repository, so it belongs in a change of its own, not here.

Two harness details matter for the numbers:
- **Stores scheduled by hand.** GCC does not know that an Xbrvdsp result arrives a cycle late, as a
  multiply's does. Left to itself, it put each store straight after the instruction feeding it, and every
  store stalled. So each group of butterflies is one asm statement, ordered so that neither a result nor the
  last word loaded is used straight away.
- **Inputs copied in first.** The transforms work in place, so the harness copies the inputs in before each
  run, outside the markers.

## Step 3: a model of ML-KEM, checked against published vectors

`tests/bench/mlkem.py` is ML-KEM written from FIPS 203 for clarity, not speed. It covers:
- the NTT and MultiplyNTTs;
- sampling (SampleNTT from SHAKE-128, the centred binomial distribution);
- byte encoding and compression;
- K-PKE;
- KeyGen, Encaps and Decaps with implicit rejection.

`gen_data.py` takes the benchmark's expected values from it. It is checked two ways:

- **NIST's ACVP vectors** for FIPS 203 (`mlkem.py acvp DIR`, the `internalProjection.json` files from
  usnistgov/ACVP-Server): 75 KeyGen, 25 Encaps and 10 Decaps tests at each of ML-KEM-512, -768 and -1024. All
  180 pass.
- **C2SP CCTV's accumulated test** (`mlkem.py cctv 10000 768`): 10,000 key pairs, encapsulations and
  decapsulations of both a valid and a random (invalid) ciphertext, drawn from one SHAKE-128 stream. All
  outputs are hashed into one value, which matches CCTV's published hash at all three levels.

The CCTV hashes did not match at first, although every decapsulation recovered its key. CCTV's intermediate
values showed why: they compute ρ‖σ = G(d), as the draft standard did. FIPS 203 as published hashes d‖k (k = 2,
3 or 4), separating the three parameter sets. CCTV's accumulated vectors were generated before that change.
So `mlkem.py` has a `draft` switch for the CCTV test, which changes only that hash, and the ACVP vectors check
the final form. `gen_data.py` re-checks the first 100 CCTV tests in both forms each time it runs, against
hashes recorded after both full checks passed.

## Step 4: the whole of ML-KEM-512 on the core

`tests/bench/run_kem.sh` builds FIPS 203's KeyGen, Encaps and Decaps (`mlkem_kem.c`, with Keccak-f[1600],
SHA3 and SHAKE in `keccak.c`) twice: once over the reference arithmetic of step 2 (`mlkem.c`) and once over the
Xbrvdsp kernels (`mlkem_x.c`: `mlkem_ntt_ct2`, `mlkem_basemul_x`, `mlkem_invntt_x2`), chosen by `-DMLKEM_EXT`.
The top level is the same code in both builds. It follows pq-crystals on the Montgomery factors: the base
multiplication leaves ×R⁻¹ and the inverse NTT ×R, so u and v need nothing, and t = A·s + e needs one
multiply by R (`poly_tomont`) after its accumulated products. The reference's NTT output is Barrett-reduced,
not in [0, q), so `poly_normalise` brings it there before any encoding; for the extension, whose results are
always in [0, q), it is nothing.

Each build runs KeyGen(d, z), Encaps(ek, m), Decaps(dk, c) and Decaps of a tampered ciphertext, with d, z and m
fixed, and compares ek, dk, c and K byte for byte with `mlkem.py` (its final FIPS 203 form, which passes the ACVP
vectors; `gen_kem.py`). The tampered ciphertext must give the implicit-rejection key J(z‖c′). Before that it
checks `keccak.c` against `hashlib`'s digests. Both builds are also compiled on the host with gcc and checked
the same way before any simulation (`HOST=1 run_kem.sh`; `mlkem_x_host.c` computes what the kernels compute,
in C), which is where the arithmetic was debugged. On the core, every instruction is compared with Spike in
lockstep, as the kernels were.

Each program is a 128 KB build of its own (`link_kem.ld`; `TB_MEM_DEPTH=32768`, Spike `-m` the same), not part of
`dsp.elf`. A run is over five million cycles, so the pipeline trace is not written: the testbench's `+marks=`
file records the cycle at which each marker retires, and `kem_report.py` works from that. `keccak.c` marks
every permutation, so the report also says how much of each operation is Keccak.

| Operation | Reference | Xbrvdsp | Speed-up | Keccak-f permutations | Cycles in Keccak (ext) | Share of ext |
|---|---|---|---|---|---|---|
| KeyGen | 1,433,125 | 1,291,067 | 1.11× | 27 | 1,055,258 | 82% |
| Encaps | 1,536,007 | 1,313,117 | 1.17× | 26 | 1,018,602 | 78% |
| Decaps | 1,717,035 | 1,398,671 | 1.23× | 26 | 1,019,496 | 73% |
| Decaps, tampered ciphertext (rejected) | 1,716,958 | 1,398,428 | 1.23× | 26 | 1,019,471 | 73% |
| All four | 6,403,125 | 5,401,283 | 1.19× | 105 | 4,112,827 | 76% |

Cycles from CI's build (the reference run retires 4.19 million instructions in 6.97 million cycles, the
extension's 3.40 million in 5.97 million, the hash checks and result comparisons included). The extension's
gain on the whole scheme is 1.19×, against 6.1× on a polynomial product alone, because the whole scheme is
mostly not polynomial arithmetic. With the extension, Keccak is 76% of the total: 105 permutations at 39,169
cycles each. Everything else (the kernels, the sampling, compression, encoding, and the hashes' absorb and
squeeze loops) is 1,288,456 cycles across the four operations, against 2,292,699 with the reference
arithmetic: the kernels take 1,004,243 cycles off, 44% of what is not Keccak, and the reference build itself
spends 64% in Keccak, the same 105 permutations. KeyGen gains least (1.11×): it has four NTTs and four base
multiplications but no inverse NTT, where the reference is slowest, and the most Keccak (SampleNTT for A, four
CBD samples, and H of the 800-byte key).

Why Keccak costs what it does here: `keccak.c` is plain C with 64-bit lanes, which rv32imc's GCC splits into
register pairs, and the state (50 words) does not fit the register file, so each step of a round loads and
stores its lanes. A permutation is about 20,000 instructions at an IPC near 0.5, the loss being the
write-through D-cache's store waits, which step 2 met in the NTT. An earlier version, with the lane indices
computed as `(x + 1) % 5` in loops and the rotations from a table, took 116,000 cycles a permutation: each
`% 5` became a hardware divide and each rotation a variable 64-bit shift. The constant-index form is the
one measured. The next useful step for the whole scheme would be a Keccak with 32-bit bit-interleaved lanes,
as pqm4 uses on Cortex-M4, or a Keccak instruction; either is a separate question from the arithmetic mod q
this part is about.
