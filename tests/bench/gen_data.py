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
sha256: the digest of a 256-byte message (hashlib), as eight words.
crc32:  zlib's CRC-32 of 256 bytes; the table for the table-driven C, and a
        check that the carry-less Barrett formula crc32_zk.c uses gives zlib's
        result.
aes:    AES-128 encryption (ECB) of 256 bytes. The model below is checked
        against the FIPS-197 example (key 000102..0f) before use.
"""
import hashlib
import zlib
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


def aes_gmul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = ((a << 1) ^ 0x11B) if a & 0x80 else a << 1
        b >>= 1
    return r


def aes_sbox():
    inv = [0] * 256
    for x in range(1, 256):
        inv[x] = next(y for y in range(1, 256) if aes_gmul(x, y) == 1)
    rot = lambda v, n: ((v << n) | (v >> (8 - n))) & 0xFF
    return [b ^ rot(b, 1) ^ rot(b, 2) ^ rot(b, 3) ^ rot(b, 4) ^ 0x63 for b in inv]


def aes128(key, data):
    """(round keys, ciphertext) of data (a multiple of 16 bytes), ECB."""
    sb = aes_sbox()
    rk, rcon = list(key), 1
    while len(rk) < 176:
        t = rk[-4:]
        if len(rk) % 16 == 0:
            t = [sb[x] for x in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = aes_gmul(rcon, 2)
        rk += [a ^ b for a, b in zip(rk[-16:-12], t)]
    out = []
    for i in range(0, len(data), 16):
        s = [a ^ b for a, b in zip(data[i:i + 16], rk[:16])]
        for r in range(1, 11):
            s = [sb[s[4 * ((c + j) % 4) + j]] for c in range(4) for j in range(4)]
            if r < 10:
                m = []
                for c in range(4):
                    a = s[4 * c:4 * c + 4]
                    m += [aes_gmul(a[j], 2) ^ aes_gmul(a[(j + 1) % 4], 3) ^ a[(j + 2) % 4] ^ a[(j + 3) % 4]
                          for j in range(4)]
                s = m
            s = [a ^ b for a, b in zip(s, rk[16 * r:16 * r + 16])]
        out += s
    return rk, out


def crc_barrett(data):
    """CRC-32 as crc32_zk.c computes it: a word at a time, bit-reversed into
    the normal domain, Barrett reduction by carry-less multiplies."""
    def clmul(a, b):
        r = 0
        for i in range(32):
            if (b >> i) & 1:
                r ^= a << i
        return r
    rev = lambda v: int(format(v, "032b")[::-1], 2)
    p, mu = 0x04C11DB7, 0x04D101DF
    crc = 0xFFFFFFFF
    for i in range(0, len(data), 4):
        x = crc ^ rev(int.from_bytes(data[i:i + 4], "little"))
        q = (clmul(x, mu) >> 32) ^ x
        crc = clmul(q, p) & 0xFFFFFFFF
    return rev(crc) ^ 0xFFFFFFFF


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

    gm = lcg(19)
    msg = bytes(next(gm) & 0xFF for _ in range(256))
    dig = hashlib.sha256(msg).digest()
    print(f"\n#define SHA_LEN {len(msg)}\n")
    print(arr("sha_msg", "uint8_t", list(msg)))
    print(arr("sha_expect", "uint32_t", [int.from_bytes(dig[i:i + 4], "big") for i in range(0, 32, 4)]))

    _, fips = aes128(bytes(range(16)), bytes.fromhex("00112233445566778899aabbccddeeff"))
    assert bytes(fips).hex() == "69c4e0d86a7b0430d8cdb78070b4c55a", "AES model fails FIPS-197"
    ga = lcg(23)
    akey = bytes(next(ga) & 0xFF for _ in range(16))
    apt = bytes(next(ga) & 0xFF for _ in range(256))
    ark, act = aes128(akey, apt)
    print(f"\n#define AES_BLOCKS {len(apt) // 16}\n")
    sb = aes_sbox()
    print(arr("aes_sbox", "uint8_t", sb))
    print(arr("aes_t0", "uint32_t", [(aes_gmul(s, 3) << 24) | (s << 16) | (s << 8) | aes_gmul(s, 2) for s in sb]))
    print(arr("aes_rk", "uint8_t __attribute__((aligned(4)))", ark))
    print(arr("aes_pt", "uint8_t __attribute__((aligned(4)))", list(apt)))
    print(arr("aes_expect", "uint8_t", act))

    gc = lcg(29)
    cmsg = bytes(next(gc) & 0xFF for _ in range(256))
    tab = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ (0xEDB88320 if c & 1 else 0)
        tab.append(c)
    assert crc_barrett(cmsg) == zlib.crc32(cmsg), "the clmul Barrett formula disagrees with zlib"
    print(f"\n#define CRC_LEN {len(cmsg)}\n")
    print(arr("crc32_tab", "uint32_t", tab))
    print(arr("crc_msg", "uint8_t __attribute__((aligned(4)))", list(cmsg)))
    print(f"static const uint32_t crc_expect = {zlib.crc32(cmsg):#010x}u;")


if __name__ == "__main__":
    main()
