// dslash_def.h - Dslash kernel definitions

// There are currently 32 different variants of the Dslash kernel,
// each one characterized by a set of 5 options, where each option can
// take one of two values (2^5 = 32).  This file is structured so that
// the C preprocessor loops through all 32 variants (in a manner
// resembling a binary counter), sets the appropriate macros, and
// defines the corresponding functions.
//
// For an example of the function naming conventions, consider
//
// dslashSH12DaggerXpayKernel(float4* g_out, int oddBit, float a).
//
// This is a Dslash^dagger kernel where the gauge field is read in single
// precision (S), the spinor field is read in half precision (H), each
// gauge matrix is reconstructed from 12 real numbers, and the result is
// multiplied by "a" and accumulated into an input vector (Xpay).
// In other words, a general function name is given by the concatenation
// of the following 5 fields, with "dslash" at the beginning and "Kernel"
// at the end:
//
// DD_GPREC_F = S, H
// DD_SPREC_F = S, H
// DD_RECON_F = 12, 8
// DD_DAG_F = Dagger, [blank]
// DD_XPAY_F = Xpay, [blank]


// initialize on first iteration

#ifndef DD_LOOP
#define DD_LOOP
#define DD_DAG 0
#define DD_XPAY 0
#define DD_RECON 0
#define DD_GPREC 0
#define DD_SPREC 0
#endif

// set options for current iteration

#if (DD_DAG==0) // no dagger
#define DD_DAG_F
#else           // dagger
#define DD_DAG_F Dagger
#endif

#if (DD_XPAY==0) // no xpay 
#define DD_XPAY_F 
#define DD_PARAM2 int oddBit
#else            // xpay
#define DD_XPAY_F Xpay
#define DD_PARAM2 int oddBit, float a
#define DSLASH_XPAY
#endif

#if (DD_RECON==0) // reconstruct from 12 reals
#define DD_RECON_F 12
#define RECONSTRUCT_GAUGE_MATRIX RECONSTRUCT_MATRIX_12
#define READ_GAUGE_MATRIX READ_GAUGE_MATRIX_12
#else             // reconstruct from 8 reals
#define DD_RECON_F 8
#define RECONSTRUCT_GAUGE_MATRIX RECONSTRUCT_MATRIX_8
#if (DD_GPREC==0)
#define READ_GAUGE_MATRIX READ_GAUGE_MATRIX_8
#else
#define READ_GAUGE_MATRIX READ_GAUGE_MATRIX_8_HALF
#endif
#endif

#if (DD_GPREC==0) // single-precision gauge field
#define DD_GPREC_F S
#define GAUGE0TEX gauge0TexSingle
#define GAUGE1TEX gauge1TexSingle
#else             // half-precision gauge field
#define DD_GPREC_F H
#define GAUGE0TEX gauge0TexHalf
#define GAUGE1TEX gauge1TexHalf
#endif

#if (DD_SPREC==0) // single-precision spinor field
#define DD_SPREC_F S
#define DD_PARAM1 float4* g_out
#define READ_SPINOR READ_SPINOR_SINGLE
#define READ_SPINOR_UP READ_SPINOR_SINGLE_UP
#define READ_SPINOR_DOWN READ_SPINOR_SINGLE_DOWN
#define SPINORTEX spinorTexSingle
#define WRITE_SPINOR WRITE_SPINOR_FLOAT4
#if (DD_XPAY==1)
#define ACCUMTEX accumTexSingle
#define READ_ACCUM READ_ACCUM_SINGLE
#endif
#else            // half-precision spinor field
#define DD_SPREC_F H
#define READ_SPINOR READ_SPINOR_HALF
#define READ_SPINOR_UP READ_SPINOR_HALF_UP
#define READ_SPINOR_DOWN READ_SPINOR_HALF_DOWN
#define SPINORTEX spinorTexHalf
#if (DD_XPAY==0)
#define DD_PARAM1 short4* g_out, float *c
#define WRITE_SPINOR WRITE_SPINOR_SHORT4
#else
#define DD_PARAM1 float4* g_out
#define WRITE_SPINOR WRITE_SPINOR_FLOAT4
#define ACCUMTEX accumTexHalf
#define READ_ACCUM READ_ACCUM_HALF
#endif
#endif

#define DD_CONCAT(g,s,r,d,x) dslash ## g ## s ## r ## d ## x ## Kernel
#define DD_FUNC(g,s,r,d,x) DD_CONCAT(g,s,r,d,x)

// define the kernel

__global__ void
DD_FUNC(DD_GPREC_F, DD_SPREC_F, DD_RECON_F, DD_DAG_F, DD_XPAY_F)(DD_PARAM1, DD_PARAM2) {
#if DD_DAG
#include "dslash_dagger_core.h"
#else
#include "dslash_core.h"
#endif
}

// clean up

#undef DD_GPREC_F
#undef DD_SPREC_F
#undef DD_RECON_F
#undef DD_DAG_F
#undef DD_XPAY_F
#undef DD_PARAM1
#undef DD_PARAM2
#undef DD_CONCAT
#undef DD_FUNC

#undef DSLASH_XPAY
#undef READ_GAUGE_MATRIX
#undef RECONSTRUCT_GAUGE_MATRIX
#undef GAUGE0TEX
#undef GAUGE1TEX
#undef READ_SPINOR
#undef READ_SPINOR_UP
#undef READ_SPINOR_DOWN
#undef SPINORTEX
#undef WRITE_SPINOR
#undef ACCUMTEX
#undef READ_ACCUM

// prepare next set of options, or clean up after final iteration

#if (DD_DAG==0)
#undef DD_DAG
#define DD_DAG 1
#else
#undef DD_DAG
#define DD_DAG 0

#if (DD_XPAY==0)
#undef DD_XPAY
#define DD_XPAY 1
#else
#undef DD_XPAY
#define DD_XPAY 0

#if (DD_RECON==0)
#undef DD_RECON
#define DD_RECON 1
#else
#undef DD_RECON
#define DD_RECON 0

#if (DD_GPREC==0)
#undef DD_GPREC
#define DD_GPREC 1
#else
#undef DD_GPREC
#define DD_GPREC 0

#if (DD_SPREC==0)
#undef DD_SPREC
#define DD_SPREC 1
#else

#undef DD_LOOP
#undef DD_DAG
#undef DD_XPAY
#undef DD_RECON
#undef DD_GPREC
#undef DD_SPREC

#endif // DD_SPREC
#endif // DD_GPREC
#endif // DD_RECON
#endif // DD_XPAY
#endif // DD_DAG

#ifdef DD_LOOP
#include "dslash_def.h"
#endif
