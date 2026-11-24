#pragma once
namespace paired_initial {
struct Rng { uint32_t s0, s1, s2, s3; };
__device__ __forceinline__ uint64_t splitmix(uint64_t& x) {
    uint64_t z = (x += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
__device__ __forceinline__ void rng_seed(Rng& r, uint64_t seed, uint32_t trial, uint32_t lane) {
    uint64_t x = seed ^ (uint64_t(trial) << 20) ^ (uint64_t(lane) << 48) ^ 0x5CA0F00Dull;
    const uint64_t a = splitmix(x), b = splitmix(x);
    r.s0 = uint32_t(a); r.s1 = uint32_t(a >> 32); r.s2 = uint32_t(b); r.s3 = uint32_t(b >> 32);
    if (!(r.s0 | r.s1 | r.s2 | r.s3)) r.s0 = 1;
}
__device__ __forceinline__ uint32_t rng_next(Rng& r) {
    const uint32_t m = r.s1 * 5u;
    const uint32_t res = __funnelshift_l(m, m, 7) * 9u, t = r.s1 << 9;
    r.s2 ^= r.s0; r.s3 ^= r.s1; r.s1 ^= r.s2; r.s0 ^= r.s3; r.s2 ^= t; r.s3 = __funnelshift_l(r.s3, r.s3, 11);
    return res;
}

__device__ __forceinline__ float amplitude(uint32_t id,int i){
    Rng r;
    rng_seed(r,20261004ULL,id,i%256);
    unsigned sample=0;
    for(int k=0;k<=i/256;++k)sample=rng_next(r);
    return copysignf(fabsf(float(initial_x(id,i))), (sample>>31) ? 1.f : -1.f);
}
}
