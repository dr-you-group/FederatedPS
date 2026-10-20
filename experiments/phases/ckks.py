"""CKKS aggregation for federated proximal block CCD packets (TenSEAL / SEAL)."""
import time, numpy as np, tenseal as ts

def make_context(poly_modulus_degree=8192, scale_bits=40, coeff=None):
    """Addition-only chain: no rescaling depth is consumed by ciphertext addition."""
    if coeff is None:
        coeff = [60, scale_bits, 60] if poly_modulus_degree >= 8192 else [40, 20, 40]
    ctx = ts.context(ts.SCHEME_TYPE.CKKS, poly_modulus_degree=poly_modulus_degree,
                     coeff_mod_bit_sizes=coeff)
    ctx.global_scale = 2 ** scale_bits
    ctx.generate_galois_keys()
    return ctx

def slots(poly_modulus_degree):
    """CKKS packs N/2 complex slots for ring degree N."""
    return poly_modulus_degree // 2

def aggregate(ctx, packets, return_timing=True):
    """packets: list of 1-D float arrays, one per site.  Returns (plain_sum, ckks_sum, timing)."""
    t0 = time.perf_counter()
    enc = [ts.ckks_vector(ctx, list(map(float, p))) for p in packets]
    t1 = time.perf_counter()
    acc = enc[0]
    for e in enc[1:]:
        acc = acc + e
    t2 = time.perf_counter()
    dec = np.array(acc.decrypt())[:len(packets[0])]
    t3 = time.perf_counter()
    plain = np.sum(np.array(packets, dtype=float), axis=0)
    timing = dict(encrypt=t1 - t0, add=t2 - t1, decrypt=t3 - t2,
                  ct_bytes=len(enc[0].serialize()), n_ct=len(enc))
    return (plain, dec, timing) if return_timing else (plain, dec)

def err(plain, dec, rel_floor=1e-8):
    """Absolute error everywhere; relative error only where the plaintext is not
    numerically zero -- CKKS adds absolute noise, so the relative error at an
    exact zero is meaningless (and infinite)."""
    a = np.abs(plain - dec)
    m = np.abs(plain) > rel_floor
    rel = a[m] / np.abs(plain)[m] if m.any() else np.array([0.0])
    return dict(inf=float(a.max()), l2=float(np.sqrt((a ** 2).sum())),
                rel_inf=float(rel.max()), rel_median=float(np.median(rel)),
                n_near_zero=int((~m).sum()), n=int(len(plain)))
