#pragma once
#include "sca_ref.hpp"
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace optimum {
constexpr int anneal_steps=3600, tail_steps=50, target_cut=33337;
constexpr uint64_t master_seed=20261124;
inline int steps(const std::string& arm) {
    if (arm=="base") return anneal_steps;
    if (arm=="finish") return anneal_steps + tail_steps;
    throw std::runtime_error("expected schedule arm base or finish");
}
inline sca::Tables checked_tables(const std::string& arm, const std::string& path) {
    const int S=steps(arm);
    std::vector<double> temp(S,6.5), q(S,12.0), zero(S,0.0);
    for (int t=0;t<anneal_steps;++t) {
        temp[t]=15.0*std::pow(4.5/15.0,static_cast<double>(t)/(anneal_steps-1));
        q[t]=8.0;
    }
    auto tb=sca::make_tables(temp,q,zero);
    for (int t=1;t<anneal_steps;++t) {
        const double taper=(t<2520)?1.0:static_cast<double>(3599-t)/1079.0;
        tb.kconst[t]=static_cast<int32_t>(std::llround(2.0*temp[t-1]*taper*65536.0));
    }
    std::ifstream in(path,std::ios::binary);
    if (!in) throw std::runtime_error("cannot open schedule-table file");
    for (int t=0;t<S;++t) {
        const std::array<int64_t,4> expected{{tb.fourT[t],tb.q[t],tb.kconst[t],tb.kcorr[t]}};
        std::array<uint8_t,16> bytes{};
        if(!in.read(reinterpret_cast<char*>(bytes.data()),bytes.size())) throw std::runtime_error("truncated schedule table");
        for (int i=0;i<4;++i) {
            const auto *p=bytes.data()+4*i;
            const uint32_t actual=uint32_t(p[0])|(uint32_t(p[1])<<8)|(uint32_t(p[2])<<16)|(uint32_t(p[3])<<24);
            if (actual!=uint32_t(expected[i]))
                throw std::runtime_error("table differs at zero-based row "+std::to_string(t)+", field "+std::to_string(i));
        }
    }
    if(in.peek()!=std::char_traits<char>::eof()) throw std::runtime_error("trailing schedule table bytes");
    return tb;
}
inline std::vector<uint64_t> hbm_image(const sca::Tables& tb) {
    std::vector<uint64_t> out(4*tb.q.size());
    for (size_t t=0;t<tb.q.size();++t) {
        out[4*t]=uint64_t(uint32_t(tb.fourT[t]))|(uint64_t(uint32_t(tb.q[t]))<<32);
        out[4*t+1]=uint64_t(int64_t(tb.kconst[t]));
        out[4*t+2]=uint64_t(tb.kcorr[t]);
    }
    return out;
}
inline int64_t crossing_cut(const sca::Graph& g,const uint64_t* spins) {
    std::array<uint64_t,sca::WORDS> negative{};
    int num_negative=0;
    for(int w=0;w<sca::WORDS;++w) {
        negative[w]=~spins[w];
        if(w==sca::WORDS-1) negative[w]&=(uint64_t(1)<<(sca::N%64))-1;
        num_negative+=__builtin_popcountll(negative[w]);
    }
    int positive_J_crossings=0;
    for(int x=0;x<sca::N;++x) {
        if (!((spins[x/64]>>(x%64))&1)) continue;
        for(int w=0;w<sca::WORDS;++w)
            positive_J_crossings+=__builtin_popcountll(g.J[x][w]&negative[w]);
    }
    return int64_t(num_negative)*(sca::N-num_negative)-2*positive_J_crossings;
}
}
