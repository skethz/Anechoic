#pragma once
__device__ __forceinline__ void easy_step(float& x,float& y,float& p,int field,float c,float inv,float a,float dt){
    const float factor=__fsub_rn(1.f,__fmul_rn(__fmul_rn(a,x),x));
    p=__fsub_rn(p,__fmul_rn(__fmul_rn(factor,p),inv));
    const float force=__fsub_rn(__fmul_rn(c,__fmul_rn(float(field),0x1p-14f)),__fmul_rn(p,x));
    y=__fadd_rn(y,__fmul_rn(dt,force));x=__fadd_rn(x,__fmul_rn(dt,y));
    if(fabsf(x)>1.f){x=copysignf(1.f,x);y=0.f;}
}
