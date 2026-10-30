#!/usr/bin/env python3
"""ML-KEM (FIPS 203), a plain model: the reference for the lattice benchmarks.

Written from FIPS 203 for clarity, not speed: lists of ints, coefficients
in [0, q). The benchmark data (gen_data.py) use its NTT, inverse NTT and
MultiplyNTTs; ML-KEM itself is here so that those are checked inside the
whole scheme against published test vectors, two sets:

    mlkem.py acvp DIR         NIST's ACVP vectors for FIPS 203 (DIR holds
                              ML-KEM-keyGen-FIPS203.json and
                              ML-KEM-encapDecap-FIPS203.json, the
                              internalProjection.json files of
                              github.com/usnistgov/ACVP-Server gen-val):
                              75 KeyGen, 105 Encaps and Decaps
    mlkem.py cctv [N] [512|768|1024]
                              C2SP CCTV's "accumulated" test
                              (github.com/C2SP/CCTV, ML-KEM/README)

CCTV's test draws N tests from one SHAKE-128 stream with empty input (d, z,
m, then an invalid ciphertext), absorbs ek, dk, ct, K and the
implicit-rejection K of each into a second SHAKE-128 instance, and compares
its first 32 bytes with CCTV's for N = 10,000. Its hashes come from the draft
standard (pq-crystals' ref/test/test_vectors.c before FIPS 203 was final),
whose K-PKE.KeyGen hashes d alone: the final standard hashes d || k. So the
CCTV test runs with draft=True, which changes only that, and the ACVP
vectors check the final form. Each CCTV test also checks that decapsulation
recovers the encapsulated K. 10,000 tests take some minutes; gen_data.py
checks the first 100 in both forms, against hashes recorded here after both
full checks passed.
"""
import hashlib
import sys

Q, N = 3329, 256
PARAMS = {512: (2, 3, 2, 10, 4), 768: (3, 2, 2, 10, 4), 1024: (4, 2, 2, 11, 5)}   # k, eta1, eta2, du, dv
CCTV_10K = {512: "845913ea5a308b803c764a9ed8e9d814ca1fd9c82ba43c7b1e64b79c7a6ec8e4",
            768: "f7db260e1137a742e05fe0db9525012812b004d29040a5b606aad3d134b548d3",
            1024: "47ac888fe61544efc0518f46094b4f8a600965fc89822acb06dc7169d24f3543"}


def bitrev7(i):
    return int(f"{i:07b}"[::-1], 2)


ZETAS = [pow(17, bitrev7(i), Q) for i in range(128)]            # zeta^BitRev7(i)
GAMMAS = [pow(17, 2 * bitrev7(i) + 1, Q) for i in range(128)]   # for BaseCaseMultiply


def ntt(f):
    """FIPS 203 Algorithm 9: the output is in bit-reversed order."""
    f, k, ln = list(f), 1, 128
    while ln >= 2:
        for start in range(0, N, 2 * ln):
            z = ZETAS[k]
            k += 1
            for j in range(start, start + ln):
                t = z * f[j + ln] % Q
                f[j + ln] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        ln //= 2
    return f


def intt(f):
    """FIPS 203 Algorithm 10, including the final 128^-1 (3303)."""
    f, k, ln = list(f), 127, 2
    while ln <= 128:
        for start in range(0, N, 2 * ln):
            z = ZETAS[k]
            k -= 1
            for j in range(start, start + ln):
                t = f[j]
                f[j] = (t + f[j + ln]) % Q
                f[j + ln] = z * (f[j + ln] - t) % Q
        ln *= 2
    return [x * 3303 % Q for x in f]


def multiply_ntts(f, g):
    """FIPS 203 Algorithm 11: 128 products of degree-one polynomials."""
    h = [0] * N
    for i in range(128):
        a0, a1, b0, b1 = f[2 * i], f[2 * i + 1], g[2 * i], g[2 * i + 1]
        h[2 * i] = (a0 * b0 + a1 * b1 * GAMMAS[i]) % Q
        h[2 * i + 1] = (a0 * b1 + a1 * b0) % Q
    return h


def schoolbook(a, b):
    """a * b in Z_q[X]/(X^256 + 1), directly: the check on the three above."""
    c = [0] * N
    for i in range(N):
        for j in range(N):
            if i + j < N:
                c[i + j] += a[i] * b[j]
            else:
                c[i + j - N] -= a[i] * b[j]
    return [x % Q for x in c]


def add(f, g):
    return [(x + y) % Q for x, y in zip(f, g)]


def sub(f, g):
    return [(x - y) % Q for x, y in zip(f, g)]


def byte_encode(f, d):
    bits = 0
    for i, x in enumerate(f):
        bits |= x << (d * i)
    return bits.to_bytes(32 * d, "little")


def byte_decode(b, d):
    bits, m = int.from_bytes(b, "little"), (1 << d) - 1
    return [(bits >> (d * i)) & m for i in range(N)]


def compress(f, d):
    return [((x << d) + Q // 2) // Q % (1 << d) for x in f]


def decompress(f, d):
    return [(y * Q + (1 << (d - 1))) >> d for y in f]


def sample_ntt(seed):
    """FIPS 203 Algorithm 7: rejection sampling from SHAKE-128."""
    out, buf, n = [], b"", 0
    while len(out) < N:
        if n + 3 > len(buf):
            buf = hashlib.shake_128(seed).digest(len(buf) + 504)
        b0, b1, b2 = buf[n], buf[n + 1], buf[n + 2]
        n += 3
        for d in (b0 + 256 * (b1 & 15), (b1 >> 4) + 16 * b2):
            if d < Q and len(out) < N:
                out.append(d)
    return out


def sample_cbd(b, eta):
    """FIPS 203 Algorithm 8."""
    bits = int.from_bytes(b, "little")
    f = []
    for i in range(N):
        x = sum((bits >> (2 * i * eta + j)) & 1 for j in range(eta))
        y = sum((bits >> (2 * i * eta + eta + j)) & 1 for j in range(eta))
        f.append((x - y) % Q)
    return f


def prf(s, b, eta):
    return hashlib.shake_256(s + bytes([b])).digest(64 * eta)


def G(x):
    h = hashlib.sha3_512(x).digest()
    return h[:32], h[32:]


def H(x):
    return hashlib.sha3_256(x).digest()


def J(x):
    return hashlib.shake_256(x).digest(32)


def matrix(rho, k):
    return [[sample_ntt(rho + bytes([j, i])) for j in range(k)] for i in range(k)]


def dot(row, vec):
    acc = [0] * N
    for a, b in zip(row, vec):
        acc = add(acc, multiply_ntts(a, b))
    return acc


def pke_keygen(d, p, draft=False):
    k, eta1 = p[0], p[1]
    rho, sigma = G(d if draft else d + bytes([k]))
    A = matrix(rho, k)
    s = [sample_cbd(prf(sigma, i, eta1), eta1) for i in range(k)]
    e = [sample_cbd(prf(sigma, k + i, eta1), eta1) for i in range(k)]
    sh, eh = [ntt(x) for x in s], [ntt(x) for x in e]
    th = [add(dot(A[i], sh), eh[i]) for i in range(k)]
    return b"".join(byte_encode(x, 12) for x in th) + rho, b"".join(byte_encode(x, 12) for x in sh)


def pke_encrypt(ek, m, r, p):
    k, eta1, eta2, du, dv = p
    th = [byte_decode(ek[384 * i:384 * (i + 1)], 12) for i in range(k)]
    A = matrix(ek[384 * k:], k)
    y = [sample_cbd(prf(r, i, eta1), eta1) for i in range(k)]
    e1 = [sample_cbd(prf(r, k + i, eta2), eta2) for i in range(k)]
    e2 = sample_cbd(prf(r, 2 * k, eta2), eta2)
    yh = [ntt(x) for x in y]
    u = [add(intt(dot([A[j][i] for j in range(k)], yh)), e1[i]) for i in range(k)]
    mu = decompress(byte_decode(m, 1), 1)
    v = add(add(intt(dot(th, yh)), e2), mu)
    return b"".join(byte_encode(compress(x, du), du) for x in u) + byte_encode(compress(v, dv), dv)


def pke_decrypt(dk, c, p):
    k, _, _, du, dv = p
    u = [decompress(byte_decode(c[32 * du * i:32 * du * (i + 1)], du), du) for i in range(k)]
    v = decompress(byte_decode(c[32 * du * k:], dv), dv)
    sh = [byte_decode(dk[384 * i:384 * (i + 1)], 12) for i in range(k)]
    w = sub(v, intt(dot(sh, [ntt(x) for x in u])))
    return byte_encode(compress(w, 1), 1)


def keygen(d, z, p, draft=False):
    ek, dk = pke_keygen(d, p, draft)
    return ek, dk + ek + H(ek) + z


def encaps(ek, m, p):
    K, r = G(m + H(ek))
    return K, pke_encrypt(ek, m, r, p)


def decaps(dk, c, p):
    k = p[0]
    dk_pke, ek, h, z = dk[:384 * k], dk[384 * k:768 * k + 32], dk[768 * k + 32:768 * k + 64], dk[768 * k + 64:]
    m = pke_decrypt(dk_pke, c, p)
    K, r = G(m + h)
    return K if pke_encrypt(ek, m, r, p) == c else J(z + c)


def accumulated(n, level, draft=True):
    """CCTV's accumulated test: the hex digest of n tests at this level."""
    p = PARAMS[level]
    ct_len = 32 * (p[3] * p[0] + p[4])
    stream = hashlib.shake_128(b"").digest(n * (96 + ct_len))
    acc, pos = hashlib.shake_128(), 0

    def draw(m):
        nonlocal pos
        pos += m
        return stream[pos - m:pos]
    for _ in range(n):
        d, z, m, bad = draw(32), draw(32), draw(32), draw(ct_len)
        ek, dk = keygen(d, z, p, draft)
        K, c = encaps(ek, m, p)
        assert decaps(dk, c, p) == K, "decapsulation does not recover K"
        for x in (ek, dk, c, K, decaps(dk, bad, p)):
            acc.update(x)
    return acc.hexdigest(32)


def acvp(path):
    """NIST's ACVP vectors: the number of tests run, and the number passed."""
    import json
    import os
    run = passed = 0
    for name in ("ML-KEM-keyGen-FIPS203.json", "ML-KEM-encapDecap-FIPS203.json"):
        with open(os.path.join(path, name)) as f:
            groups = json.load(f)["testGroups"]
        for g in groups:
            p = PARAMS[int(g["parameterSet"][-4:].lstrip("-"))]
            fn = g.get("function", "keyGen")
            for t in g["tests"]:
                x = {k: bytes.fromhex(v) for k, v in t.items() if isinstance(v, str) and k != "reason"}
                if fn == "keyGen":
                    ok = keygen(x["d"], x["z"], p) == (x["ek"], x["dk"])
                elif fn == "encapsulation":
                    ok = encaps(x["ek"], x["m"], p) == (x["k"], x["c"])
                elif fn == "decapsulation":
                    ok = decaps(x["dk"], x["c"], p) == x["k"]
                else:
                    continue                          # key checks: not modelled
                run, passed = run + 1, passed + ok
    return run, passed


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "acvp":
        run, passed = acvp(sys.argv[2])
        print(f"ACVP: {passed} of {run} pass")
        sys.exit(0 if run and passed == run else 1)
    if len(sys.argv) < 2 or sys.argv[1] != "cctv":
        sys.exit(__doc__)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    level = int(sys.argv[3]) if len(sys.argv) > 3 else 768
    h = accumulated(n, level)
    print(f"ML-KEM-{level}, {n} tests: {h}")
    if n == 10000:
        ok = h == CCTV_10K[level]
        print("matches CCTV" if ok else "DOES NOT MATCH CCTV " + CCTV_10K[level])
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
