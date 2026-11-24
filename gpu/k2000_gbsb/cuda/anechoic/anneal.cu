// Bit-exact GPU (GH200, sm_90) implementation of the V80 Onsager/TEC-T/plain SCA engine (reference: sca_ref.hpp, SCA_LANES=256).
//
// One thread-block cluster of CS CTAs runs 4*G independent chains. The cluster holds the whole coupling matrix J in registers as
// binary tensor-core (BMMA m16n8k256 .b1 AND+POPC) A-fragments: 32 warps per cluster, each owning 8 RNG lanes x 8 rounds = 64
// field slots y and the full 2048-bit x range (128 registers per thread). Lane L of a warp owns chain (L % 4) of each group and
// RNG lane 8*wg + L/4, i.e. the 8 slots k*256 + l (k = 0..7) that lane l of the V80 engine decides in rounds k = 0..7.
// Per step and group, every warp:
//   decisions (8 per thread, exactly as sca::run_trial, Q16.16 integer arithmetic) -> per-chain flip masks F and F&sigma'
//   -> CTA staging -> st.async (DSMEM, mbarrier complete_tx) to every CTA of the cluster
//   -> after the mbarrier wait, BMMA over the 8 k-blocks gives popc(J_y & Fsigma') and popc(J_y & F) for its 64 y and 4 chains
//   -> dh_y = 2*(4 cA - 2 cB - 2|Fsigma'| + |F| + [y in F](2 sigma'_y - 1))   (diagonal and padding handled exactly)
// The initial field uses the same path with F := valid slots, sigma' := initial spins and factor 1.
// Random numbers do not depend on the chain state; each step's 8 thresholds per thread are generated while messages are in flight.
#include "sca_ref.hpp"
#include "tables.hpp"
#include "frozen_input.hpp"
#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#if SCA_LANES != 256
#error "build with -DSCA_LANES=256"
#endif

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) throw std::runtime_error(std::string(#x) + ": " + cudaGetErrorString(e_)); } while (0)


namespace kern {

constexpr int N = 2000;

#include "triple.cuh"

struct Params {
    const unsigned long long* graph;
    Trigger* events;
    const uint4* A;          // [32 wg][4 j][8 kb][32 lanes]
    const int32_t* fourT;    // [S]
    const int32_t* q;        // [S]
    const int64_t* kcorr;    // [S]
    const int32_t* kconst;   // [S]
    int S;
    uint64_t seed;
    uint32_t trial_offset;
    int nchains;             // chains reported (chain index < nchains); other chains of a group are computed but not written
    int do_trace;
    uint8_t* out_spins;      // [nchains][256]: bit k = (spin of slot k*256+l == +1)
    int32_t* out_sh;         // [nchains][256]: sum over the lane's valid slots of s*h
    int64_t* out_flips;      // [nchains]
    int32_t* out_trace;      // [nchains][S] n_lin per step
    long long* prof;         // [gridDim][8] phase cycle totals (SCA_PROFILE builds only)
};

__device__ __forceinline__ uint32_t smem_u32(const void* p) { return (uint32_t)__cvta_generic_to_shared(p); }
__device__ __forceinline__ uint32_t mapa(uint32_t a, uint32_t rank) {
    uint32_t r; asm volatile("mapa.shared::cluster.u32 %0, %1, %2;" : "=r"(r) : "r"(a), "r"(rank)); return r;
}
__device__ __forceinline__ uint32_t cluster_rank() { uint32_t r; asm volatile("mov.u32 %0, %%cluster_ctarank;" : "=r"(r)); return r; }
__device__ __forceinline__ uint32_t cluster_index() { uint32_t r; asm volatile("mov.u32 %0, %%clusterid.x;" : "=r"(r)); return r; }
__device__ __forceinline__ void cluster_sync_all() {
    asm volatile("barrier.cluster.arrive.release.aligned;\n\tbarrier.cluster.wait.acquire.aligned;" ::: "memory");
}
__device__ __forceinline__ void mbar_init(uint32_t bar, uint32_t count) {
    asm volatile("mbarrier.init.shared::cta.b64 [%0], %1;" :: "r"(bar), "r"(count) : "memory");
}
__device__ __forceinline__ void mbar_arm(uint32_t bar, uint32_t bytes) {
    asm volatile("mbarrier.arrive.expect_tx.release.cta.shared::cta.b64 _, [%0], %1;" :: "r"(bar), "r"(bytes) : "memory");
}
__device__ __forceinline__ bool mbar_test(uint32_t bar, uint32_t parity) {
    uint32_t ok;
    asm volatile("{\n\t.reg .pred p;\n\tmbarrier.try_wait.parity.acquire.cluster.shared::cta.b64 p, [%1], %2;\n\tselp.u32 %0, 1, 0, p;\n\t}"
                 : "=r"(ok) : "r"(bar), "r"(parity) : "memory");
    return ok != 0;
}
__device__ __forceinline__ void st_async16(uint32_t raddr, uint32_t rbar, uint4 v) {
    asm volatile("st.async.shared::cluster.mbarrier::complete_tx::bytes.v4.b32 [%0], {%1,%2,%3,%4}, [%5];"
                 :: "r"(raddr), "r"(v.x), "r"(v.y), "r"(v.z), "r"(v.w), "r"(rbar) : "memory");
}
__device__ __forceinline__ void bmma(int32_t (&c)[4], const uint4& a, uint32_t b0, uint32_t b1) {
    asm("mma.sync.aligned.m16n8k256.row.col.s32.b1.b1.s32.and.popc {%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
        : "+r"(c[0]), "+r"(c[1]), "+r"(c[2]), "+r"(c[3]) : "r"(a.x), "r"(a.y), "r"(a.z), "r"(a.w), "r"(b0), "r"(b1));
}

// xoshiro128**, seeded by splitmix64(seed, trial, lane) -- identical to sca::Rng.
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
// r = ((u16 - 32768) * fourT) >> 16 (int64, arithmetic shift); the result always fits in int32.
__device__ __forceinline__ int32_t threshold(uint32_t draw, int32_t fourT) {
    const int32_t a = int32_t(draw >> 16) - 32768;
    return int32_t((int64_t(a) * int64_t(fourT)) >> 16);
}

template <int CS, int G>
struct Cfg {
    static constexpr int NWG = 32 / CS;                 // warps per CTA
    static constexpr int THREADS = 32 * NWG;
    // One message (per group and step) = 32 source warps x (16 mask words + 4 count words) = 2560 bytes, double-buffered.
    static constexpr int MSG_WORDS = 32 * 16 + 4 * 32;  // masks [32 wg][16] then counts [4 chains][32 wg]
    static constexpr uint32_t BYTES = uint32_t(MSG_WORDS * 4);
    static constexpr int RB_OFF = 0;                                    // [G][2][MSG_WORDS] u32
    static constexpr int BAR_OFF = RB_OFF + G * 2 * MSG_WORDS * 4;      // [G][2] u64
    static constexpr int TAB_OFF = BAR_OFF + G * 2 * 8;                 // fourT[S], q[S], kconst[S] (i32), kcorr[S] (i64, 16-aligned)
    static_assert(TAB_OFF % 16 == 0, "alignment");
};

__device__ __forceinline__ void st_async4(uint32_t raddr, uint32_t rbar, uint32_t v) {
    asm volatile("st.async.shared::cluster.mbarrier::complete_tx::bytes.b32 [%0], %1, [%2];" :: "r"(raddr), "r"(v), "r"(rbar) : "memory");
}

// ONS: the correction depends on the previous step's n_lin (lambda > 0). Otherwise corr = kconst[t] is known in advance and is
// folded into the thresholds. LIN: count n_lin (needed for ONS and for the trace).
// No CTA-wide barrier inside the step loop: every warp sends its own 64-byte mask chunks and 4-byte count words to every CTA and
// waits only for the mbarrier of the next message. A buffer (group, parity) is rewritten with message m+2 only after every warp
// of the cluster has sent message m+1, i.e. after every warp has finished reading message m.
template <int CS, int G, bool ONS, bool LIN, bool MID=false>
__global__ void __launch_bounds__(32 * (32 / CS), 1) sca_kernel(const Params p) {
    static_assert(LIN || !ONS, "Onsager mode needs n_lin");
    using C = Cfg<CS, G>;
    constexpr int NWG = C::NWG, MW = C::MSG_WORDS;
    extern __shared__ __align__(16) uint8_t smem[];
    uint32_t* RB = reinterpret_cast<uint32_t*>(smem + C::RB_OFF);
    const int S = p.S;
    using Work = typename std::conditional<MID,TriangleScratch,int>::type;
    __shared__ Work station;
    TriangleScratch* root=nullptr;
    if constexpr(MID) root=cooperative_groups::this_cluster().map_shared_rank(&station,0);
    Trigger event{-1,-1,-1,-1,0,0,0};
    int last_flips[G]{};
    const bool streamed = S > 4096;
    const int cached = streamed ? 0 : S;
    int32_t* sharedT = reinterpret_cast<int32_t*>(smem + C::TAB_OFF);
    int32_t* sharedQ = sharedT + cached;
    int32_t* sharedK = sharedQ + cached;
    int64_t* sharedCorr = reinterpret_cast<int64_t*>(smem + C::TAB_OFF + ((12 * cached + 15) / 16) * 16);
    const int32_t* T_fourT = streamed ? p.fourT : sharedT;
    const int32_t* T_q = streamed ? p.q : sharedQ;
    const int32_t* T_kconst = streamed ? p.kconst : sharedK;
    const int64_t* T_kcorr = streamed ? p.kcorr : sharedCorr;

    const int tid = threadIdx.x, L = tid & 31, w = tid >> 5;
    const uint32_t rank = cluster_rank();
    const int wg = int(rank) * NWG + w;                 // warp-global index 0..31
    const int c4 = L & 3;                               // chain within group
    const int lane_l = 8 * wg + (L >> 2);               // RNG lane 0..255
    const uint32_t validm = lane_l < (N - 7 * 256) ? 0xFFu : 0x7Fu;   // slot 7*256+l exists only for l < 208
    const int cl = int(cluster_index());
#ifdef SCA_PROFILE
    long long pr[8] = {0, 0, 0, 0, 0, 0, 0, 0}; long long tq = clock64();
#define PROF(i) do { const long long tn = clock64(); pr[i] += tn - tq; tq = tn; } while (0)
#else
#define PROF(i) do {} while (0)
#endif

    for (int i = tid; i < cached; i += blockDim.x) {
        sharedT[i] = p.fourT[i]; sharedQ[i] = p.q[i]; sharedK[i] = p.kconst[i]; sharedCorr[i] = p.kcorr[i];
    }
    const uint32_t bar0 = smem_u32(smem + C::BAR_OFF);
    if (tid == 0) {
        for (int i = 0; i < 2 * G; ++i) mbar_init(bar0 + 8 * i, 1);
        asm volatile("fence.mbarrier_init.release.cluster;" ::: "memory");
        for (int i = 0; i < 2 * G; ++i) mbar_arm(bar0 + 8 * i, C::BYTES);   // messages 0 and 1 of every group
    }
    uint4 A[4][8];   // A fragments: 4 y-blocks x 8 k-blocks x 4 registers, resident for the whole kernel
#pragma unroll
    for (int j = 0; j < 4; ++j)
#pragma unroll
        for (int kb = 0; kb < 8; ++kb) A[j][kb] = p.A[((wg * 4 + j) * 8 + kb) * 32 + L];

    // per-group chain state. hh = h - s (shifted field: no diagonal correction needed).
    Rng rng[G];
    int32_t hh[G][8], ntk[G][8], l1[G][8];
    uint32_t sb[G], dif[G];
    int32_t flips_tot[G], nlin_cur[G];
#pragma unroll
    for (int g = 0; g < G; ++g) {
        const uint32_t trial = p.trial_offset + uint32_t((cl * G + g) * 4 + c4);
        rng_seed(rng[g], p.seed, trial, uint32_t(lane_l));
        uint32_t s = 0xFFu;   // padding slots are +1
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const uint32_t r = rng_next(rng[g]);
            if ((validm >> k) & 1) s = (s & ~(1u << k)) | ((r >> 31) << k);
        }
        sb[g] = s; dif[g] = s ^ 0xFFu;   // sprev = +1 everywhere at step 0
        flips_tot[g] = 0; nlin_cur[g] = 0;
#pragma unroll
        for (int k = 0; k < 8; ++k) { hh[g][k] = 0; ntk[g][k] = 0; l1[g][k] = 0; }
    }
    __syncthreads();
    cluster_sync_all();   // barriers of every CTA initialised before any st.async

    // remote addresses (fixed per thread): sender lane L sends chain (L & 3) of this warp to CTA (L >> 2)
    const int dst = L >> 2, sc = L & 3;
    const bool sender = dst < CS;
    uint32_t r_msk[G][2], r_cnt[G][2], r_bar[G][2];
#pragma unroll
    for (int g = 0; g < G; ++g)
#pragma unroll
        for (int par = 0; par < 2; ++par) {
            const uint32_t base = smem_u32(RB + (g * 2 + par) * MW);
            const uint32_t d = sender ? uint32_t(dst) : 0u;
            r_msk[g][par] = mapa(base + 4u * uint32_t(wg * 16 + sc * 4), d);
            r_cnt[g][par] = mapa(base + 4u * uint32_t(32 * 16 + sc * 32 + wg), d);
            r_bar[g][par] = mapa(bar0 + 8u * uint32_t(g * 2 + par), d);
        }

    // ---- send: sender lane (dst, chain sc) gathers the 8 lanes of its chain in one shuffle level and st.asyncs to CTA dst ----
    // mask words: byte = RNG lane offset within the half-warp group (4h'+byte), bit = round; counts packed 10-bit fields.
    auto send = [&](int g, int m, uint32_t fbits, uint32_t snew, uint32_t lin) {
        const int par = m & 1;
        const uint32_t av = fbits | ((fbits & snew) << 8) | (lin << 24);
        uint32_t v[8];
#pragma unroll
        for (int lam = 0; lam < 8; ++lam) v[lam] = __shfl_sync(0xffffffffu, av, 4 * lam + sc);
        const uint32_t x01 = __byte_perm(v[0], v[1], 0x5140u), x23 = __byte_perm(v[2], v[3], 0x5140u);
        const uint32_t x45 = __byte_perm(v[4], v[5], 0x5140u), x67 = __byte_perm(v[6], v[7], 0x5140u);
        const uint32_t wf0 = __byte_perm(x01, x23, 0x5410u), wfs0 = __byte_perm(x01, x23, 0x7632u);
        const uint32_t wf1 = __byte_perm(x45, x67, 0x5410u), wfs1 = __byte_perm(x45, x67, 0x7632u);
        const uint32_t ls = (v[0] + v[1] + v[2]) + (v[3] + v[4] + v[5]) + (v[6] + v[7]);   // bits 24..31 = sum of lin (<= 64)
        const uint32_t pcs = uint32_t(__popc(wf0) + __popc(wf1)) | (uint32_t(__popc(wfs0) + __popc(wfs1)) << 10) | ((ls >> 24) << 20);
        if (sender) {
            const uint32_t rm = par ? r_msk[g][1] : r_msk[g][0], rc = par ? r_cnt[g][1] : r_cnt[g][0], rbr = par ? r_bar[g][1] : r_bar[g][0];
            st_async16(rm, rbr, make_uint4(wfs0, wfs1, wf0, wf1));
            st_async4(rc, rbr, pcs);
        }
    };

    // ---- receive: wait for message m of group g, BMMA, field update (factor 1 for the initial field, 2 afterwards) ----
    auto receive = [&](int g, int m) {
        const int par = m & 1;
        const uint32_t bar = bar0 + 8 * (g * 2 + par);
        const uint32_t parity = uint32_t(m >> 1) & 1u;
        while (!mbar_test(bar, parity)) {}
        PROF(5);
        if (tid == 0) mbar_arm(bar, C::BYTES);   // for message m + 2
        const uint32_t* rb = RB + (g * 2 + par) * MW;
        // counts: lanes with the same chain each sum 4 source warps, then a 3-level reduction (16-bit fields)
        const uint4 cw = *reinterpret_cast<const uint4*>(rb + 32 * 16 + c4 * 32 + 4 * (L >> 2));
        const uint32_t vsum = cw.x + cw.y + cw.z + cw.w;   // 10-bit fields, each <= 256
        uint32_t u0 = (vsum & 1023u) | (((vsum >> 10) & 1023u) << 16), u1 = vsum >> 20;
        uint32_t b[8][2];
#pragma unroll
        for (int kb = 0; kb < 8; ++kb) {
#pragma unroll
            for (int hi = 0; hi < 2; ++hi) {
                const int wgx = 4 * kb + 2 * hi + ((L >> 1) & 1);
                b[kb][hi] = rb[wgx * 16 + (L >> 2) * 2 + (L & 1)];
            }
        }
        int32_t acc[4][4], acc2[4][4];
#pragma unroll
        for (int j = 0; j < 4; ++j) {
            acc[j][0] = acc[j][1] = acc[j][2] = acc[j][3] = 0;
            acc2[j][0] = acc2[j][1] = acc2[j][2] = acc2[j][3] = 0;
        }
#pragma unroll
        for (int kb = 0; kb < 4; ++kb)
#pragma unroll
            for (int j = 0; j < 4; ++j) {
                bmma(acc[j], A[j][kb], b[kb][0], b[kb][1]);
                bmma(acc2[j], A[j][kb + 4], b[kb + 4][0], b[kb + 4][1]);
            }
#pragma unroll
        for (int j = 0; j < 4; ++j)
#pragma unroll
            for (int i = 0; i < 4; ++i) acc[j][i] += acc2[j][i];
        u0 += __shfl_xor_sync(0xffffffffu, u0, 4); u1 += __shfl_xor_sync(0xffffffffu, u1, 4);
        u0 += __shfl_xor_sync(0xffffffffu, u0, 8); u1 += __shfl_xor_sync(0xffffffffu, u1, 8);
        u0 += __shfl_xor_sync(0xffffffffu, u0, 16); u1 += __shfl_xor_sync(0xffffffffu, u1, 16);
        const int32_t nF = int32_t(u0 & 0xFFFFu), nFs = int32_t(u0 >> 16);
        nlin_cur[g] = int32_t(u1);
        if constexpr(MID) last_flips[g]=nF;
        const int32_t base = nF - 2 * nFs, f = m == 0 ? 1 : 2;
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const int j = k >> 1, hi = k & 1;
            hh[g][k] += f * (4 * acc[j][2 * hi] - 2 * acc[j][2 * hi + 1] + base);
        }
        if (m >= 1) flips_tot[g] += nF;
    };

    // thresholds for step t: ntk = q + 65536 - thr (+/- corr folded for non-Onsager modes), l1 for the n_lin band
    auto make_thresholds = [&](int g, int t) {
        const int32_t fourT = T_fourT[t], twoT = fourT >> 1, qc = T_q[t] + 65536, corr = T_kconst[t];
        const int32_t qs = qc - corr, qd = qc + corr;
        const int64_t c64 = -int64_t(32768) * fourT;
        const uint32_t df = dif[g];
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const int32_t thr = int32_t((int64_t(uint64_t(rng_next(rng[g]) >> 16) * uint64_t(uint32_t(fourT))) + c64) >> 16);
            ntk[g][k] = ONS ? qc - thr : (((df >> k) & 1u) ? qd : qs) - thr;
            if (LIN) l1[g][k] = thr + twoT - 1;
        }
    };
#pragma unroll
    for (int g = 0; g < G; ++g) {
        make_thresholds(g, 0);
        send(g, 0, validm, sb[g], 0u);   // message 0: F := valid slots, sigma' := initial spins
    }

    const int chain_base = cl * G * 4;
    const bool writer = (wg == 0) && (L < 4);   // lane L = chain c4, RNG lane 0
    for (int m = 0; m <= S; ++m) {
#pragma unroll
        for (int g = 0; g < G; ++g) {
            PROF(0);
            receive(g, m);
            PROF(1);
            const int chain = chain_base + g * 4 + c4;
            if (LIN && m >= 1 && p.do_trace && writer && chain < p.nchains) p.out_trace[size_t(chain) * S + (m - 1)] = nlin_cur[g];
            if (m == S) continue;
            if constexpr (MID) {
                const bool examine = chain < p.nchains && event.sweep<0 && (m==0 || last_flips[g]!=0);
                bool negative=!examine;
                if(examine) {
                    ++event.tested;
#pragma unroll
                    for(int k=0;k<8;++k) {
                        if((validm>>k)&1u) {
                            const int margin=(((sb[g]>>k)&1u)?hh[g][k]:-hh[g][k])+1;
                            negative |= margin<0;
                        }
                    }
                }
                const unsigned mask=__ballot_sync(~0u,negative);
                if(L==0) root->bad[m&1][wg]=mask;
                cluster_sync_all();
                unsigned allbad=root->bad[m&1][L];
#pragma unroll
                for(int gap=16;gap;gap>>=1) allbad|=__shfl_xor_sync(~0u,allbad,gap);
                unsigned stable=0;
#pragma unroll
                for(int c=0;c<4;++c) if(!(allbad&(0x11111111u<<c)))stable|=1u<<c;
                if(stable) {   // uniform across all eight CTAs
                    const bool mine=(stable>>c4)&1u;
                    if(mine) {
                        ++event.stable;
#pragma unroll
                        for(int k=0;k<8;++k) {
                            int site=256*k+lane_l;
                            if(site<N) {
                                int positive=(sb[g]>>k)&1u;
                                int margin=(positive?hh[g][k]:-hh[g][k])+1;
                                root->codes[c4][site]=(margin==1||margin==3)?
                                    ((site+1)|(positive<<11)|((margin==3)<<12)):0;
                            }
                        }
                    }
                    cluster_sync_all();
                    if(writer&&mine) choose_triple(p.graph,root->codes[c4],root->choice[c4]);
                    cluster_sync_all();
                    if(mine && root->choice[c4][0]) {
                        int codes[3]={root->choice[c4][1],root->choice[c4][2],root->choice[c4][3]};
                        event.sweep=m;event.a=tri_site(codes[0]);event.b=tri_site(codes[1]);event.c=tri_site(codes[2]);
                        event.gain=root->choice[c4][0];
                        unsigned fire=0;
#pragma unroll
                        for(int k=0;k<8;++k) {
                            const int y=256*k+lane_l;if(y>=N)continue;
                            int delta=0;
#pragma unroll
                            for(int j=0;j<3;++j) {
                                int x=tri_site(codes[j]),sign=tri_sign(codes[j]);
                                if(x==y) {fire|=1u<<k;delta+=2*sign;} // hh=h-s
                                else delta-=2*sign*tri_edge(p.graph,x,y);
                            }
                            hh[g][k]+=delta;
                        }
                        sb[g]^=fire;dif[g]^=fire;flips_tot[g]+=3;
                        if constexpr (!ONS) {
#pragma unroll
                            for(int k=0;k<8;++k) if((fire>>k)&1u)
                                ntk[g][k]+=((dif[g]>>k)&1u)?2*T_kconst[m]:-2*T_kconst[m];
                        }
                    }
                }
            }

            const int t = m;
            int32_t ci = 0;
            if (ONS) ci = int32_t(((int64_t(nlin_cur[g]) * T_kcorr[t]) >> 8) + int64_t(T_kconst[t]));
            const uint32_t lw = uint32_t(2 * (T_fourT[t] >> 1) - 1);
            uint32_t fbits = 0, lin = 0;
            const uint32_t s = sb[g], df = dif[g];
#pragma unroll
            for (int k = 0; k < 8; ++k) {
                const int32_t hs = ((s >> k) & 1u) ? hh[g][k] : -hh[g][k];
                int32_t x = ntk[g][k];
                if (ONS) x += ((df >> k) & 1u) ? ci : -ci;
                const int32_t dv = hs * 65536 + x;   // z - thr
                fbits |= (dv < 0 ? 1u : 0u) << k;
                if (LIN && (k < 7 || validm == 0xFFu)) lin += (uint32_t(dv + l1[g][k]) < lw) ? 1u : 0u;
            }
            fbits &= validm;
            sb[g] = s ^ fbits; dif[g] = fbits;
            PROF(2);
            send(g, m + 1, fbits, sb[g], lin);
            PROF(3);
            if (t + 1 < S) make_thresholds(g, t + 1);   // overlaps the message flight
            PROF(4);
        }
    }
#ifdef SCA_PROFILE
    if (tid == 0 && p.prof) for (int i = 0; i < 8; ++i) p.prof[blockIdx.x * 8 + i] = pr[i];
#endif
#pragma unroll
    for (int g = 0; g < G; ++g) {
        const int chain = chain_base + g * 4 + c4;
        if (chain < p.nchains) {
            int32_t sh = 0;
#pragma unroll
            for (int k = 0; k < 8; ++k)
                if ((validm >> k) & 1u) sh += (((sb[g] >> k) & 1u) ? hh[g][k] : -hh[g][k]) + 1;   // s*h = s*hh + 1
            p.out_spins[size_t(chain) * 256 + lane_l] = uint8_t(sb[g]);
            p.out_sh[size_t(chain) * 256 + lane_l] = sh;
            if (writer) {p.out_flips[chain] = flips_tot[g];p.events[chain]=event;}
        }
    }
    cluster_sync_all();
}


// Comparison variant: one CTA (256 threads) per chain, J^T bit-packed in global memory (read through L2/L1), the brief's popcount
// field update dh_y = sum_w [F_w != 0] (2 popc(F_w & m) - 4 popc((JT_y,w ^ S'_w) & F_w & m)), m excluding the diagonal.
// Thread l owns RNG lane l and its 8 slots k*256 + l. Same arithmetic and random stream as run_trial.
__global__ void __launch_bounds__(256, 1) sca_l2_kernel(const Params p, const unsigned long long* __restrict__ JT) {
    __shared__ unsigned long long Fm[32], Sm[32];
    __shared__ int red[8][2];
    const int l = threadIdx.x, S = p.S, chain = blockIdx.x;
    const uint32_t trial = p.trial_offset + uint32_t(chain);
    Rng rng; rng_seed(rng, p.seed, trial, uint32_t(l));
    const uint32_t validm = l < (N - 7 * 256) ? 0xFFu : 0x7Fu;
    uint32_t sb = 0xFFu, spb = 0xFFu;
#pragma unroll
    for (int k = 0; k < 8; ++k) { const uint32_t r = rng_next(rng); if ((validm >> k) & 1) sb = (sb & ~(1u << k)) | ((r >> 31) << k); }
    // spin words: slot i = k*256 + l -> word i>>6, bit i&63; built with shared atomics
    if (l < 32) { Fm[l] = 0; Sm[l] = 0; }
    __syncthreads();
#pragma unroll
    for (int k = 0; k < 8; ++k) {
        const int i = k * 256 + l;
        if (((validm >> k) & 1) && ((sb >> k) & 1)) atomicOr(&Sm[i >> 6], 1ull << (i & 63));
        if ((validm >> k) & 1) atomicOr(&Fm[i >> 6], 1ull << (i & 63));   // F := valid for the initial field
    }
    __syncthreads();
    int32_t h[8];
    // initial field: h_y = sum_{x valid, x != y} J_xy s_x = sum_w (2 popc(~(JT^S) & V & m) - popc(V & m))
#pragma unroll
    for (int k = 0; k < 8; ++k) {
        const int y = k * 256 + l; int32_t acc = 0;
        if (y < N) for (int wd = 0; wd < 32; ++wd) {
            unsigned long long v = Fm[wd]; if (wd == (y >> 6)) v &= ~(1ull << (y & 63));
            acc += 2 * __popcll(~(JT[size_t(y) * 32 + wd] ^ Sm[wd]) & v) - __popcll(v);
        }
        h[k] = acc;
    }
    int32_t nlin_prev = 0; int64_t flips = 0;
    for (int t = 0; t < S; ++t) {
        const int64_t corr = ((int64_t(nlin_prev) * p.kcorr[t]) >> 8) + p.kconst[t];
        const int32_t fourT = p.fourT[t], twoT = fourT >> 1;
        uint32_t fb = 0; int nl = 0;
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const uint32_t u16 = rng_next(rng) >> 16;
            if (!((validm >> k) & 1)) continue;
            const int sk = ((sb >> k) & 1) ? 1 : -1, sp = ((spb >> k) & 1) ? 1 : -1;
            const int64_t z = (int64_t(sk) * h[k]) * 65536 + p.q[t] - (sk == sp ? corr : -corr);
            const int64_t r = ((int64_t(u16) - 32768) * fourT) >> 16;
            if (z > -twoT && z < twoT) ++nl;
            if (z < r) fb |= 1u << k;
        }
        __syncthreads();   // previous step's readers of Fm/Sm are done
        if (l < 32) { Fm[l] = 0; Sm[l] = 0; }
        __syncthreads();
        spb = sb; sb ^= fb;
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const int i = k * 256 + l;
            if ((fb >> k) & 1) atomicOr(&Fm[i >> 6], 1ull << (i & 63));
            if (((validm >> k) & 1) && ((sb >> k) & 1)) atomicOr(&Sm[i >> 6], 1ull << (i & 63));
        }
        // n_lin and flip count: warp reduce then CTA reduce
        int nf = __popc(fb);
#pragma unroll
        for (int o = 16; o > 0; o >>= 1) { nl += __shfl_xor_sync(0xffffffffu, nl, o); nf += __shfl_xor_sync(0xffffffffu, nf, o); }
        if ((l & 31) == 0) { red[l >> 5][0] = nl; red[l >> 5][1] = nf; }
        __syncthreads();
        int nlt = 0, nft = 0;
#pragma unroll
        for (int i = 0; i < 8; ++i) { nlt += red[i][0]; nft += red[i][1]; }
        flips += nft; nlin_prev = nlt;
        if (p.do_trace && l == 0 && chain < p.nchains) p.out_trace[size_t(chain) * S + t] = nlt;
        // field update for my 8 slots
#pragma unroll
        for (int k = 0; k < 8; ++k) {
            const int y = k * 256 + l;
            if (y >= N) continue;
            int32_t acc = 0;
            for (int wd = 0; wd < 32; ++wd) {
                unsigned long long fw = Fm[wd];
                if (!fw) continue;
                if (wd == (y >> 6)) fw &= ~(1ull << (y & 63));
                acc += 2 * __popcll(fw) - 4 * __popcll((JT[size_t(y) * 32 + wd] ^ Sm[wd]) & fw);
            }
            h[k] += acc;
        }
    }
    if (chain < p.nchains) {
        int32_t sh = 0;
#pragma unroll
        for (int k = 0; k < 8; ++k) if ((validm >> k) & 1) sh += (((sb >> k) & 1) ? h[k] : -h[k]);
        p.out_spins[size_t(chain) * 256 + l] = uint8_t(sb);
        p.out_sh[size_t(chain) * 256 + l] = sh;
        if (l == 0) p.out_flips[chain] = flips;
    }
}

}  // namespace kern

// ------------------------------------------------------------------------------------------------------------------------------
namespace host {

struct Device {
    int id = 0;
    cudaDeviceProp prop{};
    std::string uuid;
};

std::string uuid_str(const cudaUUID_t& u) {
    char b[64]; const unsigned char* x = reinterpret_cast<const unsigned char*>(u.bytes);
    std::snprintf(b, sizeof b, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", x[0], x[1], x[2], x[3], x[4], x[5],
                  x[6], x[7], x[8], x[9], x[10], x[11], x[12], x[13], x[14], x[15]);
    return b;
}

Device open_device() {
    int n = 0; CK(cudaGetDeviceCount(&n));
    if (n != 1) throw std::runtime_error("select one Hopper GPU with CUDA_VISIBLE_DEVICES");
    Device d; CK(cudaGetDeviceProperties(&d.prop, 0)); d.uuid = uuid_str(d.prop.uuid);
    if (d.prop.major != 9) throw std::runtime_error("Hopper GPU required");
    CK(cudaSetDevice(0));
    return d;
}

// A fragments for the whole matrix (same for every cluster): index ((wg*4 + j)*8 + kb)*32 + L, 4 words each.
std::vector<uint32_t> build_A(const sca::Graph& g) {
    std::vector<uint32_t> A(size_t(32) * 4 * 8 * 32 * 4, 0);
    for (int wg = 0; wg < 32; ++wg)
        for (int j = 0; j < 4; ++j)
            for (int kb = 0; kb < 8; ++kb)
                for (int L = 0; L < 32; ++L)
                    for (int r = 0; r < 4; ++r) {
                        const int rho = (L >> 2) + ((r & 1) ? 8 : 0);
                        const int y = (2 * j + rho / 8) * 256 + 8 * wg + (rho % 8);
                        const int kbase = ((r >> 1) ? 128 : 0) + 32 * (L & 3);
                        uint32_t word = 0;
                        for (int i = 0; i < 32; ++i) {
                            const int kap = kbase + i, W = 8 * kb + kap / 32, beta = kap % 32;
                            const int wgx = W / 2, hp = W % 2, lam = beta / 8, rk = beta % 8;
                            const int x = 256 * rk + 8 * wgx + 4 * hp + lam;   // byte = lane 8wg+4h'+lam, bit = round
                            uint32_t bit = 0;
                            if (x < sca::N && y < sca::N && x != y) bit = uint32_t((g.J[x][y >> 6] >> (y & 63)) & 1u);   // J[x][y], as run_trial
                            word |= bit << i;
                        }
                        A[((size_t(wg * 4 + j) * 8 + kb) * 32 + L) * 4 + r] = word;
                    }
    return A;
}

// Integer-range guard: the kernel evaluates z = s*h*65536 + q -/+ corr in int32. Prove no overflow for every step.
void check_ranges(const sca::Tables& tb) {
    const int64_t lim = (int64_t(1) << 31) - 1;
    for (size_t t = 0; t < tb.fourT.size(); ++t) {
        if (tb.fourT[t] <= 0) throw std::runtime_error("fourT must be positive");
        if (tb.kcorr[t] < 0) throw std::runtime_error("negative kcorr not supported");
        const int64_t corr_max = ((int64_t(sca::N) * tb.kcorr[t]) >> 8) + std::llabs(int64_t(tb.kconst[t])) + 1;
        const int64_t zmax = int64_t(sca::N - 1) * 65536 + std::llabs(int64_t(tb.q[t])) + corr_max + int64_t(tb.fourT[t]);
        if (zmax >= lim) throw std::runtime_error("table range exceeds int32 kernel arithmetic at step " + std::to_string(t));
    }
}

int64_t scalar_cut(const sca::Graph& g, const uint64_t* bits) {
    std::array<uint64_t, sca::WORDS> negative{};
    int count_negative=0;
    for (int k=0;k<sca::WORDS;++k) {
        negative[k]=~bits[k];
        if (k+1==sca::WORDS) negative[k]&=((uint64_t(1)<<(sca::N%64))-1);
        count_negative+=__builtin_popcountll(negative[k]);
    }
    int negative_crossings=0;
    for (int i=0;i<sca::N;++i) {
        if (((bits[i/64]>>(i%64))&1)==0) continue;
        for (int k=0;k<sca::WORDS;++k)
            negative_crossings+=__builtin_popcountll(g.J[i][k]&negative[k]);
    }
    return int64_t(count_negative)*(sca::N-count_negative)-2*negative_crossings;
}

struct Launcher {
    int cs = 4, groups = 1;
    bool ons = false, lin = true, mid = false;
    void* fn = nullptr;
    int threads = 0;
    size_t smem = 0;
    int max_clusters = 0;
    const unsigned long long* JT = nullptr;   // for cs == 1 (single-CTA L2 variant)
    template <int CS, int G> void pick() {
        if constexpr(CS==8 && G==1) {
            if(mid) {
                if(ons) fn=reinterpret_cast<void*>(kern::sca_kernel<CS,G,true,true,true>);
                else if(lin) fn=reinterpret_cast<void*>(kern::sca_kernel<CS,G,false,true,true>);
                else fn=reinterpret_cast<void*>(kern::sca_kernel<CS,G,false,false,true>);
                smem=kern::Cfg<CS,G>::TAB_OFF;
                return;
            }
        }
        if (ons) fn = reinterpret_cast<void*>(kern::sca_kernel<CS, G, true, true>);
        else if (lin) fn = reinterpret_cast<void*>(kern::sca_kernel<CS, G, false, true>);
        else fn = reinterpret_cast<void*>(kern::sca_kernel<CS, G, false, false>);
        smem = kern::Cfg<CS, G>::TAB_OFF;
    }
    void setup(int S) {
        if (cs == 1) {   // single CTA per chain, J^T in global memory
            fn = reinterpret_cast<void*>(kern::sca_l2_kernel); threads = 256; smem = 0;
            CK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(&max_clusters, kern::sca_l2_kernel, 256, 0));
            int dev = 0, sms = 0; CK(cudaGetDevice(&dev)); CK(cudaDeviceGetAttribute(&sms, cudaDevAttrMultiProcessorCount, dev));
            max_clusters *= sms;
            return;
        }
        if (cs == 4 && groups == 1) pick<4, 1>();
        else if (cs == 4 && groups == 2) pick<4, 2>();
        else if (cs == 8 && groups == 1) pick<8, 1>();
        else if (cs == 8 && groups == 2) pick<8, 2>();
        else throw std::runtime_error("unsupported --cs/--groups (4|8, 1|2)");
        threads = 32 * (32 / cs);
        smem += size_t((12 * S + 15) / 16) * 16 + size_t(8) * S;
        CK(cudaFuncSetAttribute(fn, cudaFuncAttributeMaxDynamicSharedMemorySize, int(smem)));
        cudaLaunchConfig_t cfg = {}; cudaLaunchAttribute at[1];
        at[0].id = cudaLaunchAttributeClusterDimension; at[0].val.clusterDim.x = cs; at[0].val.clusterDim.y = 1; at[0].val.clusterDim.z = 1;
        cfg.attrs = at; cfg.numAttrs = 1; cfg.blockDim = dim3(threads); cfg.dynamicSmemBytes = smem; cfg.gridDim = dim3(cs);
        CK(cudaOccupancyMaxActiveClusters(&max_clusters, fn, &cfg));
    }
    void launch(int clusters, const kern::Params& p, cudaStream_t st) {
        if (cs == 1) { kern::sca_l2_kernel<<<clusters, 256, 0, st>>>(p, JT); CK(cudaGetLastError()); return; }
        cudaLaunchConfig_t cfg = {}; cudaLaunchAttribute at[1];
        at[0].id = cudaLaunchAttributeClusterDimension; at[0].val.clusterDim.x = cs; at[0].val.clusterDim.y = 1; at[0].val.clusterDim.z = 1;
        cfg.attrs = at; cfg.numAttrs = 1; cfg.blockDim = dim3(threads); cfg.dynamicSmemBytes = smem; cfg.gridDim = dim3(cs * clusters);
        cfg.stream = st;
        void* args[] = {const_cast<kern::Params*>(&p)};
        CK(cudaLaunchKernelExC(&cfg, fn, args));
    }
};

}  // namespace host


__global__ void final_host_layout(const uint8_t* lanes, const int32_t* partials,
                                  int sumw, uint32_t* packed, int32_t* cuts) {
    const int c=blockIdx.x, l=threadIdx.x;
    const unsigned int byte=lanes[c*256+l];
    for(int k=0;k<8;++k){
        const int i=k*256+l;
        const uint32_t word=__ballot_sync(0xffffffffu, i<2000 && ((byte>>k)&1u));
        if((l&31)==0) packed[c*64+i/32]=word;
    }
    int sh=partials[c*256+l];
    for(int d=16;d;d>>=1) sh+=__shfl_down_sync(0xffffffffu,sh,d);
    __shared__ int per_warp[8];
    if((l&31)==0) per_warp[l/32]=sh;
    __syncthreads();
    if(l<32){
        int v=l<8?per_warp[l]:0;
        for(int d=16;d;d>>=1) v+=__shfl_down_sync(0xffffffffu,v,d);
        if(l==0) cuts[c]=(sumw+v/2)/2;
    }
}


#include "tail.cuh"
#include "paired_main.cuh"
