#pragma once
// Two signed INT8 columns encode every Q2.14 position exactly. The INT32
// tensor product computes 240 column fields for 120 chains in each step.
__device__ __forceinline__ void split_value(int v,int8_t* columns,int chain,int i){
    int low=int(static_cast<signed char>(v&255));
    columns[2*chain*N+i]=static_cast<int8_t>(low);
    columns[(2*chain+1)*N+i]=static_cast<int8_t>((v-low)/256);
}
__global__ void wide_init(const uint32_t* first,float* x,float* y,float* p,int8_t* cols){
    int idx=blockIdx.x*blockDim.x+threadIdx.x;if(idx>=Width*N)return;
    int chain=idx/N,i=idx%N;float v=paired_initial::amplitude(*first+chain,i);
    x[idx]=v;y[idx]=0.f;p[idx]=1.f;split_value(quant(v),cols,chain,i);
}
__global__ void wide_step(float* x,float* y,float* p,int8_t* cols,const int* fields,const float* table,
                          int* progress,float c,float a,float dt,int phase,int stride){
    int idx=blockIdx.x*blockDim.x+threadIdx.x;if(idx>=Width*N)return;
    int chain=idx/N,i=idx%N,offset=(2*chain)*N+i;
    int dot=fields[offset]+256*fields[offset+N];
    float xx=x[idx],yy=y[idx],pp=p[idx];easy_step(xx,yy,pp,dot,c,table[*progress*stride+phase],a,dt);
    x[idx]=xx;y[idx]=yy;p[idx]=pp;split_value(quant(xx),cols,chain,i);
}
__global__ void next_segment(int* progress){++*progress;}
