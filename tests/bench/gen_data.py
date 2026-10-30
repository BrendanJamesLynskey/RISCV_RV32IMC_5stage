#!/usr/bin/env python3
"""Generate the benchmark inputs and expected outputs (bench_data.h).

The data are deterministic (a fixed LCG), so the header is reproducible:
    gen_data.py > bench_data.h

fir:    16-tap low-pass (windowed sinc) in Q15 over 64 outputs. The taps'
        absolute sum is below 1.0, so a 32-bit accumulator cannot overflow.
        y[n] = sat16((sum_k h[k] * x[n+k] + 2^14) >> 15)
        x and h are 4-byte aligned, and x has 3 zeros after its 79 samples,
        so the dmac kernel can read them as aligned pairs (dsp.c).
energy: sum of x[i]^2 over 256 Q15 samples, as a 64-bit integer: it needs
        more than 32 bits, which is what a 40-bit DSP accumulator is for.
biquad: two second-order sections in cascade (a Butterworth low-pass), Q14
        coefficients, direct form I, over 256 Q15 samples:
        y = sat16((b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2 + 2^13) >> 14),
        summed in the order written. Every partial sum fits in 32 bits.
mix:    z[i] = sat32(p[i] + q[i]) over 256 Q31 samples, large enough that
        about a quarter of the sums saturate.
fft:    64-point complex radix-2 decimation-in-time FFT, Q15, each sample a
        word (re in the low half, im in the high). Bit-reversed copy, then 6
        stages; each butterfly computes t = b * w as
        tr = sat16((br wr - bi wi + 2^14) >> 15), ti = sat16((br wi + bi wr + 2^14) >> 15)
        and outputs (a + t) >> 1, (a - t) >> 1, so the result is DFT / 64.
        Twiddles w = exp(-2 pi i k / 64), Q15, clamped to +-32767. Inputs are at
        a quarter of full scale, so no intermediate value overflows 16 bits.
"""
import math

TAPS, OUTS, NE = 16, 64, 256
NB, NMIX = 256, 256
NFFT = 64


def lcg(seed):
    while True:
        seed = (1103515245 * seed + 12345) & 0x7FFFFFFF
        yield seed


def q15_samples(n, seed):
    g = lcg(seed)
    return [((next(g) >> 8) % 65535) - 32767 for _ in range(n)]


def lowpass(taps, cutoff=0.2):
    mid = (taps - 1) / 2
    h = []
    for k in range(taps):
        t = k - mid
        sinc = 2 * cutoff * (math.sin(2 * math.pi * cutoff * t) / (2 * math.pi * cutoff * t) if t else 1.0)
        hann = 0.5 - 0.5 * math.cos(2 * math.pi * (k + 0.5) / taps)
        h.append(sinc * hann)
    scale = 0.95 / sum(abs(v) for v in h)          # absolute sum 0.95: no overflow in 32 bits
    return [round(v * scale * 32768) for v in h]


def sat16(v):
    return max(-32768, min(32767, v))


def sat32(v):
    return max(-2**31, min(2**31 - 1, v))


def butterworth_sections(cutoff=0.1):
    """Two second-order low-pass sections (4th-order Butterworth, bilinear
    transform), as (b0, b1, b2, a1, a2) in Q14."""
    k = math.tan(math.pi * cutoff)
    out = []
    for q in (1 / (2 * math.cos(math.pi / 8)), 1 / (2 * math.cos(3 * math.pi / 8))):
        norm = 1 / (1 + k / q + k * k)
        b0 = k * k * norm
        sec = (b0, 2 * b0, b0, 2 * (k * k - 1) * norm, (1 - k / q + k * k) * norm)
        out.append(tuple(round(c * 16384) for c in sec))
    return out


def fft_twiddles(n):
    def q15(v):
        return max(-32767, min(32767, round(v * 32768)))   # symmetric, so -w fits too
    return [(q15(math.cos(2 * math.pi * k / n)), q15(-math.sin(2 * math.pi * k / n))) for k in range(n // 2)]


def fft_q15(x, tw):
    """x: list of (re, im); the integer algorithm dsp.c runs."""
    n = len(x)
    bits = n.bit_length() - 1
    y = [x[int(format(i, f"0{bits}b")[::-1], 2)] for i in range(n)]
    length = 2
    while length <= n:
        half, step = length // 2, n // length
        for start in range(0, n, length):
            for j in range(half):
                wr, wi = tw[j * step]
                (ar, ai), (br, bi) = y[start + j], y[start + j + half]
                tr = sat16((br * wr - bi * wi + (1 << 14)) >> 15)
                ti = sat16((br * wi + bi * wr + (1 << 14)) >> 15)
                for v in (ar + tr, ai + ti, ar - tr, ai - ti):
                    assert -32768 <= v >> 1 <= 32767
                y[start + j] = ((ar + tr) >> 1, (ai + ti) >> 1)
                y[start + j + half] = ((ar - tr) >> 1, (ai - ti) >> 1)
        length *= 2
    return y


def biquad(x, sections):
    for b0, b1, b2, a1, a2 in sections:
        y, x1, x2, y1, y2 = [], 0, 0, 0, 0
        for v in x:
            acc = 0
            for term in (b0 * v, b1 * x1, b2 * x2, -a1 * y1, -a2 * y2):
                acc += term
                assert -2**31 <= acc < 2**31, "biquad partial sum overflows 32 bits"
            out = sat16((acc + (1 << 13)) >> 14)
            x2, x1, y2, y1 = x1, v, y1, out
            y.append(out)
        x = y
    return x


def main():
    x = q15_samples(OUTS + TAPS - 1, 1)
    h = lowpass(TAPS)
    assert sum(abs(v) for v in h) < 32768
    y = [sat16((sum(h[k] * x[n + k] for k in range(TAPS)) + (1 << 14)) >> 15) for n in range(OUTS)]
    e = q15_samples(NE, 7)
    energy = sum(v * v for v in e)
    assert energy >= 1 << 32, "the energy kernel must need more than 32 bits"

    def arr(name, typ, vals):
        rows = [", ".join(str(v) for v in vals[i:i + 12]) for i in range(0, len(vals), 12)]
        return f"static const {typ} {name}[{len(vals)}] = {{\n  " + ",\n  ".join(rows) + "\n};\n"

    print("/* bench_data.h: generated by gen_data.py; do not edit. */")
    print(f"#define FIR_TAPS {TAPS}\n#define FIR_OUTS {OUTS}\n#define ENERGY_N {NE}\n")
    print(arr("fir_x", "int16_t __attribute__((aligned(4)))", x + [0, 0, 0]))
    print(arr("fir_h", "int16_t __attribute__((aligned(4)))", h))
    print(arr("fir_expect", "int16_t", y))
    print(arr("energy_x", "int16_t __attribute__((aligned(4)))", e))
    print(f"static const int64_t energy_expect = {energy}LL;\n")

    sections = butterworth_sections()
    bx = [v // 2 for v in q15_samples(NB, 11)]          # half scale: headroom for the overshoot
    by = biquad(bx, sections)
    print(f"#define BIQUAD_N {NB}\n#define MIX_N {NMIX}\n")
    print(arr("biquad_c", "int16_t", [c for s in sections for c in s]))
    print(arr("biquad_x", "int16_t", bx))
    print(arr("biquad_expect", "int16_t", by))
    g = lcg(13)
    mp = [(next(g) << 1) - 2**31 + (next(g) & 1) for _ in range(NMIX)]
    mq = [(next(g) << 1) - 2**31 + (next(g) & 1) for _ in range(NMIX)]
    mz = [sat32(a + b) for a, b in zip(mp, mq)]
    print(arr("mix_p", "int32_t", mp))
    print(arr("mix_q", "int32_t", mq))
    print(arr("mix_expect", "int32_t", mz))
    print(f"/* mix: {sum(1 for a, b in zip(mp, mq) if sat32(a + b) != a + b)} of {NMIX} sums saturate */\n")

    def word(re, im):
        return ((im & 0xFFFF) << 16) | (re & 0xFFFF)
    tw = fft_twiddles(NFFT)
    fs = q15_samples(2 * NFFT, 17)
    fx = [(fs[2 * i] // 4, fs[2 * i + 1] // 4) for i in range(NFFT)]
    fy = fft_q15(fx, tw)
    print(f"#define FFT_N {NFFT}\n")
    print(arr("fft_x", "uint32_t __attribute__((aligned(256)))", [word(*v) for v in fx]))
    print(arr("fft_expect", "uint32_t", [word(*v) for v in fy]))
    print(arr("fft_wr", "int16_t", [w[0] for w in tw]))
    print(arr("fft_wi", "int16_t", [w[1] for w in tw]))
    # Packed for dmac: (wr, -wi) gives br wr - bi wi; (wi, wr) gives br wi + bi wr
    print(arr("fft_wa", "uint32_t", [word(wr, -wi) for wr, wi in tw]))
    print(arr("fft_wb", "uint32_t", [word(wi, wr) for wr, wi in tw]))


if __name__ == "__main__":
    main()
