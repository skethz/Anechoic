#include <stdint.h>

namespace gbsb {
constexpr int N=2000, Lanes=12, Tile=16, Blocks=N/Tile;
static_assert(Blocks*Tile==N,"complete 16-spin tiles");
inline uint64_t mix(uint64_t x){
    x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;
    x=(x^(x>>27))*0x94d049bb133111ebULL;
    return x^(x>>31);
}
inline uint32_t rot(uint32_t x,unsigned n){return (x<<n)|(x>>(32-n));}
float initial(unsigned id,int spin){
    constexpr uint64_t stride=0x9e3779b97f4a7c15ULL;
    const uint64_t key=20261004ULL^(uint64_t(id)<<20)^(uint64_t(spin%256)<<48)^0x5ca0f00dULL;
    const uint64_t a=mix(key+stride),b=mix(key+2*stride);
    uint32_t s0=uint32_t(a),s1=uint32_t(a>>32),s2=uint32_t(b),s3=uint32_t(b>>32),out=0;
    if(!(s0|s1|s2|s3))s0=1;
    for(int k=0;k<=spin/256;++k){
#pragma HLS LOOP_TRIPCOUNT min=1 max=8
        out=rot(s1*5u,7)*9u;
        const uint32_t t=s1<<9;
        s2^=s0;s3^=s1;s1^=s2;s0^=s3;s2^=t;s3=rot(s3,11);
    }
    const uint64_t z=mix(2026112403ULL+stride*((uint64_t(id)<<11)+spin+1));
    const double coordinate=0.2*((double(z>>12)+0.5)*(1.0/4503599627370496.0)-0.5);
    float value=float(coordinate);if(value<0)value=-value;
    return (out>>31)?value:-value;
}
inline int16_t quantize(float x){
    const float mag=(x<0?-x:x)*16384.0f;
    const int whole=int(mag);
    const float fraction=mag-float(whole);
    const int result=whole+((fraction>.5f)||((fraction==.5f)&&(whole&1)));
    return int16_t(x<0?-result:result);
}
inline int32_t tile_dot(uint16_t signs,const int16_t x[Tile]){
#pragma HLS INLINE
    int32_t s[16],s2[8],s4[4],s8[2];
#pragma HLS ARRAY_PARTITION variable=s complete
#pragma HLS ARRAY_PARTITION variable=s2 complete
#pragma HLS ARRAY_PARTITION variable=s4 complete
#pragma HLS ARRAY_PARTITION variable=s8 complete
    for(int k=0;k<16;++k){
#pragma HLS UNROLL
        s[k]=((signs>>k)&1)?int32_t(x[k]):-int32_t(x[k]);
    }
    for(int k=0;k<8;++k){
#pragma HLS UNROLL
        s2[k]=s[2*k]+s[2*k+1];
    }
    for(int k=0;k<4;++k){
#pragma HLS UNROLL
        s4[k]=s2[2*k]+s2[2*k+1];
    }
    for(int k=0;k<2;++k){
#pragma HLS UNROLL
        s8[k]=s4[2*k]+s4[2*k+1];
    }
    return s8[0]+s8[1];
}
inline void advance(float& x,float& y,float& pump,int32_t field,float inv){
#pragma HLS INLINE
    // Preserve the separate IEEE-754 binary32 operations in the matched GH200 PXY update.
    const float c=0.011180340312421321868896484375f;
    const float f1=.196f*x,f2=f1*x,factor=1.f-f2;
    const float p1=factor*pump,p2=p1*inv,new_p=pump-p2;
    const float f3=float(field)*0.00006103515625f,f4=c*f3,f5=new_p*x,force=f4-f5;
    const float dy=1.25f*force,new_y=y+dy,dx=1.25f*new_y,new_x=x+dx;
    pump=new_p;
    if(new_x>1.f){x=1.f;y=0.f;}
    else if(new_x< -1.f){x=-1.f;y=0.f;}
    else{x=new_x;y=new_y;}
}
} // namespace gbsb

extern "C" void sca_v80(const uint64_t* jtiles,const float* inverse,uint64_t* results,
                         unsigned first,int horizon,int stop,int load_j){
#pragma HLS INTERFACE m_axi port=jtiles bundle=gmem0 offset=slave depth=62500
#pragma HLS INTERFACE m_axi port=inverse bundle=gmem1 offset=slave depth=21400
#pragma HLS INTERFACE m_axi port=results bundle=gmem2 offset=slave depth=398
#pragma HLS INTERFACE s_axilite port=jtiles bundle=control
#pragma HLS INTERFACE s_axilite port=inverse bundle=control
#pragma HLS INTERFACE s_axilite port=results bundle=control
#pragma HLS INTERFACE s_axilite port=first bundle=control
#pragma HLS INTERFACE s_axilite port=horizon bundle=control
#pragma HLS INTERFACE s_axilite port=stop bundle=control
#pragma HLS INTERFACE s_axilite port=load_j bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control
    using namespace gbsb;
    if(horizon<1||horizon>21400||stop<0||stop>horizon)return;
    static uint16_t weights[Tile][Blocks*Blocks];
#pragma HLS ARRAY_PARTITION variable=weights complete dim=1
#pragma HLS BIND_STORAGE variable=weights type=ram_1p impl=uram
    static int16_t q[2][Lanes][Blocks][Tile];
#pragma HLS ARRAY_PARTITION variable=q complete dim=1
#pragma HLS ARRAY_PARTITION variable=q complete dim=2
#pragma HLS ARRAY_PARTITION variable=q complete dim=4
    static float x[Lanes][N],y[Lanes][N],p[Lanes][N];
#pragma HLS ARRAY_PARTITION variable=x complete dim=1
#pragma HLS ARRAY_PARTITION variable=y complete dim=1
#pragma HLS ARRAY_PARTITION variable=p complete dim=1
    if(load_j)for(int tile=0;tile<Blocks*Blocks;++tile){
        for(int w=0;w<4;++w){
#pragma HLS PIPELINE II=1
            const uint64_t bits=jtiles[tile*4+w];
            for(int n=0;n<4;++n){
#pragma HLS UNROLL
                weights[4*w+n][tile]=uint16_t(bits>>(16*n));
            }
        }
    }
    for(int lane=0;lane<Lanes;++lane)for(int i=0;i<N;++i){
        const float v=initial(first+lane,i);
        x[lane][i]=v;y[lane][i]=0;p[lane][i]=1;
        q[0][lane][i/Tile][i%Tile]=stop?quantize(v):int16_t(v>=0?1:-1);
    }
    int32_t signed_field_sum[Lanes]={};
#pragma HLS ARRAY_PARTITION variable=signed_field_sum complete
    for(int t=0;t<=stop;++t){
#pragma HLS LOOP_TRIPCOUNT min=1 max=21401
        bool score=(t==stop);
        const float inv=score?0.f:inverse[t];
        const int old=t&1,newbank=1-old;
        for(int rb=0;rb<Blocks;++rb){
            int32_t dots[Lanes][Tile]={};
#pragma HLS ARRAY_PARTITION variable=dots complete dim=0
            for(int cb=0;cb<Blocks;++cb){
#pragma HLS PIPELINE II=1
                for(int row=0;row<Tile;++row){
#pragma HLS UNROLL
                    const uint16_t bits=weights[row][rb*Blocks+cb];
                    for(int h=0;h<Lanes;++h){
#pragma HLS UNROLL
                        dots[h][row]+=tile_dot(bits,q[old][h][cb]);
                    }
                }
            }
            for(int row=0;row<Tile;++row){
#pragma HLS PIPELINE II=1
                const int i=rb*Tile+row;
                for(int h=0;h<Lanes;++h){
#pragma HLS UNROLL
                    const int16_t own=q[old][h][rb][row];
                    const int32_t field=dots[h][row]-own; // the staging convention sets the diagonal bit to one.
                    if(score){signed_field_sum[h]+=int32_t(own)*field;}
                    else{
                        float xx=x[h][i],yy=y[h][i],pp=p[h][i];
                        advance(xx,yy,pp,field,inv);
                        x[h][i]=xx;y[h][i]=yy;p[h][i]=pp;
                        q[newbank][h][rb][row]=(t+1==stop)?int16_t(xx>=0?1:-1):quantize(xx);
                    }
                }
            }
        }
    }
    int best=0;int32_t best_cut=-2147483647;
    for(int h=0;h<Lanes;++h){
        for(int w=0;w<32;++w){
            uint64_t bits=0;
            for(int i=0;i<64;++i){
#pragma HLS PIPELINE II=1
                const int spin=w*64+i;
                if(spin<N && x[h][spin]>=0)bits|=uint64_t(1)<<i;
            }
            results[33*h+w]=bits;
        }
        const int32_t cut=(-2080+signed_field_sum[h])/4;
        results[33*h+32]=uint64_t(int64_t(cut));
        if(cut>best_cut){best_cut=cut;best=h;}
    }
    results[396]=unsigned(best);results[397]=uint64_t(int64_t(best_cut));
}
