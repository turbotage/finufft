#include <cmath>
#include <complex>
#include <helper_cuda.h>
#include <iomanip>
#include <iostream>
#include <random>

#include <cufinufft_eitherprec.h>
#include <cufinufft/utils.h>
using cufinufft::utils::infnorm;

int main(int argc, char *argv[]) {

    if (argc < 9) {
        fprintf(stderr, "Usage: cufinufft3d1_test method type N1 N2 N3 M tol checktol\n"
                        "Arguments:\n"
                        "  method: One of\n"
                        "    1: nupts driven (GM), or\n"
                        "    2: sub-problem (SM), or\n"
                        "    4: block gather.\n"
                        "  type: Type of transform (1, 2)\n"
                        "  N1, N2, N3: The size of the 3D array\n"
                        "  M: The number of non-uniform points\n"
                        "  tol: NUFFT tolerance\n"
                        "  checktol:  relative error to pass test\n");
        return 1;
    }
    const int method = atoi(argv[1]);
    const int type = atoi(argv[2]);
    const int N1 = atof(argv[3]);
    const int N2 = atof(argv[4]);
    const int N3 = atof(argv[5]);
    const int M = atof(argv[6]);
    const int N = N1 * N2;
    const CUFINUFFT_FLT tol = atof(argv[7]);
    const CUFINUFFT_FLT checktol = atof(argv[8]);    

    std::cout << std::scientific << std::setprecision(3);

    int iflag = 1;
    int ier;

    CUFINUFFT_FLT *x, *y, *z;
    CUFINUFFT_CPX *c, *fk;
    cudaMallocHost(&x, M * sizeof(CUFINUFFT_FLT));
    cudaMallocHost(&y, M * sizeof(CUFINUFFT_FLT));
    cudaMallocHost(&z, M * sizeof(CUFINUFFT_FLT));
    cudaMallocHost(&c, M * sizeof(CUFINUFFT_CPX));
    cudaMallocHost(&fk, N1 * N2 * N3 * sizeof(CUFINUFFT_CPX));

    CUFINUFFT_FLT *d_x, *d_y, *d_z;
    CUCPX *d_c, *d_fk;
    checkCudaErrors(cudaMalloc(&d_x, M * sizeof(CUFINUFFT_FLT)));
    checkCudaErrors(cudaMalloc(&d_y, M * sizeof(CUFINUFFT_FLT)));
    checkCudaErrors(cudaMalloc(&d_z, M * sizeof(CUFINUFFT_FLT)));
    checkCudaErrors(cudaMalloc(&d_c, M * sizeof(CUCPX)));
    checkCudaErrors(cudaMalloc(&d_fk, N1 * N2 * N3 * sizeof(CUCPX)));

    std::default_random_engine eng(1);
    std::uniform_real_distribution<CUFINUFFT_FLT> dist11(-1, 1);
    auto randm11 = [&eng, &dist11]() { return dist11(eng); };

    // Making data
    for (int i = 0; i < M; i++) {
        x[i] = M_PI * randm11(); // x in [-pi,pi)
        y[i] = M_PI * randm11();
        z[i] = M_PI * randm11();
    }
    if (type == 1) {
        for (int i = 0; i < M; i++) {
            c[i].real(randm11());
            c[i].imag(randm11());
        }
    }
    else if (type == 2) {
        for (int i = 0; i < N1 * N2 * N3; i++) {
            fk[i].real(randm11());
            fk[i].imag(randm11());
        }
    } else {
        std::cerr << "Invalid type " << type << " supplied\n";
        return 1;
    }

    checkCudaErrors(cudaMemcpy(d_x, x, M * sizeof(CUFINUFFT_FLT), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(d_y, y, M * sizeof(CUFINUFFT_FLT), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(d_z, z, M * sizeof(CUFINUFFT_FLT), cudaMemcpyHostToDevice));
    if (type == 1)
        checkCudaErrors(cudaMemcpy(d_c, c, M * sizeof(CUCPX), cudaMemcpyHostToDevice));
    else if (type == 2)
        checkCudaErrors(cudaMemcpy(d_fk, fk, N1 * N2 * N3 * sizeof(CUCPX), cudaMemcpyHostToDevice));

    cudaEvent_t start, stop;
    float milliseconds = 0;
    float totaltime = 0;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    // warm up CUFFT (is slow, takes around 0.2 sec... )
    cudaEventRecord(start);
    {
        int nf1 = 1;
        cufftHandle fftplan;
        cufftPlan1d(&fftplan, nf1, CUFFT_TYPE, 1);
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&milliseconds, start, stop);
    printf("[time  ] dummy warmup call to CUFFT\t %.3g s\n", milliseconds / 1000);

    // now to the test...
    CUFINUFFT_PLAN dplan;
    int dim = 3;

    // Here we setup our own opts, for gpu_method and gpu_kerevalmeth.
    cufinufft_opts opts;
    ier = CUFINUFFT_DEFAULT_OPTS(type, dim, &opts);
    if (ier != 0) {
        printf("err %d: CUFINUFFT_DEFAULT_OPTS\n", ier);
        return ier;
    }
    opts.gpu_method = method;
    opts.gpu_kerevalmeth = 1;

    int nmodes[3] = {N1, N2, N3};
    int ntransf = 1;
    int maxbatchsize = 1;
    cudaEventRecord(start);
    ier = CUFINUFFT_MAKEPLAN(type, dim, nmodes, iflag, ntransf, tol, maxbatchsize, &dplan, &opts);
    if (ier != 0) {
        printf("err: cufinufft_makeplan\n");
        return ier;
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&milliseconds, start, stop);
    totaltime += milliseconds;
    printf("[time  ] cufinufft plan:\t\t %.3g s\n", milliseconds / 1000);

    cudaEventRecord(start);
    ier = CUFINUFFT_SETPTS(M, d_x, d_y, d_z, 0, NULL, NULL, NULL, dplan);
    if (ier != 0) {
        printf("err: cufinufft_setpts\n");
        return ier;
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&milliseconds, start, stop);
    totaltime += milliseconds;
    printf("[time  ] cufinufft setNUpts:\t\t %.3g s\n", milliseconds / 1000);

    cudaEventRecord(start);
    ier = CUFINUFFT_EXECUTE(d_c, d_fk, dplan);
    if (ier != 0) {
        printf("err: cufinufft_execute\n");
        return ier;
    }
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&milliseconds, start, stop);
    totaltime += milliseconds;
    float exec_ms = milliseconds;
    printf("[time  ] cufinufft exec:\t\t %.3g s\n", milliseconds / 1000);

    cudaEventRecord(start);
    ier = CUFINUFFT_DESTROY(dplan);
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&milliseconds, start, stop);
    totaltime += milliseconds;
    printf("[time  ] cufinufft destroy:\t\t %.3g s\n", milliseconds / 1000);

    if (type == 1)
        checkCudaErrors(cudaMemcpy(fk, d_fk, N1 * N2 * N3 * sizeof(CUCPX), cudaMemcpyDeviceToHost));
    else if (type == 2)
        checkCudaErrors(cudaMemcpy(c, d_c, M * sizeof(CUCPX), cudaMemcpyDeviceToHost));

    printf("[Method %d] %d NU pts to %d U pts in %.3g s:\t%.3g NU pts/s\n", opts.gpu_method, M, N1 * N2 * N3,
           totaltime / 1000, M / totaltime * 1000);
    printf("\t\t\t\t\t(exec-only thoughput: %.3g NU pts/s)\n", M / exec_ms * 1000);

    CUFINUFFT_FLT rel_error = std::numeric_limits<CUFINUFFT_FLT>::max();
    if (type == 1) {
        int nt1 = (int)(0.37 * N1), nt2 = (int)(0.26 * N2), nt3 = (int)(0.13 * N3); // choose some mode index to check
        CUFINUFFT_CPX Ft = CUFINUFFT_CPX(0, 0), J = IMA * (CUFINUFFT_FLT)iflag;
        for (int j = 0; j < M; ++j)
            Ft += c[j] * exp(J * (nt1 * x[j] + nt2 * y[j] + nt3 * z[j]));       // crude direct

        int it = N1 / 2 + nt1 + N1 * (N2 / 2 + nt2) + N1 * N2 * (N3 / 2 + nt3); // index in complex F as 1d array
        rel_error = abs(Ft - fk[it]) / infnorm(N, fk);
        printf("[gpu   ] one mode: rel err in F[%d,%d,%d] is %.3g\n", nt1, nt2, nt3, rel_error);
    }
    else if (type == 2) {
        int jt = M / 2; // check arbitrary choice of one targ pt
        CUFINUFFT_CPX J = IMA * (CUFINUFFT_FLT)iflag;
        CUFINUFFT_CPX ct = CUFINUFFT_CPX(0, 0);
        int m = 0;
        for (int m3 = -(N3 / 2); m3 <= (N3 - 1) / 2; ++m3)     // loop in correct order over F
            for (int m2 = -(N2 / 2); m2 <= (N2 - 1) / 2; ++m2) // loop in correct order over F
                for (int m1 = -(N1 / 2); m1 <= (N1 - 1) / 2; ++m1)
                    ct += fk[m++] * exp(J * (m1 * x[jt] + m2 * y[jt] + m3 * z[jt])); // crude direct

        rel_error = abs(c[jt] - ct) / infnorm(M, c);
        printf("[gpu   ] one targ: rel err in c[%ld] is %.3g\n", (int64_t)jt, rel_error);
    }

    cudaFreeHost(x);
    cudaFreeHost(y);
    cudaFreeHost(z);
    cudaFreeHost(c);
    cudaFreeHost(fk);
    cudaFree(d_x);
    cudaFree(d_y);
    cudaFree(d_z);
    cudaFree(d_c);
    cudaFree(d_fk);

    return std::isnan(rel_error) || rel_error > checktol;
}
