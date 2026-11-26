// Stream-level test vectors for the v6 core (sca_core.v): input beats and the expected output words, from sca_ref.hpp.
// Build: c++ -O2 -std=c++17 -DSCA_LANES=256 gen_vectors.cpp -o gen_vectors
// Usage: gen_vectors <K2000.bin> <outdir> O1|O5
#include "tables.hpp"
#include <cmath>
#include <cstdlib>

int main(int argc, char** argv) {
    using namespace sca;
    if (argc != 6) {
        std::fprintf(stderr,"usage: gen_vectors graph dir schedule offset trials\n");
        return 2;
    }
    const std::string dir = argv[2];
    const uint32_t trial_offset = std::stoul(argv[4]);
    const int trial_count = std::stoi(argv[5]);
    if (trial_count <= 0 || trial_count>32) return 2;
    Graph g = load_graph(argv[1]);
    std::vector<int8_t> dense = dense_matrix(g);
    FILE* fs = std::fopen((dir + "/stim.hex").c_str(), "w");
    FILE* fe = std::fopen((dir + "/expect.hex").c_str(), "w");
    FILE* fc = std::fopen((dir + "/counts.txt").c_str(), "w");
    if (!fs || !fe || !fc) { std::perror("open"); return 1; }
    auto beat = [&](uint64_t hi, uint64_t lo) { std::fprintf(fs, "%016llx%016llx\n", (unsigned long long)hi, (unsigned long long)lo); };
    auto word = [&](uint64_t v) { std::fprintf(fe, "%016llx\n", (unsigned long long)v); };

    struct Case { const char* name; int S; double kappa; int trials; int trace; int keep; };
    const std::string schedule = argv[3];
    if (schedule != "O1" && schedule != "O5" && schedule != "O1off" && schedule != "B5") return 2;
    const int steps = schedule == "O5" ? 760 : (schedule == "B5" ? 560 : 280);
    const double kappa = schedule == "O5" ? 2.0 : (schedule == "O1" ? 1.75 : 0);
    const std::vector<Case> cases = {{schedule.c_str(), steps, kappa, trial_count, 1, 0}};
    long nbeats = 0, nwords = 0;
    for (size_t ci = 0; ci < cases.size(); ++ci) {
        const Case& c = cases[ci];
        v80host::Schedule schedule_flags;
        schedule_flags.S = c.S; schedule_flags.q = schedule == "B5" ? 4 : 8;
        schedule_flags.t0 = schedule == "B5" ? 30 : 15;
        schedule_flags.t1 = 5; schedule_flags.kappa = c.kappa; schedule_flags.ramp = true;
        Tables tb = v80host::build_tables(schedule_flags);
        const uint64_t seed = 20261004;
        const uint32_t off = trial_offset;
        const int loadJ = ci == 0;
        beat(seed, (uint64_t(c.keep) << 34) | (uint64_t(c.trace) << 33) | (uint64_t(loadJ) << 32) | (uint64_t(c.S) << 16) | uint64_t(c.trials));
        beat(uint64_t(g.sumw), uint64_t(off));
        nbeats += 2;
        if (loadJ) {
            for (int x = 0; x < NP; ++x)
                for (int cc = 0; cc < 16; ++cc) beat(g.J[x][2 * cc + 1], g.J[x][2 * cc]);
            nbeats += NP * 16;
        }
        for (int t = 0; t < (c.keep ? 0 : c.S); ++t) {
            if (tb.kcorr[t] != int64_t(int32_t(tb.kcorr[t]))) { std::fprintf(stderr, "kcorr does not fit int32\n"); return 1; }
            beat((uint64_t(uint32_t(tb.kcorr[t])) << 32) | uint64_t(uint32_t(tb.kconst[t])),
                 (uint64_t(uint32_t(tb.q[t])) << 32) | uint64_t(uint32_t(tb.fourT[t])));
        }
        nbeats += c.keep ? 0 : c.S;
        for (int tr = 0; tr < c.trials; ++tr) {
            Result r = run_trial(g, tb, seed, off + tr, true, dense.data());
            for (int w = 0; w < WORDS; ++w) word(r.spins[w]);
            word(uint64_t(r.cut)); word(uint64_t(r.flips));
            nwords += WORDS + 2;
            if (c.trace) { for (int t = 0; t < c.S; ++t) word(uint64_t(uint32_t(r.n_lin[t]))); nwords += c.S; }
            std::printf("%-20s trial %d: cut %lld flips %lld\n", c.name, int(off + tr), (long long)r.cut, (long long)r.flips);
        }
    }
    std::fprintf(fc, "%ld %ld\n", nbeats, nwords);
    std::fclose(fs); std::fclose(fe); std::fclose(fc);
    std::printf("beats %ld words %ld\n", nbeats, nwords);
    return 0;
}
