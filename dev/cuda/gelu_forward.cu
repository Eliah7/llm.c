/*
Kernels for gelu forward pass.

Compile example:
nvcc -O3 --use_fast_math gelu_forward.cu -o gelu_forward

If encountering "error: identifier "M_PI" is undefined", add the following lines to the top of the file:

#define _USE_MATH_DEFINES
#include <math.h>  OR  #include <cmath>

version 1 is naive port from CPU code to kernel
./gelu_forward 1

version 2 uses the Packed128 data structure
./gelu_forward 2
*/

#include <stdio.h>
#include <stdlib.h>
#include <cuda_runtime.h>
#include "common.h"

// turn on bf16 as default, done up here for now
//#define ENABLE_BF16

#if defined(ENABLE_BF16)
typedef __nv_bfloat16 floatX;
typedef __nv_bfloat16 floatN;
#elif defined(ENABLE_FP16)
typedef half floatX;
typedef half floatN;
#else
typedef float floatX;
typedef float floatN;
#endif

typedef Packed128<floatX> x128;

// ----------------------------------------------------------------------------
// CPU code reference

#define GELU_SCALING_FACTOR sqrtf(2.0f / M_PI)

void gelu_forward_cpu(float* out, const float* inp, int N) {
    for (int i = 0; i < N; i++) {
        float x = inp[i];
        float cube = 0.044715f * x * x * x;
        out[i] = 0.5f * x * (1.0f + tanhf(GELU_SCALING_FACTOR * (x + cube)));
    }
}

// ----------------------------------------------------------------------------
// GPU kernels

// elementwise ops are nice and ez
__global__ void gelu_kernel(float* out, const float* inp, int N) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < N) {
        float xi = inp[i];
        float cube = 0.044715f * xi * xi * xi;
        out[i] = 0.5f * xi * (1.0f + tanhf(GELU_SCALING_FACTOR * (xi + cube)));
    }
}

// elementwise ops are nice and ez
__global__ void gelu_kernel2(floatX* out, const floatX* inp, int N) {
    int i = (blockIdx.x * blockDim.x + threadIdx.x) * x128::size;
    if (i < N) {
        x128 packed_out;
        x128 packed_inp = load128cs(inp + i); // load and do not keep in cache
        for(int k = 0; k < packed_inp.size; ++k) {
            float xi = (float)packed_inp[k];
            float cube = 0.044715f * xi * xi * xi;
            packed_out[k] = (float)(0.5f * xi * (1.0f + tanhf(GELU_SCALING_FACTOR * (xi + cube))));
        }
        // store instead of storecs (without cache streaming) in case it is useful for the
        // data to be in the cache for the next operation after this GeLU
        store128(out + i, packed_out);
    }
}

// ----------------------------------------------------------------------------
// kernel launcher

void gelu_forward1(float* out, const float* inp, int N, const int block_size) {
    const int grid_size = ceil_div(N, block_size);
    gelu_kernel<<<grid_size, block_size>>>(out, inp, N);
    cudaCheck(cudaGetLastError());
}

void gelu_forward2(floatX* out, const floatX* inp, int N, const int block_size) {
    const int grid_size = ceil_div(N, block_size)/x128::size;
    gelu_kernel2<<<grid_size, block_size>>>(out, inp, N);
    cudaCheck(cudaGetLastError());
}

// kernel version dispatch
void gelu_forward(int kernel_num,
                  floatX* out,
                  const floatX* inp,
                  int B, int T, int C,
                  int block_size) {
    switch (kernel_num) {
#if !defined(ENABLE_BF16) && !defined(ENABLE_FP16)
        case 1:
            gelu_forward1(out, inp, B * T * C, block_size);
            break;
#endif
#if defined(ENABLE_BF16)
        case 2:
            gelu_forward2(out, inp, B * T * C, block_size);
            break;
#endif
        default:
            printf("Invalid kernel number\n");
            exit(1);
    }
}

// ----------------------------------------------------------------------------

int main(int argc, char **argv) {
    srand(0);

    int B = 8;
    int T = 1024;
    int C = 768;

    int deviceIdx = 0;
    cudaCheck(cudaSetDevice(deviceIdx));

    // create host memory of random numbers
    float* out = (float*)malloc(B * T * C * sizeof(float));
    float* inp = make_random_float(B * T * C);

    // read kernel_num from command line
    int kernel_num = 1;
    if (argc > 1) {
        kernel_num = atoi(argv[1]);
    }
    printf("Using kernel %d\n", kernel_num);

    // first check the correctness of the kernel
    gelu_forward_cpu(out, inp, B * T * C);

    // move to GPU
    floatX* d_out;
    floatX* d_inp;
    cudaCheck(cudaMalloc(&d_out, B * T * C * sizeof(floatX)));
    cudaCheck(cudaMalloc(&d_inp, B * T * C * sizeof(floatX)));

    floatX* inpX = (floatX*)malloc(B * T * C * sizeof(floatX));

    for (int i = 0; i < B * T * C; i++) {
        inpX[i] = (floatX)inp[i];
    }

    cudaCheck(cudaMemcpy(d_inp, inpX, B * T * C * sizeof(floatX), cudaMemcpyHostToDevice));

    // time the kernel at different block sizes
    int block_sizes[] = {32, 64, 128, 256, 512, 1024};
    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];
        printf("Checking block size %d.\n", block_size);
        gelu_forward(kernel_num, d_out, d_inp, B, T, C, block_size);
#if !defined(ENABLE_BF16) && !defined(ENABLE_FP16)
        validate_result(d_out, out, "out", B * T * C, 1e-5f);
#endif
#if defined(ENABLE_BF16)
#endif
        validate_result(d_out, out, "out", B * T * C, 1e-2f);
    }

    printf("All results match. Starting benchmarks.\n\n");

    for (int j = 0; j < sizeof(block_sizes) / sizeof(int); j++) {
        int block_size = block_sizes[j];

        int repeat_times = 1000;

        float elapsed_time = benchmark_kernel(repeat_times, gelu_forward,
                                              kernel_num, d_out, d_inp,
                                              B, T, C, block_size);

        // napkin math: estimate the memory bandwidth achieved
        // for each (B,T,C) output element, we do 1 read and 1 write, 4 bytes each
        // and e.g. A100 40GB PCIe is advertised at 1,555GB/s
        long memory_ops = B * T * C * 2 * 4;
        float memory_bandwidth = memory_ops / elapsed_time / 1e6;

        printf("block_size %4d | time %.4f ms | bandwidth %.2f GB/s\n", block_size, elapsed_time, memory_bandwidth);
    }

    // free memory
    free(out);
    free(inp);
    free(inpX);

    cudaCheck(cudaFree(d_out));
    cudaCheck(cudaFree(d_inp));
    return 0;
}