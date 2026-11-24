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
using Clock=std::chrono::steady_clock;
double ms(Clock::time_point t){return std::chrono::duration<double,std::milli>(Clock::now()-t).count();}
int main(int argc,char**argv) try{
    if(argc!=8 && argc!=9)throw std::runtime_error("usage: host graph uuid mhz first_id logical_requests output_dir expected_first_request_spins [steps]");
    const int steps = argc==9 ? std::stoi(argv[8]) : 21400;
    if(steps!=1000 && steps!=3650 && steps!=21400)throw std::runtime_error("expected 1000, 3650 or 21400 steps");
    const auto graph=sca::load_graph(argv[1]);const std::string uuid=argv[2];double mhz=std::stod(argv[3]);
    unsigned first=std::stoul(argv[4]);int requests=std::stoi(argv[5]);const std::filesystem::path dest(argv[6]);
    if(graph.sumw!=-1040||!std::isfinite(mhz)||mhz<=0||mhz>500||requests<1||requests>1000||uint64_t(first)+120ul*requests>=UINT32_MAX)throw std::runtime_error("input range");
    std::array<uint64_t,120*32> expected{};
    std::ifstream g(argv[7],std::ios::binary);g.read(reinterpret_cast<char*>(expected.data()),expected.size()*8);
    if(!g||g.peek()!=std::char_traits<char>::eof())throw std::runtime_error("expected 120 matched GH200 spin vectors");
    if(!std::filesystem::create_directory(dest))throw std::runtime_error("fresh output directory required");
    std::vector<uint64_t> tiled(62500,0);
    for(int i=0;i<2000;++i)for(int j=0;j<2000;++j){
        const auto pos=(i==j)?1u:(graph.J[i][j/64]>>(j%64))&1u;
        tiled[(125*(i/16)+j/16)*4+(i%16)/4]|=uint64_t(pos)<<((i%4)*16+j%16);
    }
    std::vector<float> inv(steps);
    for(int t=0;t<steps;++t)inv[t]=1.f/(steps-t);
    Device dev;if(dev.uuid()!=uuid)throw std::runtime_error("wrong image");
    check(ami_dev_request_access(dev.h),"request AMI access");
    if(dev.rd(0,SCA_TIMER_ID)!=TIMER_MAGIC||!(dev.rd(0,0)&4))throw std::runtime_error("timer unavailable or engine busy");
    dev.write(J_OFF,tiled.data(),tiled.size()*8);dev.write(TAB_OFF,inv.data(),inv.size()*4);
    dev.wr64(0,XSCA_V80_CONTROL_ADDR_JTILES_DATA,HBM+J_OFF);
    dev.wr64(0,XSCA_V80_CONTROL_ADDR_INVERSE_DATA,HBM+TAB_OFF);
    dev.wr64(0,XSCA_V80_CONTROL_ADDR_RESULTS_DATA,HBM+OUT_BASE);
    dev.wr(0,XSCA_V80_CONTROL_ADDR_HORIZON_DATA,steps);
    dev.wr(0,XSCA_V80_CONTROL_ADDR_STOP_DATA,steps);
    dev.wr(0,0x04,0);
    struct Wave {uint64_t cycles;double host;std::array<uint64_t,398> words;};
    auto launch=[&](unsigned id,bool load,Wave& w){
        const auto begin=Clock::now();
        if(!(dev.rd(0,0)&4))throw std::runtime_error("busy before launch");
        dev.wr(0,XSCA_V80_CONTROL_ADDR_FIRST_DATA,id);dev.wr(0,XSCA_V80_CONTROL_ADDR_LOAD_J_DATA,load?1:0);
        dev.wr(0,0,1);
        while(!(dev.rd(0,0)&2))if(ms(begin)>900000)throw std::runtime_error("kernel timeout");
        w.cycles=dev.cycles(0);if(!w.cycles)throw std::runtime_error("zero device cycles");
        auto data=dev.read(OUT_BASE,w.words.size()*8);std::memcpy(w.words.data(),data.data(),w.words.size()*8);
        dev.wr(0,0,0x10);w.host=ms(begin);
    };
    Wave warm{};launch(427000000,true,warm);
    std::ofstream csv(dest/"waves.csv"),groups(dest/"requests.csv"),rows(dest/"trials.csv"),bits(dest/"spins.bin",std::ios::binary);
    csv<<"group,wave,first_trial,cut,cycles,host_ms\n"<<std::setprecision(12);groups<<"group,first_trial,cut,sum_wave_cycles,host_ms\n"<<std::setprecision(12);
    rows<<"trial,lane,cut\n";
    for(int b=0;b<requests;++b){
        std::array<Wave,10> waves{};int64_t best=INT64_MIN;uint64_t cycles=0;const unsigned base=first+120*b;
        auto begin=Clock::now();
        for(int w=0;w<10;++w){launch(base+12*w,false,waves[w]);cycles+=waves[w].cycles;best=std::max(best,int64_t(waves[w].words[397]));}
        const auto wall=ms(begin);
        for(int w=0;w<10;++w){
            const auto& a=waves[w].words;int pick=0;int64_t cut=INT64_MIN;
            for(int h=0;h<12;++h){
                auto* state=a.data()+33*h;auto c=optimum::crossing_cut(graph,state);
                if((state[31]>>16)||int64_t(state[32])!=c)throw std::runtime_error("signed cut differs from board output");
                if(!b&&std::memcmp(state,expected.data()+32*(w*12+h),256))throw std::runtime_error("primary GH200 and V80 endpoints differ");
                if(c>cut){cut=c;pick=h;}rows<<base+12*w+h<<','<<h<<','<<c<<'\n';bits.write(reinterpret_cast<const char*>(state),256);
            }
            if(unsigned(pick)!=a[396]||cut!=int64_t(a[397]))throw std::runtime_error("device winner mismatch");
            csv<<b<<','<<w<<','<<base+12*w<<','<<cut<<','<<waves[w].cycles<<','<<waves[w].host<<'\n';
        }
        groups<<b<<','<<base<<','<<best<<','<<cycles<<','<<wall<<'\n';
        if(b%10==9||b==requests-1){std::cout<<b+1<<'/'<<requests<<std::endl;groups.flush();csv.flush();rows.flush();bits.flush();}
        if(!groups||!csv||!rows||!bits)throw std::runtime_error("evidence write failed");
    }
    return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}
