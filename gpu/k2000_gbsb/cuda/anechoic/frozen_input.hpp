#pragma once
#include "sca_ref.hpp"
#include <cstdint>
#include <fstream>
#include <string>

inline sca::Tables load_frozen_input(const std::string& path, int steps) {
    std::ifstream in(path, std::ios::binary);
    if (!in || (steps < 2 || steps > 21400)) throw std::runtime_error("invalid frozen input");
    sca::Tables tb;
    for (int step = 0; step < steps; ++step) {
        int32_t row[4];
        in.read(reinterpret_cast<char*>(row), sizeof(row));
        if (!in || row[0] <= 0 || row[3] < 0) throw std::runtime_error("incomplete or incompatible frozen input");
        tb.fourT.push_back(row[0]);
        tb.q.push_back(row[1]);
        tb.kconst.push_back(row[2]);
        tb.kcorr.push_back(static_cast<int64_t>(row[3]));
    }
    if (in.peek() != std::char_traits<char>::eof()) throw std::runtime_error("trailing frozen input");
    return tb;
}
