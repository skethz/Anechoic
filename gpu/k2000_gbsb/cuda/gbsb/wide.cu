#include "../shared.cuh"
#include "../easy/rule.cuh"
#include "start.cuh"
#include "objective.cuh"
#include <cooperative_groups.h>
namespace cg=cooperative_groups;
constexpr int Width=120,SegmentLength=50;
struct Winner { unsigned bits[64]; int cut,index; };
#include "wide_core.cuh"
__global__ void select_result(const uint32_t* bits,const int* cuts,Winner* win){
    __shared__ int best;
    if(!threadIdx.x){best=0;for(int c=1;c<Width;++c)if(cuts[c]>cuts[best])best=c;win->cut=cuts[best];win->index=best;}
    __syncthreads();win->bits[threadIdx.x]=bits[best*64+threadIdx.x];
}
int main(int argc,char** argv)try{
    if(argc!=8)throw std::runtime_error("twelve graph first_id rounds out_prefix steps amplitude dt");
    int first_id=std::stoi(argv[2]),rounds=std::stoi(argv[3]),steps=std::stoi(argv[5]);float amp=std::stof(argv[6]),dt=std::stof(argv[7]);
    if(first_id<0||rounds<1||rounds>1000||steps<1||steps>21400)throw std::runtime_error("invalid range");
    auto dev=device();auto st=make_stream();auto weights=graph(argv[1]);

    std::vector<uint32_t> upper(N*64),positive(N*64);
    for(int i=0;i<N;++i){
        for(int k=i+1;k<N;++k){upper[i*64+k/32]|=1u<<(k%32);if(weights[i*N+k]<0)positive[i*64+k/32]|=1u<<(k%32);}}
    Buf<int8_t> j(N*N),columns(2*Width*N);
    Buf<int> field(2*Width*N),cuts(Width),progress(1);Buf<float> x(Width*N),y(Width*N),p(Width*N),inv(steps);
    Buf<uint32_t> first(1),bits(Width*64),pos(positive.size()),up(upper.size());Buf<Winner> win(1);
    ck(cudaMemcpy(j.d,weights.data(),weights.size(),cudaMemcpyHostToDevice));ck(cudaMemcpy(pos.d,positive.data(),positive.size()*4,cudaMemcpyHostToDevice));
    ck(cudaMemcpy(up.d,upper.data(),upper.size()*4,cudaMemcpyHostToDevice));
    std::vector<float> table(steps);for(int i=0;i<steps;++i)table[i]=1.f/float(steps-i);
    ck(cudaMemcpy(inv.d,table.data(),steps*4,cudaMemcpyHostToDevice));float c=float(1./(2.*sqrt(double(N))));
    cublasHandle_t handle;ck(cublasCreate(&handle));ck(cublasSetStream(handle,st));
    // A is symmetric, so its row-major upload is also the correct column-major matrix.
    Buf<unsigned char> scratch(32<<20);ck(cublasSetWorkspace(handle,scratch.d,32<<20));
    const int one=1,zero=0,blocks=(Width*N+255)/256;
    auto capture=[&](int length){
        cudaGraph_t g;cudaGraphExec_t exe;ck(cudaStreamBeginCapture(st,cudaStreamCaptureModeThreadLocal));
        for(int m=0;m<length;++m){
            ck(cublasGemmEx(handle,CUBLAS_OP_T,CUBLAS_OP_N,N,2*Width,N,&one,
                            j.d,CUDA_R_8I,N,columns.d,CUDA_R_8I,N,&zero,field.d,CUDA_R_32I,N,CUBLAS_COMPUTE_32I,CUBLAS_GEMM_DEFAULT));
            wide_step<<<blocks,256,0,st>>>(x.d,y.d,p.d,columns.d,field.d,inv.d,progress.d,c,amp,dt,m,SegmentLength);
        }
        next_segment<<<1,1,0,st>>>(progress.d);
        ck(cudaGetLastError());ck(cudaStreamEndCapture(st,&g));ck(cudaGraphInstantiate(&exe,g,0));ck(cudaGraphDestroy(g));return exe;
    };
    cudaGraphExec_t segment=steps>=SegmentLength?capture(SegmentLength):nullptr;
    cudaGraphExec_t rem=steps%SegmentLength?capture(steps%SegmentLength):nullptr;
    cudaGraph_t graph_op;cudaGraphExec_t exec;ck(cudaStreamBeginCapture(st,cudaStreamCaptureModeThreadLocal));
    pack_batch<<<Width*8,256,0,st>>>(x.d,bits.d,Width);
    objective<<<Width,256,0,st>>>(bits.d,up.d,pos.d,cuts.d);
    select_result<<<1,64,0,st>>>(bits.d,cuts.d,win.d);ck(cudaGetLastError());ck(cudaStreamEndCapture(st,&graph_op));ck(cudaGraphInstantiate(&exec,graph_op,0));
    cudaEvent_t t0,t1;ck(cudaEventCreate(&t0));ck(cudaEventCreate(&t1));uint32_t* host_id;Winner* answer;
    ck(cudaMallocHost(&host_id,4));ck(cudaMallocHost(&answer,sizeof(Winner)));
    std::string pref=argv[4];std::ofstream csv(pref+".csv"),trials(pref+".trials.csv"),spins(pref+".spins",std::ios::binary);
    csv<<"round,first_id,winner,cut,device_ms,host_ms\n"<<std::setprecision(12);trials<<"trial,cut\n";
    std::vector<Bitmap> all(Width);std::vector<int> scores(Width);
    for(int r=-3;r<rounds;++r){
        *host_id=r<0?0xd1590000U+(r+3)*Width:uint32_t(first_id+r*Width);
        auto t=std::chrono::steady_clock::now();ck(cudaEventRecord(t0,st));ck(cudaMemcpyAsync(first.d,host_id,4,cudaMemcpyHostToDevice,st));
        wide_init<<<blocks,256,0,st>>>(first.d,x.d,y.d,p.d,columns.d);ck(cudaMemsetAsync(progress.d,0,4,st));
        for(int k=0;k<steps/SegmentLength;++k)ck(cudaGraphLaunch(segment,st));
        if(rem)ck(cudaGraphLaunch(rem,st));
        ck(cudaGraphLaunch(exec,st));ck(cudaEventRecord(t1,st));ck(cudaMemcpyAsync(answer,win.d,sizeof(Winner),cudaMemcpyDeviceToHost,st));ck(cudaStreamSynchronize(st));
        double host=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();float ms;ck(cudaEventElapsedTime(&ms,t0,t1));
        if(r>=0){ck(cudaMemcpy(all.data(),bits.d,Width*sizeof(Bitmap),cudaMemcpyDeviceToHost));ck(cudaMemcpy(scores.data(),cuts.d,Width*4,cudaMemcpyDeviceToHost));
            int best=std::max_element(scores.begin(),scores.end())-scores.begin();
            if(best!=answer->index||scores[best]!=answer->cut||std::memcmp(answer->bits,all[best].data(),256))throw std::runtime_error("winner mismatch");
            csv<<r<<','<<*host_id<<','<<best<<','<<scores[best]<<','<<ms<<','<<host<<'\n';
            for(int i=0;i<Width;++i)trials<<*host_id+i<<','<<scores[i]<<'\n';
            spins.write(reinterpret_cast<const char*>(all.data()),all.size()*sizeof(Bitmap));}
        if(r>=0&&((r+1)%50==0||r+1==rounds)){csv.flush();trials.flush();spins.flush();std::cout<<r+1<<" requests; last ms "<<ms<<std::endl;}
        if(!csv||!trials||!spins)throw std::runtime_error("write error");
        std::this_thread::sleep_for(std::chrono::duration<double,std::milli>(std::min(10.,std::max(.5,double(ms)*.2))));
    }
    ck(cudaGraphExecDestroy(exec));ck(cudaGraphDestroy(graph_op));if(segment)ck(cudaGraphExecDestroy(segment));if(rem)ck(cudaGraphExecDestroy(rem));
    ck(cublasDestroy(handle));return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}
