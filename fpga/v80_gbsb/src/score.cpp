#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
constexpr int N=2000,W=32;
using Bits=std::array<uint64_t,W>;
int main(int ac,char** av){try{
    if(ac!=4) throw std::runtime_error("signed-upper.i8 spins.bin output.cuts.i32");
    std::ifstream weights(av[1],std::ios::binary|std::ios::ate);
    if(weights.tellg()!=std::streampos(N*(N-1)/2))throw std::runtime_error("wrong signed upper-triangle size");
    weights.seekg(0);std::vector<int8_t> edges(N*(N-1)/2);weights.read(reinterpret_cast<char*>(edges.data()),edges.size());
    std::vector<Bits> valid(N),pos(N);int npos=0,nneg=0,edge=0;
    for(int i=0;i<N;++i)for(int j=i+1;j<N;++j){
       int w=edges[edge++];auto b=uint64_t(1)<<(j%64);valid[i][j/64]|=b;
       if(w==1){pos[i][j/64]|=b;++npos;}else if(w==-1){++nneg;}else throw std::runtime_error("wrong signed edge value");
    }
    if(npos!=998980||nneg!=1000020)throw std::runtime_error("source weight histogram");
    std::ifstream in(av[2],std::ios::binary|std::ios::ate);auto size=in.tellg();
    if(size<=0||size_t(size)%sizeof(Bits))throw std::runtime_error("spin file length");
    std::vector<Bits> spin(size_t(size)/sizeof(Bits));in.seekg(0);in.read(reinterpret_cast<char*>(spin.data()),size);
    std::vector<int32_t> result(spin.size());int invalid=0;
    #pragma omp parallel for reduction(+:invalid) schedule(static)
    for(size_t k=0;k<spin.size();++k){
       const Bits& s=spin[k];if(s.back()>>(N%64)){++invalid;continue;}
       int cut=0;
       for(int i=0;i<N;++i){
          uint64_t same=s[i/64]>>(i%64)&1U;uint64_t signmask=uint64_t(0)-same;int here=0;
          #pragma omp simd reduction(+:here)
          for(int j=0;j<W;++j){
             uint64_t crossed=(s[j]^signmask)&valid[i][j];
             here+=2*__builtin_popcountll(crossed&pos[i][j])-__builtin_popcountll(crossed);
          }
          cut+=here;
       }
       result[k]=cut;
    }
    if(invalid)throw std::runtime_error("nonzero padding");
    std::ofstream out(av[3],std::ios::binary);out.write(reinterpret_cast<char*>(result.data()),result.size()*sizeof(int32_t));
    if(!out)throw std::runtime_error("output write");
    std::cout<<result.size()<<" independent signed graph cuts\n";return 0;
}catch(const std::exception& ex){std::cerr<<ex.what()<<'\n';return 1;}}
