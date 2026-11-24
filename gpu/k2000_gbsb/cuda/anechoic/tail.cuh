namespace polish {
constexpr int N=2000, P=2048, W=P/64, Threads=256, Group=12;
using Word=unsigned long long;
using Spins=std::array<Word,W>;
constexpr int Budgets[]={64,256,1024,3072};
__device__ __forceinline__ unsigned hash32(unsigned x) {
    x^=x>>16;x*=0x7feb352dU;x^=x>>15;x*=0x846ca68bU;return x^(x>>16);
}
__device__ __forceinline__ int warp_max(int x) {
    for(int k=16;k;k>>=1)x=max(x,__shfl_down_sync(~0u,x,k));
    return x;
}
__device__ __forceinline__ int warp_sum(int x) {
    for(int k=16;k;k>>=1)x+=__shfl_down_sync(~0u,x,k);
    return x;
}
__device__ __forceinline__ int signbit_at(const Word* row,int i){return int((row[i>>6]>>(i&63))&1)*2-1;}

__global__ void walk(const int8_t* __restrict__ dense,const Word* __restrict__ packed,int sumw,
 const Word* starts,const Word* original,const Word* guides,const int* forced,const int* origcuts,
 int first_id,int policy,int maxmoves,int points,int stride,int dest_offset,Word* outspins,int* outcuts) {
    const int id=blockIdx.x,t=threadIdx.x,lane=t&31,warp=t>>5;
    const Word* base=starts+id*W;
    const Word* old=original+id*W;
    const Word* guide=guides+id*W;
    __shared__ short gains[P], expires[P];
    __shared__ int8_t spins[P], record[P], guide_s[P];
    __shared__ int warp_tmp[8],current,best,last_record,chosen,chosen_sign,take;
    int subtotal=0;
    for(int i=t;i<N;i+=Threads) {
        const int si=signbit_at(base,i);
        int d=0;
        for(int w=0;w<W;++w)d+=__popcll(packed[size_t(i)*W+w]^base[w]);
        const int g=-si*(N-2*d+si);
        gains[i]=g;subtotal+=g;spins[i]=si;expires[i]=0;guide_s[i]=signbit_at(guide,i);
    }
    int ws=warp_sum(subtotal);if(!lane)warp_tmp[warp]=ws;__syncthreads();
    if(!t){
        int g=0;for(int w=0;w<8;++w)g+=warp_tmp[w];
        current=(2*sumw-g)/4;best=max(current,origcuts[id]);last_record=0;
    }
    __syncthreads();
    for(int i=t;i<N;i+=Threads)record[i]=current>origcuts[id]?spins[i]:signbit_at(old,i);
    __syncthreads();
    const unsigned seed=unsigned(first_id+id);
    const int tenure=policy==0?8:policy==2?64:24;
    const int guided=forced[id];
    int next_point=0;
    for(int step=1;step<=maxmoves;++step) {
        const unsigned rnd=hash32(seed ^ (unsigned(step)*0x9e3779b9U) ^ 0x85ebca6bU);
        const int salt=rnd&2047;
        const bool perturb=policy==3 && step-last_record>=64 && (step%128)<12;
        int key=-1;
        for(int i=t;i<N;i+=Threads) {
            int g=gains[i];
            if(step<=guided ? spins[i]==guide_s[i] : (expires[i]>step && current+g<=best))continue;
            int noise=perturb?int(((unsigned(i)*0x9e3779b9U)^rnd)>>29):0;
            key=max(key,((g+noise+4096)<<11)|(i^salt));
        }
        key=warp_max(key);if(!lane)warp_tmp[warp]=key;__syncthreads();
        if(!warp){
            int k=lane<8?warp_tmp[lane]:-1;k=warp_max(k);
            if(!lane){
                chosen=(k&2047)^salt;chosen_sign=spins[chosen];
                current+=gains[chosen];take=current>best;
                if(take){best=current;last_record=step;}
            }
        }
        __syncthreads();
        const int x=chosen,sg=chosen_sign;
        for(int i=t;i<N;i+=Threads) {
            if(i==x){gains[i]=-gains[i];spins[i]=-sg;expires[i]=step+tenure+1;}
            else gains[i]+=2*int(spins[i])*sg*int(dense[size_t(x)*P+i]);
            if(take)record[i]=spins[i];
        }
        __syncthreads();
        if(step==64||step==256||step==1024||step==3072) {
            int pos=next_point*stride+dest_offset+id;
            if(!t)outcuts[pos]=best;
            auto* dst=reinterpret_cast<unsigned*>(outspins+size_t(pos)*W);
            for(int k=0;k<8;++k){
                int i=t+k*Threads;
                unsigned bits=__ballot_sync(~0u,i<N && record[i]>0);
                if(!lane)dst[k*8+warp]=bits;
            }
            ++next_point;
        }
    }
}

}
