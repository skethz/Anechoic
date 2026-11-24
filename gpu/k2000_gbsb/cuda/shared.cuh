#pragma once
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

constexpr int N=2000,P=2048,M=21400;
constexpr uint64_t master=2026112403ULL;
inline void ck(cudaError_t r){if(r!=cudaSuccess)throw std::runtime_error(cudaGetErrorString(r));}
inline void ck(cublasStatus_t r){if(r!=CUBLAS_STATUS_SUCCESS)throw std::runtime_error("cuBLAS error "+std::to_string(int(r)));}
template<class T> struct Buf {
    T* d=nullptr;
    explicit Buf(size_t n){ck(cudaMalloc(&d,sizeof(T)*n));}
    ~Buf(){if(d)cudaFree(d);}
    Buf(const Buf&)=delete;
    Buf& operator=(const Buf&)=delete;
};
inline cudaDeviceProp device() {
    int count=0;ck(cudaGetDeviceCount(&count));
    if(count!=1)throw std::runtime_error("expected one visible GH200");ck(cudaSetDevice(0));
    cudaDeviceProp p{}; ck(cudaGetDeviceProperties(&p,0));
    if(p.major!=9)throw std::runtime_error("select one Hopper GPU with CUDA_VISIBLE_DEVICES");
    std::cout<<p.name<<" SM "<<p.multiProcessorCount<<std::endl;
    return p;
}
inline cudaStream_t make_stream() {
    int low=0,high=0;ck(cudaDeviceGetStreamPriorityRange(&low,&high));
    cudaStream_t s;ck(cudaStreamCreateWithPriority(&s,cudaStreamNonBlocking,low));return s;
}
__host__ __device__ inline double initial_x(uint32_t id,int i) {
    // SplitMix64 output permutation over distinct input coordinates.
    uint64_t k=(uint64_t(id)<<11)+uint32_t(i);
    uint64_t z=master+0x9e3779b97f4a7c15ULL*(k+1);
    z=(z^(z>>30))*0xbf58476d1ce4e5b9ULL;z=(z^(z>>27))*0x94d049bb133111ebULL;z^=z>>31;
    // 52 bits leave both midpoints at the endpoints representable.
    return .2*((double(z>>12)+.5)*0x1.0p-52-.5);
}
inline std::vector<int8_t> graph(const char* path) {
    std::ifstream f(path,std::ios::binary);std::vector<unsigned char> raw(std::istreambuf_iterator<char>(f),{});
    if(raw.size()!=12+N*256||std::memcmp(raw.data(),"SNOWGPU1",8))throw std::runtime_error("bad graph");
    uint32_t n=0;std::memcpy(&n,raw.data()+8,4);if(n!=N)throw std::runtime_error("dimension");
    std::vector<int8_t> j(size_t(N)*N,0);int sumw=0;
    for(int i=0;i<N;++i)for(int k=0;k<N;++k)if(k!=i){
        int sig=int((raw[12+i*256+k/8]>>(k%8))&1U)*2-1;
        j[size_t(i)*N+k]=sig;if(k>i)sumw-=sig;
    }
    if(sumw!=-1040)throw std::runtime_error("bad graph sum");
    for(int i=0;i<N;++i)for(int k=0;k<i;++k)if(j[size_t(i)*N+k]!=j[size_t(k)*N+i])throw std::runtime_error("asymmetric graph");
    return j;
}
using Bitmap=std::array<uint32_t,64>;
inline int host_cut(const std::vector<int8_t>& j,const Bitmap& b) {
    int cut=0;for(int i=0;i<N;++i){int si=(b[i/32]>>(i%32))&1;
        for(int k=i+1;k<N;++k)if(si!=int((b[k/32]>>(k%32))&1))cut-=j[size_t(i)*N+k];}
    return cut;
}
__device__ __forceinline__ int quant(float x){return __float2int_rn(x*16384.0f);}
__device__ __forceinline__ void mixed_step(float& x,float& y,float& p,int field,float c,float inv) {
    // Separate, round-to-nearest binary32 operations; use the same specification for both GPU paths.
    const float factor=__fsub_rn(1.f,__fmul_rn(__fmul_rn(.196f,x),x));
    p=__fsub_rn(p,__fmul_rn(__fmul_rn(factor,p),inv));
    const float force=__fsub_rn(__fmul_rn(c,__fmul_rn(float(field),0x1p-14f)),__fmul_rn(p,x));
    y=__fadd_rn(y,__fmul_rn(1.25f,force));
    x=__fadd_rn(x,__fmul_rn(1.25f,y));
    if(fabsf(x)>1.f){x=copysignf(1.f,x);y=0.f;}
}
