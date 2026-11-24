// Physical runner for the v6 engine (RTL core + HLS front end, same register map as v5.2) with 1..12 replicated engines.
// (Copy of host_sca_multi.cpp; only the engine limit and the per-engine trace stride differ.)
// --verify: seeded trials with per-step trace, each checked bit for bit against sca_ref.hpp (build with -DSCA_LANES=256).
// --cohort: timed trials. Every round starts all engines, then polls them; each engine's passive counter gives its own
// start-to-done cycles and the round time is their maximum. Every returned state is rescored independently on the host.
// Control windows: BAR0 offset CONTROL + e*0x1000. HBM (BAR2): J 0x0, packed tables 0x80000, out_e 0x100000 + e*0x40000,
// trace_e 0x400000 + e*0x100000 (1 MiB per engine so that 12 engines fit the 16 MiB BAR2 window).
#include "optimum_tables.hpp"
#include "xsca_v80_hw.h"
#include <ami.h>
#include <ami_device.h>
#include <ami_mem_access.h>
#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>

#ifndef SCA_TIMER_ID
#error "define SCA_TIMER_ID / SCA_CYC_LO / SCA_CYC_HI to match prepare_ip.py"
#endif

namespace {
constexpr uint64_t CONTROL = 0x01100000, HBM = 0x004000000000;
constexpr uint32_t J_OFF = 0x000000, TAB_OFF = 0x080000, OUT_BASE = 0x100000, OUT_STRIDE = 0x40000;
constexpr uint32_t TRACE_BASE = 0x400000, TRACE_STRIDE = 0x100000, BAR2_SIZE = 0x01000000;
constexpr uint32_t TIMER_MAGIC = 0x53434131;  // "SCA1"
constexpr int MAX_E = 12;

void check(int status, const char* what) {
    if (status != AMI_STATUS_OK) throw std::runtime_error(std::string(what) + ": " + ami_get_last_error());
}

struct Device {
    ami_device* h = nullptr;
    Device() { check(ami_dev_find("01:00.0", &h), "Find V80"); }
    ~Device() { if (h) ami_dev_delete(&h); }
    std::string uuid() {
        char v[AMI_LOGIC_UUID_SIZE] = {}; check(ami_dev_read_uuid(h, v), "Read UUID");
        std::string r(v); while (!r.empty() && std::isspace((unsigned char)r.back())) r.pop_back(); return r;
    }
    uint32_t rd(int e, uint32_t off) { uint32_t v = 0; check(ami_mem_bar_read(h, 0, CONTROL + e * 0x1000 + off, &v), "Read control"); return v; }
    void wr(int e, uint32_t off, uint32_t v) { check(ami_mem_bar_write(h, 0, CONTROL + e * 0x1000 + off, v), "Write control"); }
    void wr64(int e, uint32_t off, uint64_t v) { wr(e, off, uint32_t(v)); wr(e, off + 4, uint32_t(v >> 32)); }
    std::vector<uint32_t> read(uint32_t off, size_t bytes) {
        if (bytes % 4 || uint64_t(off) + bytes > BAR2_SIZE) throw std::runtime_error("HBM read range");
        std::vector<uint32_t> r(bytes / 4);
        for (size_t w = 0; w < r.size(); w += 4096)
            check(ami_mem_bar_read_range(h, 2, off + w * 4, uint32_t(std::min<size_t>(4096, r.size() - w)), r.data() + w), "Read HBM");
        return r;
    }
    void write(uint32_t off, const void* data, size_t bytes) {
        if (bytes % 4 || uint64_t(off) + bytes > BAR2_SIZE) throw std::runtime_error("HBM write range");
        std::vector<uint32_t> w(bytes / 4); std::memcpy(w.data(), data, bytes);
        for (size_t i = 0; i < w.size(); i += 4096)
            check(ami_mem_bar_write_range(h, 2, off + i * 4, uint32_t(std::min<size_t>(4096, w.size() - i)), w.data() + i), "Write HBM");
        if (read(off, bytes) != w) throw std::runtime_error("HBM staging readback mismatch");
    }
    uint64_t cycles(int e) { return uint64_t(rd(e, SCA_CYC_LO)) | (uint64_t(rd(e, SCA_CYC_HI)) << 32); }
};

uint64_t original_score_word(int64_t cut, int64_t signed_weight_sum) {
    const uint64_t sh = uint64_t(4 * cut - 2 * signed_weight_sum);
    const uint64_t half = (sh + (sh >> 63)) >> 1;
    const uint64_t mixed = uint64_t(signed_weight_sum) + half;
    return (mixed + (mixed >> 63)) >> 1;
}

} // namespace
#include <array>
#include <filesystem>
#include <sstream>
using Clock = std::chrono::steady_clock;
struct Endpoint { std::array<uint64_t,36> words{}; uint64_t cycles=0; };
double elapsed_ms(Clock::time_point begin) {
    return std::chrono::duration<double,std::milli>(Clock::now()-begin).count();
}
int main(int argc,char**argv) try {
    // The 12-engine FPGA completes ten consecutive waves for each measured request of 120 starts.
    if(argc!=9) throw std::runtime_error("board_host graph base_table 1000 expected_uuid clock_mhz first_id groups output_dir");
    const int steps=std::stoi(argv[3]), groups=std::stoi(argv[7]); const auto first=std::stoul(argv[6]);
    const double mhz=std::stod(argv[5]); const std::string uuid=argv[4];
    if(steps!=1000||mhz<=0||mhz>500||groups<1||groups>1000||first+120ul*groups>=UINT32_MAX) throw std::runtime_error("input range");
    const auto g=sca::load_graph(argv[1]);
    if(g.sumw!=-1040) throw std::runtime_error("graph mismatch");
    const auto base_table = optimum::checked_tables("finish", argv[2]);
    sca::Tables table;
    for (int t = 0; t < steps; ++t) {
        const int row = t * 3649 / (steps - 1);
        table.fourT.push_back(base_table.fourT[row]);
        table.q.push_back(base_table.q[row]);
        table.kconst.push_back(base_table.kconst[row]);
        table.kcorr.push_back(base_table.kcorr[row]);
    }
    const auto tab = optimum::hbm_image(table);
    std::vector<uint64_t> J(size_t(sca::NP)*sca::WORDS);
    for(int i=0;i<sca::N;++i)std::copy(g.J[i].begin(),g.J[i].end(),J.data()+size_t(i)*sca::WORDS);
    std::filesystem::path out(argv[8]);if(!std::filesystem::create_directory(out)) throw std::runtime_error("fresh output directory required");
    std::ofstream waves(out/"waves.csv"),requests(out/"requests.csv"),trials(out/"trials.csv"),states(out/"spins.bin",std::ios::binary);
    waves<<"group,wave,first_trial,cut,cycles,host_ms\n"<<std::setprecision(12);
    requests<<"group,first_trial,cut,sum_wave_cycles,host_ms\n"<<std::setprecision(12);
    trials<<"trial,engine,cut,flips,cycles\n";
    Device dev;if(dev.uuid()!=uuid)throw std::runtime_error("board UUID mismatch");
    check(ami_dev_request_access(dev.h),"request device access");
    for(int e=0;e<12;++e)if(dev.rd(e,SCA_TIMER_ID)!=TIMER_MAGIC||!(dev.rd(e,0)&4)) throw std::runtime_error("missing timer or non-idle core");
    dev.write(J_OFF,J.data(),J.size()*8);dev.write(TAB_OFF,tab.data(),tab.size()*8);
    for(int e=0;e<12;++e){
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_J64_DATA,HBM+J_OFF);
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_TAB_IN_DATA,HBM+TAB_OFF);
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_OUT_R_DATA,HBM+OUT_BASE+uint64_t(e)*OUT_STRIDE);
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_TRACE_DATA,HBM+TRACE_BASE+uint64_t(e)*TRACE_STRIDE);
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_SEED_DATA,20261004);
        dev.wr64(e,XSCA_V80_CONTROL_ADDR_SUMW_DATA,uint64_t(g.sumw));
        dev.wr(e,XSCA_V80_CONTROL_ADDR_TRIALS_DATA,1);dev.wr(e,XSCA_V80_CONTROL_ADDR_DO_TRACE_DATA,0);dev.wr(e,0x04,0);
    }
    auto run_wave=[&](uint32_t id,int logical_steps,bool load,Endpoint* dst){
        for(int e=0;e<12;++e){
            dev.wr(e,XSCA_V80_CONTROL_ADDR_S_DATA,logical_steps);
            dev.wr(e,XSCA_V80_CONTROL_ADDR_TRIAL_OFFSET_DATA,id+e);
            dev.wr(e,XSCA_V80_CONTROL_ADDR_LOAD_J_DATA,load?1:2);
            if(!(dev.rd(e,0)&4))throw std::runtime_error("engine busy");
        }
        auto begin=Clock::now();
        for(int e=0;e<12;++e)dev.wr(e,0,1);
        for(int e=0;e<12;++e){
            while(!(dev.rd(e,0)&2))if(elapsed_ms(begin)>30000)throw std::runtime_error("engine timeout");
        }
        for(int e=0;e<12;++e){
            dst[e].cycles=dev.cycles(e);
            if(!dst[e].cycles)throw std::runtime_error("inactive timer");
            const auto raw=dev.read(OUT_BASE+e*OUT_STRIDE,36*8);
            std::memcpy(dst[e].words.data(),raw.data(),36*8);dev.wr(e,0,0x10);
        }
    };
    std::array<Endpoint,120> endpoints{};
    // Load the complete compressed table, then warm the same 1,000-step path on disjoint starts.
    run_wave(427000000,steps,true,endpoints.data());
    run_wave(427000012,steps,false,endpoints.data());
    for(int n=0;n<groups;++n){
        size_t id=first+120ul*n;
        std::array<double,10> wall{};std::array<uint64_t,10> cycle{};
        std::array<int64_t,10> best{};uint64_t sum=0;int64_t top=INT64_MIN;
        auto request_begin=Clock::now();
        for(int w=0;w<10;++w){
            auto wave_begin=Clock::now();auto* ep=endpoints.data()+12*w;
            run_wave(id+12*w,steps,false,ep);best[w]=INT64_MIN;
            for(int e=0;e<12;++e){cycle[w]=std::max(cycle[w],ep[e].cycles);best[w]=std::max(best[w],int64_t(ep[e].words[32]));}
            sum+=cycle[w];top=std::max(top,best[w]);wall[w]=elapsed_ms(wave_begin);
        }
        const double host_ms=elapsed_ms(request_begin);
        for(int w=0;w<10;++w)waves<<n<<','<<w<<','<<id+12*w<<','<<best[w]<<','<<cycle[w]<<','<<wall[w]<<'\n';
        requests<<n<<','<<id<<','<<top<<','<<sum<<','<<host_ms<<'\n';
        for(int k=0;k<120;++k){
            const auto& ep=endpoints[k];const auto& o=ep.words;auto exact=optimum::crossing_cut(g,o.data());
            if(exact<0 || uint64_t(exact)!=o[32] || original_score_word(exact,g.sumw)!=o[32] || o[31]>>16)throw std::runtime_error("endpoint score mismatch");
            trials<<id+k<<','<<k%12<<','<<exact<<','<<o[33]<<','<<ep.cycles<<'\n';
            states.write(reinterpret_cast<const char*>(o.data()),256);
        }
        if(n%50==49||n==groups-1){std::cout<<n+1<<"/"<<groups<<std::endl;waves.flush();requests.flush();trials.flush();states.flush();}
        if(!waves||!requests||!trials||!states)throw std::runtime_error("output failed");
    }
    return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}
