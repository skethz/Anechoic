#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
extern "C" void sca_v80(const uint64_t*,const float*,uint64_t*,unsigned,int,int,int);
int main(int argc,char**argv) try{
    if(argc<3)throw std::runtime_error("expected graph and independent endpoints");
    std::ifstream in(argv[1],std::ios::binary),expected(argv[2],std::ios::binary);
    char magic[8];uint32_t n;in.read(magic,8);in.read(reinterpret_cast<char*>(&n),4);
    if(!in||std::memcmp(magic,"SNOWGPU1",8)||n!=2000)throw std::runtime_error("wrong graph");
    std::vector<uint64_t> raw(2000*32),packed(62500,0);in.read(reinterpret_cast<char*>(raw.data()),raw.size()*8);
    for(int i=0;i<2000;++i)for(int j=0;j<2000;++j){
        const auto bit= i==j ? 1u : (raw[i*32+j/64]>>(j&63))&1u;
        packed[((i/16)*125+j/16)*4+(i&15)/4]|=uint64_t(bit)<<((i&3)*16+(j&15));
    }
    const int horizon[]={21400,21400,21400,7};
    const int stops[]={0,1,4,7};
    for(int test=0;test<4;++test){
        std::vector<float> inverse(21400);
        for(int t=0;t<horizon[test];++t)inverse[t]=1.f/float(horizon[test]-t);
        std::array<uint64_t,398> out{};
        sca_v80(packed.data(),inverse.data(),out.data(),431100000u+12*(test&1),horizon[test],stops[test],test==0);
        int32_t top=-2147483647;int winner=-1;
        for(int h=0;h<12;++h){
            std::array<uint64_t,32> witness{};expected.read(reinterpret_cast<char*>(witness.data()),256);
            if(!expected||std::memcmp(witness.data(),out.data()+33*h,256))throw std::runtime_error("mismatched full endpoint at test "+std::to_string(test)+" chain "+std::to_string(h));
            int32_t cut=0;
            for(int i=0;i<2000;++i)for(int j=i+1;j<2000;++j){
                bool different=((witness[i/64]>>(i%64))^(witness[j/64]>>(j%64)))&1u;
                if(different)cut+=((raw[i*32+j/64]>>(j&63))&1u)?-1:1;
            }
            if(int64_t(out[33*h+32])!=cut)throw std::runtime_error("device score differs");
            if(cut>top){top=cut;winner=h;}
        }
        if(out[396]!=unsigned(winner)||int64_t(out[397])!=top)throw std::runtime_error("winner differs");
        std::cout<<"horizon "<<horizon[test]<<" steps "<<stops[test]<<": 12 exact endpoints and cut values"<<std::endl;
    }
    if(expected.peek()!=std::char_traits<char>::eof())throw std::runtime_error("extra expected endpoints");
    return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<std::endl;return 1;}
