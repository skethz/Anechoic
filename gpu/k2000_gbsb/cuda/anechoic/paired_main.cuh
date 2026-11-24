#include <filesystem>

struct WaveAnswer { unsigned bits[64]; int index,cut; };
__global__ void choose_winner(const unsigned* bits,const int* cuts,int width,WaveAnswer* out) {
    __shared__ int pick;
    if(threadIdx.x==0) {
        pick=0;
        for(int i=1;i<width;++i) if(cuts[i]>cuts[pick]) pick=i;
        out->index=pick;out->cut=cuts[pick];
    }
    __syncthreads();
    out->bits[threadIdx.x]=bits[64*pick+threadIdx.x];
}
template<class T> T* device_buffer(size_t n) {
    T* p=nullptr; CK(cudaMalloc(&p,n*sizeof(T))); return p;
}
template<class T> T* upload(const T* data,size_t n) {
    T* p=device_buffer<T>(n); CK(cudaMemcpy(p,data,n*sizeof(T),cudaMemcpyHostToDevice)); return p;
}
template<class T> void copy_back(std::vector<T>& result,const T* p) {
    CK(cudaMemcpy(result.data(),p,result.size()*sizeof(T),cudaMemcpyDeviceToHost));
}
int paired_run(int argc,char**argv) {
    if(argc!=9) throw std::runtime_error("paired graph table steps tail(0|256) width rounds first_id output_dir");
    const int steps=std::stoi(argv[3]),tail=std::stoi(argv[4]),width=std::stoi(argv[5]),rounds=std::stoi(argv[6]),first=std::stoi(argv[7]);
    if((tail!=0&&tail!=256)||(width!=1&&width!=12&&width!=120)||rounds<1) throw std::runtime_error("invalid protocol arguments");
    std::filesystem::path dir(argv[8]);
    if(!std::filesystem::create_directory(dir))throw std::runtime_error("output directory exists");
    auto device=host::open_device();
    std::cout<<device.prop.name<<" "<<"SM "<<device.prop.multiProcessorCount<<std::endl;
    auto graph=sca::load_graph(argv[1]); auto dense=sca::dense_matrix(graph);auto matrix=host::build_A(graph);
    auto table=load_frozen_input(argv[2],steps); host::check_ranges(table);
    kern::Params p{};p.S=steps;p.nchains=width;p.seed=20261004;
    p.graph=reinterpret_cast<unsigned long long*>(upload(graph.J[0].data(),graph.J.size()*sca::WORDS));
    p.A=reinterpret_cast<uint4*>(upload(matrix.data(),matrix.size()));
    p.fourT=upload(table.fourT.data(),steps);p.q=upload(table.q.data(),steps);
    p.kcorr=upload(table.kcorr.data(),steps);p.kconst=upload(table.kconst.data(),steps);
    p.out_spins=device_buffer<uint8_t>(width*256);p.out_sh=device_buffer<int32_t>(width*256);
    p.out_flips=device_buffer<int64_t>(width);p.events=device_buffer<kern::Trigger>(width);
    const auto* dense_dev=upload(dense.data(),dense.size());
    auto* bits=device_buffer<unsigned>(width*64);auto* cut=device_buffer<int>(width);
    auto* tail_bits=device_buffer<unsigned>(2*width*64);auto* tail_cut=device_buffer<int>(2*width);
    auto* forced=device_buffer<int>(width);CK(cudaMemset(forced,0,width*sizeof(int)));
    auto* winner=device_buffer<WaveAnswer>(1);WaveAnswer* answer;CK(cudaMallocHost(&answer,sizeof(WaveAnswer)));
    int low,high;CK(cudaDeviceGetStreamPriorityRange(&low,&high));cudaStream_t st;CK(cudaStreamCreateWithPriority(&st,cudaStreamNonBlocking,low));
    cudaEvent_t start,stop;CK(cudaEventCreate(&start));CK(cudaEventCreate(&stop));
    host::Launcher launch[2];
    for(int a=0;a<1;++a) {
        auto& x=launch[a];x.cs=8;x.groups=1;x.ons=std::any_of(table.kcorr.begin(),table.kcorr.end(),[](int64_t v){return v!=0;});
        x.lin=x.ons;x.mid=a;x.setup(steps > 4096 ? 0 : steps);
        if(x.max_clusters<=0)throw std::runtime_error("no resident clusters");
    }
    std::ofstream rows[2],ends[2],anneals[2],waves(dir/"rounds.csv");
    waves<<"arm,round,first_id,winner,cut,device_ms,host_ms,order\n"<<std::setprecision(10);
    for(int a=0;a<1;++a) {
        std::string key=a?"on":"off";
        rows[a].open(dir/(key+".trials.csv"));ends[a].open(dir/(key+".final.spins"),std::ios::binary);
        anneals[a].open(dir/(key+".anneal.spins"),std::ios::binary);
        rows[a]<<"round,trial_id,anneal_cut,cut,flips,sweep,a,b,c,gain,tested,stable\n";
    }
    std::vector<unsigned> anneal(width*64),final(width*64);std::vector<int> acut(width),fcut(width);
    std::vector<int64_t> flips(width);std::vector<kern::Trigger> fired(width);
    for(int r=-4;r<rounds;++r) {
        uint32_t id=r<0?0xd0000000U+uint32_t((r+4)*width):uint32_t(first+r*width);
        for(int order=0;order<1;++order) {
            int arm=0;p.trial_offset=id;
            auto begin=std::chrono::steady_clock::now();CK(cudaEventRecord(start,st));
            launch[arm].launch((width+3)/4,p,st);
            final_host_layout<<<width,256,0,st>>>(p.out_spins,p.out_sh,graph.sumw,bits,cut);
            unsigned* final_dev=bits;int* fc=cut;
            if(tail) {
                auto* x=reinterpret_cast<polish::Word*>(bits);
                polish::walk<<<width,256,0,st>>>(dense_dev,p.graph,graph.sumw,x,x,x,forced,cut,id,0,256,2,width,0,
                    reinterpret_cast<polish::Word*>(tail_bits),tail_cut);
                final_dev=tail_bits+width*64;fc=tail_cut+width;
            }
            choose_winner<<<1,64,0,st>>>(final_dev,fc,width,winner);CK(cudaGetLastError());
            CK(cudaEventRecord(stop,st));
            CK(cudaMemcpyAsync(answer,winner,sizeof(*answer),cudaMemcpyDeviceToHost,st));CK(cudaStreamSynchronize(st));
            double host_ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
            float ms;CK(cudaEventElapsedTime(&ms,start,stop));
            if(r>=0) {
                copy_back(anneal,bits);copy_back(acut,cut);
                if(tail){copy_back(final,final_dev);copy_back(fcut,fc);}else{final=anneal;fcut=acut;}
                copy_back(flips,p.out_flips);copy_back(fired,p.events);
                int pick=int(std::max_element(fcut.begin(),fcut.end())-fcut.begin());
                if(pick!=answer->index||fcut[pick]!=answer->cut||std::memcmp(answer->bits,final.data()+64*pick,256))throw std::runtime_error("winner mismatch");
                waves<<(arm?"on":"off")<<','<<r<<','<<id<<','<<pick<<','<<answer->cut<<','<<ms<<','<<host_ms<<','<<order<<'\n';
                for(int i=0;i<width;++i){const auto& e=fired[i];
                    rows[arm]<<r<<','<<(id+i)<<','<<acut[i]<<','<<fcut[i]<<','<<flips[i]<<','<<e.sweep<<','<<e.a<<','<<e.b<<','<<e.c<<','<<e.gain<<','<<e.tested<<','<<e.stable<<'\n';
                }
                ends[arm].write(reinterpret_cast<char*>(final.data()),final.size()*sizeof(unsigned));
                anneals[arm].write(reinterpret_cast<char*>(anneal.data()),anneal.size()*sizeof(unsigned));
                if(!ends[arm]||!anneals[arm]||!rows[arm]||!waves)throw std::runtime_error("write failed");
            }
            std::this_thread::sleep_for(std::chrono::microseconds(static_cast<long>(std::min(10000.,std::max(500.,200.*ms)))));
        }
        if(r>=0&&(r%100==99||r+1==rounds)) {
            waves.flush();for(int a=0;a<1;++a){rows[a].flush();ends[a].flush();anneals[a].flush();}
            std::cout<<"rounds "<<r+1<<" of "<<rounds<<std::endl;
        }
    }
    return 0;
}
int main(int argc,char**argv){try{return paired_run(argc,argv);}catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}}
