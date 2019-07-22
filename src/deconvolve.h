#ifndef __DECONVOLVE_H__
#define __DECONVOLVE_H__

#include "cufinufft.h"

__global__
void Deconvolve_2d(int ms, int mt, int nf1, int nf2, int fw_width, CUCPX* fw, CUCPX *fk,
                   FLT *fwkerhalf1, FLT *fwkerhalf2);
__global__
void Amplify_2d(int ms, int mt, int nf1, int nf2, int fw_width, CUCPX* fw, CUCPX *fk, 
                   FLT *fwkerhalf1, FLT *fwkerhalf2);

int cudeconvolve2d(const cufinufft_opts opts, cufinufft_plan *d_mem);
__global__
void Deconvolve_3d(int ms, int mt, int mu, int nf1, int nf2, int nf3, int fw_width, 
	CUCPX* fw, CUCPX *fk, FLT *fwkerhalf1, FLT *fwkerhalf2, FLT *fwkerhalf3);
__global__
void Amplify_3d(int ms, int mt, int mu, int nf1, int nf2, int nf3, int fw_width, 
	CUCPX* fw, CUCPX *fk, FLT *fwkerhalf1, FLT *fwkerhalf2, FLT *fwkerhalf3);

int cudeconvolve3d(const cufinufft_opts opts, cufinufft_plan *d_mem);
#endif
