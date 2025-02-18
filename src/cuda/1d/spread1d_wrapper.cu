#include <cassert>
#include <cufinufft/contrib/helper_cuda.h>
#include <iomanip>
#include <iostream>

#include <cuComplex.h>
#include <thrust/device_ptr.h>
#include <thrust/scan.h>

#include <cufinufft/memtransfer.h>
#include <cufinufft/precision_independent.h>
#include <cufinufft/spreadinterp.h>

using namespace cufinufft::common;
using namespace cufinufft::memtransfer;

#include "spreadinterp1d.cuh"

namespace cufinufft {
namespace spreadinterp {

template <typename T>
int cuspread1d(cufinufft_plan_t<T> *d_plan, int blksize)
/*
    A wrapper for different spreading methods.

    Methods available:
    (1) Non-uniform points driven
    (2) Subproblem

    Melody Shih 11/21/21
*/
{
    int nf1 = d_plan->nf1;
    int M = d_plan->M;

    int ier;
    switch (d_plan->opts.gpu_method) {
    case 1: {
        ier = cuspread1d_nuptsdriven<T>(nf1, M, d_plan, blksize);
    } break;
    case 2: {
        ier = cuspread1d_subprob<T>(nf1, M, d_plan, blksize);
    } break;
    default:
        std::cerr << "[cuspread1d] error: incorrect method, should be 1 or 2\n";
        ier = FINUFFT_ERR_METHOD_NOTVALID;
    }

    return ier;
}

template <typename T>
int cuspread1d_nuptsdriven_prop(int nf1, int M, cufinufft_plan_t<T> *d_plan) {
    if (d_plan->opts.gpu_sort) {
        int bin_size_x = d_plan->opts.gpu_binsizex;
        if (bin_size_x < 0) {
            std::cerr << "[cuspread1d_nuptsdriven_prop] error: invalid binsize (binsizex) = (" << bin_size_x << ")\n";
            return FINUFFT_ERR_BINSIZE_NOTVALID;
        }

        int numbins = ceil((T)nf1 / bin_size_x);

        T *d_kx = d_plan->kx;

        int *d_binsize = d_plan->binsize;
        int *d_binstartpts = d_plan->binstartpts;
        int *d_sortidx = d_plan->sortidx;
        int *d_idxnupts = d_plan->idxnupts;

        int pirange = d_plan->spopts.pirange;
        int ier;
        if ((ier = checkCudaErrors(cudaMemset(d_binsize, 0, numbins * sizeof(int)))))
            return ier;
        calc_bin_size_noghost_1d<<<(M + 1024 - 1) / 1024, 1024>>>(M, nf1, bin_size_x, numbins, d_binsize, d_kx,
                                                                  d_sortidx, pirange);
        RETURN_IF_CUDA_ERROR

        int n = numbins;
        thrust::device_ptr<int> d_ptr(d_binsize);
        thrust::device_ptr<int> d_result(d_binstartpts);
        thrust::exclusive_scan(d_ptr, d_ptr + n, d_result);

        calc_inverse_of_global_sort_idx_1d<<<(M + 1024 - 1) / 1024, 1024>>>(M, bin_size_x, numbins, d_binstartpts,
                                                                            d_sortidx, d_kx, d_idxnupts, pirange, nf1);
        RETURN_IF_CUDA_ERROR
    } else {
        int *d_idxnupts = d_plan->idxnupts;
        trivial_global_sort_index_1d<<<(M + 1024 - 1) / 1024, 1024>>>(M, d_idxnupts);
        RETURN_IF_CUDA_ERROR
    }

    return 0;
}

template <typename T>
int cuspread1d_nuptsdriven(int nf1, int M, cufinufft_plan_t<T> *d_plan, int blksize) {
    dim3 threadsPerBlock;
    dim3 blocks;

    int ns = d_plan->spopts.nspread; // psi's support in terms of number of cells
    int pirange = d_plan->spopts.pirange;
    int *d_idxnupts = d_plan->idxnupts;
    T es_c = d_plan->spopts.ES_c;
    T es_beta = d_plan->spopts.ES_beta;
    T sigma = d_plan->spopts.upsampfac;

    T *d_kx = d_plan->kx;
    cuda_complex<T> *d_c = d_plan->c;
    cuda_complex<T> *d_fw = d_plan->fw;

    threadsPerBlock.x = 16;
    threadsPerBlock.y = 1;
    blocks.x = (M + threadsPerBlock.x - 1) / threadsPerBlock.x;
    blocks.y = 1;

    if (d_plan->opts.gpu_kerevalmeth) {
        for (int t = 0; t < blksize; t++) {
            spread_1d_nuptsdriven<T, 1><<<blocks, threadsPerBlock>>>(d_kx, d_c + t * M, d_fw + t * nf1, M, ns, nf1,
                                                                     es_c, es_beta, sigma, d_idxnupts, pirange);
            RETURN_IF_CUDA_ERROR
        }
    } else {
        for (int t = 0; t < blksize; t++) {
            spread_1d_nuptsdriven<T, 0><<<blocks, threadsPerBlock>>>(d_kx, d_c + t * M, d_fw + t * nf1, M, ns, nf1,
                                                                     es_c, es_beta, sigma, d_idxnupts, pirange);
            RETURN_IF_CUDA_ERROR
        }
    }

    return 0;
}

template <typename T>
int cuspread1d_subprob_prop(int nf1, int M, cufinufft_plan_t<T> *d_plan)
/*
    This function determines the properties for spreading that are independent
    of the strength of the nodes,  only relates to the locations of the nodes,
    which only needs to be done once.
*/
{
    int ier;
    int maxsubprobsize = d_plan->opts.gpu_maxsubprobsize;
    int bin_size_x = d_plan->opts.gpu_binsizex;
    if (bin_size_x < 0) {
        std::cerr << "[cuspread1d_subprob_prop] error: invalid binsize (binsizex) = (" << bin_size_x << ")\n";
        return FINUFFT_ERR_BINSIZE_NOTVALID;
    }

    int numbins = ceil((T)nf1 / bin_size_x);

    T *d_kx = d_plan->kx;

    int *d_binsize = d_plan->binsize;
    int *d_binstartpts = d_plan->binstartpts;
    int *d_sortidx = d_plan->sortidx;
    int *d_numsubprob = d_plan->numsubprob;
    int *d_subprobstartpts = d_plan->subprobstartpts;
    int *d_idxnupts = d_plan->idxnupts;

    int *d_subprob_to_bin = NULL;

    int pirange = d_plan->spopts.pirange;

    if ((ier = checkCudaErrors(cudaMemset(d_binsize, 0, numbins * sizeof(int)))))
        return ier;
    calc_bin_size_noghost_1d<<<(M + 1024 - 1) / 1024, 1024>>>(M, nf1, bin_size_x, numbins, d_binsize, d_kx, d_sortidx,
                                                              pirange);
    RETURN_IF_CUDA_ERROR

    int n = numbins;
    thrust::device_ptr<int> d_ptr(d_binsize);
    thrust::device_ptr<int> d_result(d_binstartpts);
    thrust::exclusive_scan(d_ptr, d_ptr + n, d_result);

    calc_inverse_of_global_sort_idx_1d<<<(M + 1024 - 1) / 1024, 1024>>>(M, bin_size_x, numbins, d_binstartpts,
                                                                        d_sortidx, d_kx, d_idxnupts, pirange, nf1);
    RETURN_IF_CUDA_ERROR

    calc_subprob_1d<<<(M + 1024 - 1) / 1024, 1024>>>(d_binsize, d_numsubprob, maxsubprobsize, numbins);
    RETURN_IF_CUDA_ERROR

    d_ptr = thrust::device_pointer_cast(d_numsubprob);
    d_result = thrust::device_pointer_cast(d_subprobstartpts + 1);
    thrust::inclusive_scan(d_ptr, d_ptr + n, d_result);
    if ((ier = checkCudaErrors(cudaMemset(d_subprobstartpts, 0, sizeof(int)))))
        return ier;

    int totalnumsubprob;
    if ((ier =
             checkCudaErrors(cudaMemcpy(&totalnumsubprob, &d_subprobstartpts[n], sizeof(int), cudaMemcpyDeviceToHost))))
        return ier;
    if ((ier = checkCudaErrors(cudaMalloc(&d_subprob_to_bin, totalnumsubprob * sizeof(int)))))
        return ier;
    map_b_into_subprob_1d<<<(numbins + 1024 - 1) / 1024, 1024>>>(d_subprob_to_bin, d_subprobstartpts, d_numsubprob,
                                                                 numbins);
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess) {
        fprintf(stderr, "[%s] Error: %s\n", __func__, cudaGetErrorString(err));
        cudaFree(d_subprob_to_bin);
        return FINUFFT_ERR_CUDA_FAILURE;
    }

    assert(d_subprob_to_bin != NULL);
    cudaFree(d_plan->subprob_to_bin);
    d_plan->subprob_to_bin = d_subprob_to_bin;
    d_plan->totalnumsubprob = totalnumsubprob;

    return 0;
}

template <typename T>
int cuspread1d_subprob(int nf1, int M, cufinufft_plan_t<T> *d_plan, int blksize) {
    int ns = d_plan->spopts.nspread; // psi's support in terms of number of cells
    T es_c = d_plan->spopts.ES_c;
    T es_beta = d_plan->spopts.ES_beta;
    int maxsubprobsize = d_plan->opts.gpu_maxsubprobsize;

    // assume that bin_size_x > ns/2;
    int bin_size_x = d_plan->opts.gpu_binsizex;
    int numbins = ceil((T)nf1 / bin_size_x);

    T *d_kx = d_plan->kx;
    cuda_complex<T> *d_c = d_plan->c;
    cuda_complex<T> *d_fw = d_plan->fw;

    int *d_binsize = d_plan->binsize;
    int *d_binstartpts = d_plan->binstartpts;
    int *d_numsubprob = d_plan->numsubprob;
    int *d_subprobstartpts = d_plan->subprobstartpts;
    int *d_idxnupts = d_plan->idxnupts;

    int totalnumsubprob = d_plan->totalnumsubprob;
    int *d_subprob_to_bin = d_plan->subprob_to_bin;

    int pirange = d_plan->spopts.pirange;

    T sigma = d_plan->opts.upsampfac;

    size_t sharedplanorysize = (bin_size_x + 2 * (int)ceil(ns / 2.0)) * sizeof(cuda_complex<T>);
    if (sharedplanorysize > 49152) {
        std::cerr << "[cuspread1d_subprob] error: not enough shared memory\n";
        return FINUFFT_ERR_INSUFFICIENT_SHMEM;
    }

    if (d_plan->opts.gpu_kerevalmeth) {
        for (int t = 0; t < blksize; t++) {
            spread_1d_subprob<T, 1><<<totalnumsubprob, 256, sharedplanorysize>>>(
                d_kx, d_c + t * M, d_fw + t * nf1, M, ns, nf1, es_c, es_beta, sigma, d_binstartpts, d_binsize,
                bin_size_x, d_subprob_to_bin, d_subprobstartpts, d_numsubprob, maxsubprobsize, numbins, d_idxnupts,
                pirange);
            RETURN_IF_CUDA_ERROR
        }
    } else {
        for (int t = 0; t < blksize; t++) {
            spread_1d_subprob<T, 0><<<totalnumsubprob, 256, sharedplanorysize>>>(
                d_kx, d_c + t * M, d_fw + t * nf1, M, ns, nf1, es_c, es_beta, sigma, d_binstartpts, d_binsize,
                bin_size_x, d_subprob_to_bin, d_subprobstartpts, d_numsubprob, maxsubprobsize, numbins, d_idxnupts,
                pirange);
            RETURN_IF_CUDA_ERROR
        }
    }

    return 0;
}

template int cuspread1d<float>(cufinufft_plan_t<float> *d_plan, int blksize);
template int cuspread1d<double>(cufinufft_plan_t<double> *d_plan, int blksize);
template int cuspread1d_nuptsdriven_prop<float>(int nf1, int M, cufinufft_plan_t<float> *d_plan);
template int cuspread1d_nuptsdriven_prop<double>(int nf1, int M, cufinufft_plan_t<double> *d_plan);
template int cuspread1d_subprob_prop<float>(int nf1, int M, cufinufft_plan_t<float> *d_plan);
template int cuspread1d_subprob_prop<double>(int nf1, int M, cufinufft_plan_t<double> *d_plan);

} // namespace spreadinterp
} // namespace cufinufft
