#include "../shared.cuh"
#include "start.cuh"
#include "../anechoic/sca_ref.hpp"
__global__ void initial_signs(uint32_t first,int n,uint32_t* output) {
    int trial=blockIdx.x/8,site=(blockIdx.x%8)*256+threadIdx.x;
    bool positive=site<N && paired_initial::amplitude(first+trial,site)>0;
    unsigned value=__ballot_sync(~0u,positive);
    if(!(threadIdx.x%32))output[trial*64+site/32]=value;
}
int main(int argc,char** argv)try{
    device();auto st=make_stream();
    if(argc!=3)throw std::runtime_error("sign_check first n");
    unsigned first=std::stoul(argv[1]);int n=std::stoi(argv[2]);Buf<uint32_t> words(n*64);
    initial_signs<<<n*8,256,0,st>>>(first,n,words.d);ck(cudaGetLastError());ck(cudaStreamSynchronize(st));
    std::vector<Bitmap> got(n);ck(cudaMemcpy(got.data(),words.d,n*256,cudaMemcpyDeviceToHost));
    for(int trial=0;trial<n;++trial){
        Bitmap expected{};
        for(int lane=0;lane<256;++lane){
            sca::Rng rng;rng.seed(20261004,first+trial,lane);
            for(int k=0;k<8;++k){int site=k*256+lane;unsigned bit=rng.next()>>31;
                if(site<N)expected[site/32]|=bit<<(site%32);}
        }
        if(expected!=got[trial])throw std::runtime_error("initial sign mismatch for "+std::to_string(first+trial));
    }
    std::cout<<n<<" complete initial sign vectors match"<<std::endl;return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}
