struct Trigger {
    int sweep, a, b, c, gain, tested, stable;
};
struct TriangleScratch {
    unsigned bad[2][32];
    unsigned short codes[4][2000];  // low 11 bits are site+1, then sign and margin-three flag.
    int choice[4][4];
};
__device__ __forceinline__ int tri_site(int code) { return (code&2047)-1; }
__device__ __forceinline__ int tri_sign(int code) { return (code&2048)?1:-1; }
__device__ __forceinline__ int tri_edge(const unsigned long long* graph,int i,int j) {
    return int((graph[size_t(i)*32+(j>>6)]>>(j&63))&1ULL)*2-1;
}
__device__ __forceinline__ bool aligned(const unsigned long long* graph,int a,int b) {
    return tri_edge(graph,tri_site(a),tri_site(b))*tri_sign(a)*tri_sign(b)>0;
}
// One root lane per qualified chain; sorted compaction gives the lexicographic tie order.
__device__ __noinline__ void choose_triple(const unsigned long long* graph,
                                            unsigned short* list,int* choice) {
    int n=0;
    for(int site=0;site<N;++site) {const unsigned short code=list[site];if(code)list[n++]=code;}
    choice[0]=0;
    for(int i=0;i<n;++i) for(int j=i+1;j<n;++j) {
        int a=list[i],b=list[j];
        int high=((a>>12)&1)+((b>>12)&1);
        if(high>1||!aligned(graph,a,b))continue;
        for(int k=j+1;k<n;++k) {
            int c=list[k], threes=high+((c>>12)&1);
            int gain=3-2*threes;
            if(gain<=choice[0]||!aligned(graph,a,c)||!aligned(graph,b,c))continue;
            choice[0]=gain;choice[1]=a;choice[2]=b;choice[3]=c;
            if(gain==3)return;
        }
    }
}
