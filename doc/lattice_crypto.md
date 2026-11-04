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
| 5 | Power from simulated activity, not Vivado's vectorless default | **done** |
| 6 | A faster Keccak in software (bit-interleaved 32-bit lanes, with Zbkb), whole ML-KEM re-measured | **done** |

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
as pqm4 uses on 32-bit microcontrollers, or a Keccak instruction; either is a separate question from the arithmetic mod q
this part is about.

## Step 5: power from simulated activity

`tests/power/run_saif.sh` runs a small program (`saif_polymul.c`: four polynomial products a·b in a row,
the last checked against `gen_data.py`) on the SoC in Vivado's simulator, xsim, twice: with pq-crystals'
reference C and with the `mq_unit` kernels. Each run writes the SoC's switching activity as SAIF.
`scripts/vivado_ooc.tcl` with `SAIF_FILES` set then reports power for each, on the same placed and routed
design as the vectorless figure (100 MHz constraint, Vivado 2025.2):

| | Vectorless | Reference C, simulated | `mq_unit` kernels, simulated |
|---|---|---|---|
| Dynamic power | 137 mW | 171 mW | 115 mW |
| of which the core / `u_mq` | 116 / 14 mW | 158 / 20 mW | 101 / 18 mW |
| Static power | 85 mW | 85 mW | 85 mW |
| Cycles per product (steady state) | | 94,241 | 15,443 |
| Energy per product at 100 MHz, dynamic | | 161 µJ | 17.8 µJ (9.1× less) |
| Energy per product, with static | | 241 µJ | 30.9 µJ (7.8× less) |

The kernels draw less power as well as running for less time (115 against 171 mW dynamic over the whole
run), so the energy saving is larger than the 6.1× in cycles.

**How far to trust it.** The SAIF comes from the RTL simulation, so Vivado can match it only to nets that
keep their RTL names after synthesis: 1,575 of 23,903 (7%), mostly registers and ports. It propagates
activity from those through the logic it cannot match. That is much better than the default toggle rate
for every net (the confidence level stays "Medium"), but the figures are estimates, good for comparing
these two programs on this design, not a measurement. Two things to read with that in mind:

- `u_mq` is not idle in the reference run (20 mW) even though no instruction uses it. Its multipliers take
  their operands straight from EX's operand buses, which change on every instruction; only the registers
  after them load on an mq instruction. Step 5b gates them; the estimate shows less of the effect than
  expected, for the reason given there.
- A SAIF from a simulation of the routed netlist (`write_verilog -mode funcsim`) matches many more nets
  (59%, High confidence), and agrees with this table to within 8%; see Step 5c. It is far slower to
  simulate; the RTL SAIF is what this step used.

## Step 5b: operand isolation

`u_mq` is instantiated in `brv32p_core.v` with its EX operands (`rs1_fwd`, `rs2_fwd`) and `funct7` passed
through an AND with the EX-stage "is mq" decode bit (`mq_ex`, custom-0 funct3 110): a plain AND per bit
(71 gates), in front of the multipliers, the `subq` of `gsmul2` and the `mq.cfg`/`mq.zeta` loads, which are
the only uses of the operands. Unless an mq instruction is in EX, the unit sees zeros, so its products,
quotients and adders hold still. The alternative, enable-loaded operand registers, would have added 71
flip-flops and a cycle; the AND sits after the forwarding mux, and `mq_ex` is a decode of `raw_ex`, which is
ready early. Results are unchanged: the 112 ISA tests (in lockstep with Spike), the ML-KEM jobs, the SoC
testbenches and lint all pass, and the two programs below run the same cycle counts as before
(399,363 and 85,536).

The flow is Step 5's. The "before" column is a fresh run of the same flow on main (bc75bf8), not the
table above, because the placement, and with it the estimate, moves between builds (the 7% of nets
Vivado can match to the RTL SAIF is a different 7%). Same 10 ns constraint, Vivado 2025.2:

| | Before, vectorless | After | Before, reference C | After | Before, kernels | After |
|---|---|---|---|---|---|---|
| Dynamic power | 131 mW | 100 mW | 230 mW | 191 mW | 135 mW | 113 mW |
| of which the core / `u_mq` | 114 / 16 | 84 / 7 | 214 / 19 | 179 / 11 | 121 / 17 | 101 / 9 |
| Static power | 85 mW | 85 mW | 85 mW | 85 mW | 85 mW | 85 mW |
| Energy per product, dynamic (94,241 / 15,443 cycles) | | | 217 µJ | 180 µJ | 20.8 µJ | 17.4 µJ |
| Energy per product, with static | | | 296 µJ | 260 µJ | 33.8 µJ | 30.6 µJ |

| Cost | Before | After |
|---|---|---|
| LUTs | 11,872 | 11,832 |
| Registers | 7,950 | 7,975 |
| DSP48 | 16 | 16 |
| `u_mq` LUTs / registers | 748 / 136 | 811 / 161 |
| WNS at 10 ns (Fmax) | -5.876 ns (63.0 MHz) | -5.966 ns (62.6 MHz) |

Isolation costs nothing measurable: the unit's own LUTs rose by 63 and the whole design's fell by 40 (the
two are within the changes between builds), and the worst path (the accumulator readback, as before) is
0.09 ns slower, 0.6% of Fmax, which is in the range placement moves it by.

**What it shows, and what it does not.** `u_mq` falls in all three estimates (vectorless 16 to 7 mW,
reference C 19 to 11 mW, kernels 17 to 9 mW), but not to about zero, and the rest of the fall, in the core,
is not isolation: it is the estimate moving between builds. Vivado propagates activity from the 7% of nets
it matched to the RTL SAIF through the rest of the logic, and it propagates through an AND gate with the
gate's other input switching at its own rate, not at its true value of "always 0 in this program". It
cannot see that `mq_ex` is never set in the reference run. So this flow understates what isolation does,
and cannot confirm it. A SAIF that names the nets after place and route, with the gates in it (Step 5c),
can.

## Step 5c: power from the routed netlist

`tests/power/run_saif_netlist.sh` repeats Step 5 on the placed-and-routed design itself. For each program
(`saif_polymul.c` built with `-DNETLIST`, which reports on the GPIO pins, since a netlist has only the SoC's
ports; the same four products) Vivado implements the isolated SoC with the program as the SRAM's initial image
(`scripts/vivado_netlist.tcl`: 16,384 words and reset vector 0x8000_0000, as the benchmarks are built),
writes it with `write_verilog -mode funcsim`, xsim simulates that under `tests/power/tb_netlist.v`, and
Vivado reads the SAIF back into the same routed design (`scripts/vivado_netlist_power.tcl`). The simulation
is **plain funcsim: zero delay, no SDF**, so it counts the logic transitions of the routed netlist but not
glitches from unequal path delays. It passes (the GPIO result is 1) and runs the same program in 399,032 and
85,994 cycles (399,363 and 85,536 in the RTL run: the testbench stops on the GPIO write, not the `tohost` store).

| | Reference C, RTL SAIF | Reference C, netlist SAIF | Kernels, RTL SAIF | Kernels, netlist SAIF |
|---|---|---|---|---|
| Nets matched | 7% (1,705 of 24,084) | **59% (14,219 of 24,084)** | 7% | **59%** |
| Confidence level | Medium | **High** | Medium | **High** |
| Dynamic power | 194 mW | 209 mW | 115 mW | 118 mW |
| of which the core / `u_mq` | 181 / 11 | 187 / 7 | 102 / 9 | 96 / 7 |
| Static power | 85 mW | 85 mW | 85 mW | 85 mW |
| Energy per product, dynamic (94,241 / 15,443 cycles) | 183 µJ | 197 µJ | 17.8 µJ | 18.2 µJ |
| Energy per product, with static | 263 µJ | 278 µJ | 30.9 µJ | 31.3 µJ |

(The RTL columns are Step 5's SAIFs read into this 16,384-word design, so the two SAIFs are compared on one
set of nets. The vectorless figure on this design is 72 mW dynamic. Resources: 11,860 LUTs, 7,947 registers,
16 DSP, 16 RAMB36, WNS -5.423 ns; the 64 KB SRAM doubles the block RAM against the 32 KB of the earlier
tables, and placement moves the rest.)

**What it shows.** The netlist SAIF gives Vivado's report High confidence and matches 59% of nets, not near
100%: the rest are nets inside primitives (carry chains, the DSP and block RAM internals, constants) that
the funcsim netlist simulates but does not expose under the names the report uses. The figures agree with
the RTL SAIF's to within 8% for reference C and 3% for the kernels, and the kernels' energy per product is
10.8 times less in dynamic energy and 8.9 times less with static, against 10.3 and 8.5 from the RTL SAIF. So
Step 5's conclusion holds on a measured-by-net footing, and its 7% matching did little harm.
`u_mq` is 7 mW in both runs, and the kernel run, which uses it throughout, shows no more than the
reference run, which does not: with isolation, activity in the unit is no longer what sets its power. The
7 mW that remains is, we infer, the clocks to its 129 registers and 9 DSP slices, which nothing gates.
A run of the design before Step 5b was not made from the netlist, so this does not show the saving from
isolation directly.

**Cost.** Wall time on the workstation: implementation and netlist export about 10 minutes a program, xelab
1 minute, and the simulation with SAIF logging 58 minutes for the reference run (399,000 cycles, about 115
cycles a second) and 9 for the kernel run; 90 minutes for the two. Four products per program was well
within the 2-hour budget, so none was cut to one.

## Step 6: a faster Keccak

Step 4 left Keccak-f[1600] as three quarters of the extension build: 105 permutations at 39,169 cycles. Step 6
replaces it in software, with no change to the core. `keccak.c` now has three builds behind the same
`keccak.h` API, chosen by a macro, and `run_kem.sh` takes `KECCAK=64|bi|bi_zbkb`:

- **64** (the default): the original, 64-bit lanes split into register pairs by GCC.
- **bi** (`-DKECCAK_BI`): bit-interleaved 32-bit lanes, as XKCP's inplace32BI and pqm4 do on 32-bit
  microcontrollers. A lane is held as two words, its even bits and its odd bits, so a 64-bit rotation is two
  32-bit rotations (or a swap and two) and no 64-bit value exists. Plain rv32imc: a rotation is
  shift, shift, or.
- **bi_zbkb** (`-DKECCAK_BI_ZBKB`, built with `_zbkb` in `-march`): the same, with `rori` for the rotations,
  `andn` for chi (GCC picks both without source changes), and `zip`/`unzip` for converting lanes to and from
  interleaved form at absorb and squeeze. On the host, where there is no Zbkb, `zip`/`unzip` are plain C.

One round is one pass of the loop, written with constant lane indices and rotations like the original (a
`% 5` in the loop became a hardware divide again until the loops were unrolled). It reads one 50-word array and writes
another (an output plane overwrites lanes a later plane still needs), swapping the two each round, so 24
rounds leave the result in the state. Theta, rho, pi and chi are fused: each output plane takes its five
lanes from the input, xors in theta's D, rotates, and does chi straight away, so every state word is loaded
about twice and stored once per round. The state stays interleaved in `keccak_t`; absorb and squeeze convert
a whole lane at a time (a byte at a time at the edges, which SHAKE128's 168-byte blocks and the 32-byte
hashes never reach after the first lane).

**The I-cache decides it.** The first version unrolled two rounds per pass: 3.4 KB of straight-line code
against a 2 KB I-cache, so every pass refilled it, and a permutation took 51,101 cycles, slower than the
original. One round per pass is 1.8 KB with Zbkb and 2.4 KB without, and that is the difference between 16,707 and
29,258 cycles below: the plain variant still does not quite fit.

| Keccak-f[1600] variant | Cycles per permutation | Code, bytes | Speed-up |
|---|---|---|---|
| 64-bit lanes (step 4) | 39,174 | 3,072 | 1.00× |
| bit-interleaved, rv32imc | 29,258 | 2,476 (+ conversion code) | 1.34× |
| bit-interleaved, Zbkb | 16,707 | 1,862 (+ conversion code) | 2.34× |

(Cycles from CI, the mean of the 105 permutations of the extension build; the reference build gives
39,168 and 16,683. Code size is the permutation function alone.)

The whole of ML-KEM-512, with the fastest Keccak (bit-interleaved, Zbkb), each in lockstep with Spike and
checked byte for byte as before:

| Operation | Reference | Xbrvdsp | Speed-up | Keccak-f permutations | Cycles in Keccak (ext) | Share of ext |
|---|---|---|---|---|---|---|
| KeyGen | 813,225 | 670,864 | 1.21× | 27 | 448,715 | 67% |
| Encaps | 938,981 | 715,958 | 1.31× | 26 | 434,701 | 61% |
| Decaps | 1,119,630 | 801,387 | 1.40× | 26 | 435,478 | 54% |
| Decaps, tampered ciphertext (rejected) | 1,119,572 | 801,680 | 1.40× | 26 | 435,372 | 54% |
| All four | 3,991,408 | 2,989,889 | 1.33× | 105 | 1,754,266 | 59% |

Against step 4's original reference (plain C arithmetic and 64-bit Keccak, 6,406,500 cycles in this run;
6,403,125 in step 4's, the difference being code placement) the extension build with the fast Keccak is
**2.14× faster** (2,989,889 cycles), and 1.81× faster than the extension with the old Keccak (5,404,454).
Each operation gains about the same, 2.1×. The Keccak alone took the reference build from 6.41 to 3.99
million cycles (1.60×). Keccak is now 59% of the extension build, down from 76%, and 44% of the reference build.
The arithmetic mod q is worth more than before: 1.33× on the whole scheme, against 1.19× with the old
Keccak. Cycles outside Keccak are unchanged by this step apart from the lane conversions (1,235,623 in the extension build,
against 1,291,142 before, a drop of about 55,000 cycles: the new absorb and squeeze work a lane at a time, the old one a byte at a time).

**What a Keccak instruction could still win** (an estimate; no RTL was written). A unit that does one round
in a cycle or two, with the state held in it and loaded and read through the register file (50 words in,
up to 42 words out per block), would cost on the order of 150 to 250 cycles a permutation in all, most of it
moving the state. For 105 permutations that is about 20,000 cycles in place of 1.75 million, and the build
would take about 1.26 million cycles: 2.4× faster than the software Keccak here, and 4.3× faster than step 4's
extension build. Beyond that the limit is everything else (the 1.24 million cycles of sampling, compression,
encoding and the kernels), so Keccak would be under 2% and the next costs would be the stores of the polynomial kernels and
the byte loops of sampling. A narrower step, instructions only for the rotation-and-xor of theta and rho, would
gain much less over `rori` and `andn`, which already make a round about 530 instructions.
