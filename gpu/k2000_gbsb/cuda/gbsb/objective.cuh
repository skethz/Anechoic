#pragma once
__global__ void pack_batch(const float* x,uint32_t* bits,int n){
 int l=threadIdx.x,t=blockIdx.x/8,i=(blockIdx.x%8)*256+l;
 if(t>=n)return;uint32_t word=__ballot_sync(~0u,i<N && x[t*N+i]>=0.f);
 if(!(l&31))bits[t*64+i/32]=word;
}
__global__ void objective(const uint32_t* states,const uint32_t* upper,const uint32_t* positive,int* cuts){
 int t=threadIdx.x,col=blockIdx.x;const auto* b=states+col*64;int here=0;
 for(int i=t;i<N;i+=256){
    uint32_t sign=0u-((b[i/32]>>(i%32))&1u);
    for(int w=i/32;w<63;++w){int k=i*64+w;auto mask=(b[w]^sign)&upper[k];here+=2*__popc(mask&positive[k])-__popc(mask);}
 }
 __shared__ int reduced[8];int l=t%32;
 for(int s=16;s;s/=2)here+=__shfl_down_sync(~0u,here,s);
 if(!l)reduced[t/32]=here;__syncthreads();
 if(t<32){int sum=t<8?reduced[t]:0;for(int s=16;s;s/=2)sum+=__shfl_down_sync(~0u,sum,s);if(!t)cuts[col]=sum;}
}
