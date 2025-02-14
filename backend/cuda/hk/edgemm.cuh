#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <mma.h>

using namespace nvcuda;

#define OFFSET(row, col, ld) ((row) * (ld) + (col))
#define FLOAT4(pointer) (reinterpret_cast<float4*>(&(pointer))[0])

__global__ void myHGEMMAlignedV5(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 128;
    const int BN = 256;
    const int BK = 32;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK + APAD);
    int s_a_db_offset = BM * (BK + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
        }
    }

    int load_a_smem_m = (tid >> 2) << 1;
    int load_a_smem_k = (tid &  3) << 3;
    int load_b_smem_k = (tid >> 5) << 2;
    int load_b_smem_n = (tid & 31) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK + APAD) * sizeof(half);
    int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    int comp_c_frag_m = wid &  1;
    int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0), "l"(&a[load_a_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_1), "l"(&a[load_a_gmem_addr +     K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

        wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
        wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

        #pragma unroll
        for (int i = 0; i < 4; i++) {
            #pragma unroll
            for (int j = 0; j < 4; j++) {
                wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
                wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
            }
        }

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
            wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        }
    }

    int store_c_gmem_m = by * BM + comp_c_frag_m * 64;
    int store_c_gmem_n = bx * BN + comp_c_frag_n * 64;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    #pragma unroll
    for (int i = 0; i < 4; i++) {
        #pragma unroll
        for (int j = 0; j < 4; j++) {
            wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
        }
    }
#endif
}


__global__ void eed_hgemm_m8n256k32_v1(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800
    const int BM = 8;
    const int BN = 256;
    const int BK = 32;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 8 + APAD);
    int s_a_db_offset = BM * (BK * 8 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    // wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    // wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    // wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[2];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[2];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
    //     }
    // }

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 5);
    int load_a_smem_k = (tid & 31) << 3;
    int load_b_smem_k = (tid >> 5) << 2;
    int load_b_smem_n = (tid & 31) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 8 + APAD) * sizeof(half);
    // int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK * 8 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    // int comp_c_frag_m = wid &  1;
    // int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 8 * BK + 0], 8 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 8 * BK + 16], 8 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

        // #pragma unroll
        // for (int i = 0; i < 4; i++) {
        //     #pragma unroll
        //     for (int j = 0; j < 4; j++) {
        //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
        //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        //     }
        // }

        wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
        wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

        // __syncthreads();

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        if (bk % 8 == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    // wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    // wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 7 * BK + 0], 8 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 7 * BK + 16], 8 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
    //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
    //     }
    // }

    wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

    int store_c_gmem_m = by * BM;
    int store_c_gmem_n = bx * BN + wid * 32;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
    //     }
    // }
    wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
#endif
}


__global__ void eed_hgemm_m8n256k32_v2(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 256;
    const int BK = 32;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 8 + APAD);
    int s_a_db_offset = BM * (BK * 8 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    // wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    // wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    // wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[2];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[2];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
    //     }
    // }
 
    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 5);
    int load_a_smem_k = (tid & 31) << 3;
    int load_b_smem_k = (tid >> 5) << 2;
    int load_b_smem_n = (tid & 31) << 3;
    int shift = ((tid & 31) >> 2) & 1;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 8 + APAD) * sizeof(half);
    // int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK * 8 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    // int comp_c_frag_m = wid &  1;
    // int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + shift * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 8 * BK + 0], 8 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 8 * BK + 16], 8 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

        // #pragma unroll
        // for (int i = 0; i < 4; i++) {
        //     #pragma unroll
        //     for (int j = 0; j < 4; j++) {
        //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
        //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        //     }
        // }

        wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
        wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

        // __syncthreads();

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        if (bk % 8 == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + shift * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
            // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            //     : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    // wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    // wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 7 * BK + 0], 8 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 7 * BK + 16], 8 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
    //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
    //     }
    // }

    wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

    int store_c_gmem_m = by * BM;
    int store_c_gmem_n = bx * BN + wid * 32;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
    //     }
    // }
    wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
#endif
}


__global__ void eed_hgemm_m8n256k64_v3(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 256;
    const int BK = 64;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 4 + APAD);
    int s_a_db_offset = BM * (BK * 4 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    // wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    // wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    // wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
    //     }
    // }

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 5);
    int load_a_smem_k = (tid & 31) << 3;
    int load_b_smem_k = (tid >> 5) << 3;
    int load_b_smem_n = (tid & 31) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 4 + APAD) * sizeof(half);
    // int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK * 8 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    // int comp_c_frag_m = wid &  1;
    // int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 0], 4 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 16], 4 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 32], 4 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 48], 4 * BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

        // #pragma unroll
        // for (int i = 0; i < 4; i++) {
        //     #pragma unroll
        //     for (int j = 0; j < 4; j++) {
        //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
        //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        //     }
        // }
        #pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        // __syncthreads();

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        if (bk % 4 == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    // wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    // wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 3 * BK + 0], 4 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 3 * BK + 16], 4 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 3 * BK + 32], 4 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 3 * BK + 48], 4 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
    //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
    //     }
    // }

    // wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    // wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    int store_c_gmem_m = by * BM;
    int store_c_gmem_n = bx * BN + wid * 32;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
    //     }
    // }
    wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
#endif
}


__global__ void eed_hgemm_m8n128k64_v4(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 128;
    const int BK = 64;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 2 + APAD);
    int s_a_db_offset = BM * (BK * 2 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    // wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    // wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    // wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
    //     }
    // }

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);
    int load_a_smem_k = (tid & 15) << 3;
    int load_b_smem_k = (tid >> 4) << 3;
    int load_b_smem_n = (tid & 15) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 2 + APAD) * sizeof(half);
    // int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK * 8 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    // int comp_c_frag_m = wid &  1;
    // int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 0], 2 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 16], 2 * BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 32], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 48], 2 * BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

        // #pragma unroll
        // for (int i = 0; i < 4; i++) {
        //     #pragma unroll
        //     for (int j = 0; j < 4; j++) {
        //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
        //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        //     }
        // }
        #pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        // __syncthreads();

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        if (bk % 2 == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    // wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    // wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 1 * BK + 0], 2 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 1 * BK + 16], 2 * BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 1 * BK + 32], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 1 * BK + 48], 2 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
    //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
    //     }
    // }

    // wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    // wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    int store_c_gmem_m = by * BM;
    int store_c_gmem_n = bx * BN + wid * 32;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
    //     }
    // }
    wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
#endif
}


__global__ void eed_hgemm_m8n128k128_v5(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 128;
    const int BK = 128;

    int bx = blockIdx.z * gridDim.x + blockIdx.x;
    int by = blockIdx.y;
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN || by >= M / BM)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK + APAD);
    int s_a_db_offset = BM * (BK + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    // wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[2][4];
    // wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[2][4];
    // wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c[4][4];

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[8];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[8];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::fill_fragment(frag_c[i][j], __float2half(0.0f));
    //     }
    // }

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);
    int load_a_smem_k = (tid & 15) << 3;
    int load_b_smem_k = (tid >> 4) << 4;
    int load_b_smem_n = (tid & 15) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK + APAD) * sizeof(half);
    // int load_a_smem_addr_1 = load_a_smem_addr_0 + (BK * 8 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_8 = load_b_smem_addr_0 + 8 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_9 = load_b_smem_addr_0 + 9 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_10 = load_b_smem_addr_0 + 10 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_11 = load_b_smem_addr_0 + 11 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_12 = load_b_smem_addr_0 + 12 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_13 = load_b_smem_addr_0 + 13 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_14 = load_b_smem_addr_0 + 14 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_15 = load_b_smem_addr_0 + 15 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_smem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_smem_k, load_b_gmem_n, N);

    // int comp_c_frag_m = wid &  1;
    // int comp_c_frag_n = wid >> 1;

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_8), "l"(&b[load_b_gmem_addr + 8 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_9), "l"(&b[load_b_gmem_addr + 9 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_10), "l"(&b[load_b_gmem_addr + 10 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_11), "l"(&b[load_b_gmem_addr + 11 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_12), "l"(&b[load_b_gmem_addr + 12 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_13), "l"(&b[load_b_gmem_addr + 13 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_14), "l"(&b[load_b_gmem_addr + 14 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_15), "l"(&b[load_b_gmem_addr + 15 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < K / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
        // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
        // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 32], BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 48], BK + APAD);
        wmma::load_matrix_sync(frag_a[4], &s_a[smem_sel * s_a_db_offset + 64], BK + APAD);
        wmma::load_matrix_sync(frag_a[5], &s_a[smem_sel * s_a_db_offset + 80], BK + APAD);
        wmma::load_matrix_sync(frag_a[6], &s_a[smem_sel * s_a_db_offset + 96], BK + APAD);
        wmma::load_matrix_sync(frag_a[7], &s_a[smem_sel * s_a_db_offset + 112], BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
        // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[4], &s_b[smem_sel * s_b_db_offset + 64 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[5], &s_b[smem_sel * s_b_db_offset + 80 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[6], &s_b[smem_sel * s_b_db_offset + 96 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[7], &s_b[smem_sel * s_b_db_offset + 112 * (BN + BPAD) + wid * 32], BN + BPAD);

        // #pragma unroll
        // for (int i = 0; i < 4; i++) {
        //     #pragma unroll
        //     for (int j = 0; j < 4; j++) {
        //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
        //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
        //     }
        // }
        #pragma unroll
        for (int i = 0; i < 8; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        // __syncthreads();

        // wonder if the access block and computation block should change order
        // load A and B from global mem for next bk
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //     : "r"(load_a_smem_addr_1 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr +     K]));
        // if (bk % 2 == 0){
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_a_smem_addr_0 + smem_sel_next * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));  
        // }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_8 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 8 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_9 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 9 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_10 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 10 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_11 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 11 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_12 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 12 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_13 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 13 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_14 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 14 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_15 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 15 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    // wmma::load_matrix_sync(frag_a[0][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64     ) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][2], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1][3], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);

    // wmma::load_matrix_sync(frag_b[0][0], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][0], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64     ], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) +  0], BK + APAD);
    // wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) +  0], BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 16) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 32) * (BK + APAD) + 16], BK + APAD);
    // wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (comp_c_frag_m * 64 + 48) * (BK + APAD) + 16], BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 32], BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 48], BK + APAD);
    wmma::load_matrix_sync(frag_a[4], &s_a[smem_sel * s_a_db_offset + 64], BK + APAD);
    wmma::load_matrix_sync(frag_a[5], &s_a[smem_sel * s_a_db_offset + 80], BK + APAD);
    wmma::load_matrix_sync(frag_a[6], &s_a[smem_sel * s_a_db_offset + 96], BK + APAD);
    wmma::load_matrix_sync(frag_a[7], &s_a[smem_sel * s_a_db_offset + 112], BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][1], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][2], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[0][3], &s_b[smem_sel * s_b_db_offset +                    comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 16], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][2], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 32], BN + BPAD);
    // wmma::load_matrix_sync(frag_b[1][3], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + comp_c_frag_n * 64 + 48], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[4], &s_b[smem_sel * s_b_db_offset + 64 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[5], &s_b[smem_sel * s_b_db_offset + 80 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[6], &s_b[smem_sel * s_b_db_offset + 96 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[7], &s_b[smem_sel * s_b_db_offset + 112 * (BN + BPAD) + wid * 32], BN + BPAD);

    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::mma_sync(frag_c[i][j], frag_a[0][i], frag_b[0][j], frag_c[i][j]);
    //         wmma::mma_sync(frag_c[i][j], frag_a[1][i], frag_b[1][j], frag_c[i][j]);
    //     }
    // }

    // wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    // wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);

    #pragma unroll
    for (int i = 0; i < 8; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    int store_c_gmem_m = by * BM;
    int store_c_gmem_n = bx * BN + wid * 32;
    int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // #pragma unroll
    // for (int i = 0; i < 4; i++) {
    //     #pragma unroll
    //     for (int j = 0; j < 4; j++) {
    //         wmma::store_matrix_sync(&c[store_c_gmem_addr + i * 16 * N + j * 16], frag_c[i][j], N, wmma::mem_row_major);
    //     }
    // }
    wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
#endif
}

__global__ void eed_hgemm_m8n128k64x4_v7_bt(
    half *__restrict__ a, half *__restrict__ b, half *__restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif

    const int BM = 8;
    const int BN = 128;
    const int BK = 64;

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int warp_id = tid / 32;

    // only support dim-M [1, 8]
    if (bx >= N / BN)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + BM * (BK * 2 + APAD);
    int s_b_db_offset = BN * (BK + BPAD);

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::col_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);       // 0 ~ 7
    int load_a_smem_k = (tid & 15) << 3;  // 0 ~ 120

    // B tile : 128 x 64 (BN, BK)
    // each row: 64 * sizeof(half) = 128 Bytes, load float4 ---> 128 Bytes / 16Bytes per thread = 8 threads
    int load_b_smem_k = (tid % 8) * 8;  // 0 ~ 56
    int load_b_smem_n = (tid / 8) * 8;  // 0 ~ 120

    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 2 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_n, load_b_smem_k, BK + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 + (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BK + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BK + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_n, load_b_gmem_k, K);

    // load the first tile of mat_a & mat_b
    {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0),
                  "l"(&a[load_a_gmem_addr]));
        }
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr + K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * K]));

        asm("cp.async.commit_group;\n" ::);
        asm("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

#pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK;

        // async load the other tile of mat_a & mat_b
        // loop time is odd?
        if (bk % 2 == 0) {
            if (load_a_gmem_m < M) {
                asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                    : "r"(load_a_smem_addr_0),
                      "l"(&a[load_a_gmem_addr]));
            }
        }
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * K]));

        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[(bk - 1) % 2 * BK + 0], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[(bk - 1) % 2 * BK + 16], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[(bk - 1) % 2 * BK + 32], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[(bk - 1) % 2 * BK + 48], 2 * BK + APAD);

        // 32 x 16
        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD)], BK + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 16], BK + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 32], BK + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 48], BK + BPAD);

#pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        asm("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    wmma::load_matrix_sync(frag_a[0], &s_a[1 * BK + 0], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[1 * BK + 16], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[1 * BK + 32], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[1 * BK + 48], 2 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD)], BK + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 16], BK + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 32], BK + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + warp_id * 32 * (BK + BPAD) + 48], BK + BPAD);

#pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    wmma::store_matrix_sync(&smem[warp_id * 32], frag_c, BN + BPAD, wmma::mem_row_major);

    __syncthreads();

    load_b_smem_n = (tid % 16) * 8;
    load_b_gmem_n = bx * BN + load_b_smem_n;

    int store_c_smem_addr = OFFSET(load_a_smem_m, load_b_smem_n, BN + BPAD);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_b_gmem_n, N);

    if (load_a_gmem_m < M) {
        if (gridDim.z > 1) {
            atomicAdd(((half2 *)(&c[store_c_gmem_addr])),
                      *((half2 *)(&smem[store_c_smem_addr])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2])),
                      *((half2 *)(&smem[store_c_smem_addr + 2])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 4])),
                      *((half2 *)(&smem[store_c_smem_addr + 4])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 6])),
                      *((half2 *)(&smem[store_c_smem_addr + 6])));
        } else {
            *((half2 *)(&c[store_c_gmem_addr])) = *((half2 *)(&smem[store_c_smem_addr]));
            *((half2 *)(&c[store_c_gmem_addr + 2])) = *((half2 *)(&smem[store_c_smem_addr + 2]));
            *((half2 *)(&c[store_c_gmem_addr + 4])) = *((half2 *)(&smem[store_c_smem_addr + 4]));
            *((half2 *)(&c[store_c_gmem_addr + 6])) = *((half2 *)(&smem[store_c_smem_addr + 6]));
        }
    }
}

__global__ void eed_hgemm_m8n128k64x4_v7(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif

    const int BM = 8;
    const int BN = 128;
    const int BK = 64;

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int wid = tid >> 5;

    // only support dim-M [1, 8]
    if (bx >= N / BN)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + BM * (BK * 2 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);       // 0 ~ 7
    int load_a_smem_k = (tid & 15) << 3;  // 0 ~ 120
    int load_b_smem_k = (tid >> 4) << 3;  // 0 ~ 56
    int load_b_smem_n = (tid & 15) << 3;  // 0 ~ 120

    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 2 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_k, load_b_gmem_n, N);

    // load the first tile of mat_a & mat_b
    {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0),
                  "l"(&a[load_a_gmem_addr]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // async load the other tile of mat_a & mat_b
        // bk is odd?
        if (bk % 2 == 0) {
            if (load_a_gmem_m < M) {
                asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                    : "r"(load_a_smem_addr_0),
                      "l"(&a[load_a_gmem_addr]));
            }
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[(bk - 1) % 2 * BK + 0], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[(bk - 1) % 2 * BK + 16], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[(bk - 1) % 2 * BK + 32], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[(bk - 1) % 2 * BK + 48], 2 * BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

#pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        asm("cp.async.wait_group 0;\n" ::);

        // it seems compute correctly without this sync.
        // if without this sync, the runtime is reduced by 10us
        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    wmma::load_matrix_sync(frag_a[0], &s_a[1 * BK + 0], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[1 * BK + 16], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[1 * BK + 32], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[1 * BK + 48], 2 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    // int store_c_gmem_m = by * BM;
    // int store_c_gmem_n = bx * BN + wid * 32;
    // int store_c_gmem_addr = OFFSET(store_c_gmem_m, store_c_gmem_n, N);
    // wmma::store_matrix_sync(&c[store_c_gmem_addr], frag_c, N, wmma::mem_row_major);
    wmma::store_matrix_sync(&smem[wid * 32], frag_c, BN + BPAD, wmma::mem_row_major);

    __syncthreads();

    int store_c_smem_addr = OFFSET(load_a_smem_m, load_b_smem_n, BN + BPAD);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_b_gmem_n, N);

    if (load_a_gmem_m < M) {
        if (gridDim.z > 1) {
            atomicAdd(((half2 *)(&c[store_c_gmem_addr])),
                      *((half2 *)(&smem[store_c_smem_addr])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2])),
                      *((half2 *)(&smem[store_c_smem_addr + 2])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 4])),
                      *((half2 *)(&smem[store_c_smem_addr + 4])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 6])),
                      *((half2 *)(&smem[store_c_smem_addr + 6])));
        } else {
            *((half2 *)(&c[store_c_gmem_addr])) = *((half2 *)(&smem[store_c_smem_addr]));
            *((half2 *)(&c[store_c_gmem_addr + 2])) = *((half2 *)(&smem[store_c_smem_addr + 2]));
            *((half2 *)(&c[store_c_gmem_addr + 4])) = *((half2 *)(&smem[store_c_smem_addr + 4]));
            *((half2 *)(&c[store_c_gmem_addr + 6])) = *((half2 *)(&smem[store_c_smem_addr + 6]));
        }
    }
}

// BM = 16, BN = 128, BK = 64
// LDK = BK + APAD = 72
// LDN = BN + BPAD = 136
template <int BM, int BN, int BK, int LDK, int LDN>
__global__ void eed_hgemm_m8n128k64x4_v8(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int wid = tid >> 5; // 0, 1, 2, 3, 4, 5, 6, 7

    // only support dim-M [1, 8]
    if (bx >= N / BN)
        return;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * LDK;
    int s_a_db_offset = BM * LDK;
    int s_b_db_offset = BK * LDN;

    wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);       // 0 ~ 15
    int load_a_smem_k = (tid & 15) << 2;  // 0 ~ 60
    int load_b_smem_k = (tid >> 4) << 2;  // 0 ~ 60
    int load_b_smem_n = (tid & 15) << 3;  // 0 ~ 120

    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int B_UNIT = LDN * sizeof(half);
    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, LDK) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, LDN) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     B_UNIT;
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * B_UNIT;
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * B_UNIT;

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_k, load_b_gmem_n, N);

    // load the first tile of mat_a & mat_b
    {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 8;\n" :
                : "r"(load_a_smem_addr_0),
                  "l"(&a[load_a_gmem_addr]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
    
        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        int loop_offset_a = smem_sel_next * s_a_db_offset * (int)sizeof(half);
        int loop_offset_b = smem_sel_next * s_b_db_offset * (int)sizeof(half);

        // async load the other tile of mat_a & mat_b
        // bk is odd?
        // if (bk % 2 == 0) {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 8;\n" :
                    : "r"(load_a_smem_addr_0 + loop_offset_a),
                      "l"(&a[load_a_gmem_addr]));
        }

        // }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + loop_offset_b), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + loop_offset_b), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + loop_offset_b), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + loop_offset_b), "l"(&b[load_b_gmem_addr + 3 * N]));
    
        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        int s_a_addr = smem_sel * s_a_db_offset;
        int s_b_addr = smem_sel * s_b_db_offset + wid * 16;
        
        wmma::load_matrix_sync(frag_a[0], &s_a[s_a_addr], LDK);
        wmma::load_matrix_sync(frag_a[1], &s_a[s_a_addr + 16], LDK);
        wmma::load_matrix_sync(frag_a[2], &s_a[s_a_addr + 32], LDK);
        wmma::load_matrix_sync(frag_a[3], &s_a[s_a_addr + 48], LDK);

        wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDN);
        wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16 * LDN], LDN);
        wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32 * LDN], LDN);
        wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48 * LDN], LDN);

        wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
        wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);
        wmma::mma_sync(frag_c, frag_a[2], frag_b[2], frag_c);
        wmma::mma_sync(frag_c, frag_a[3], frag_b[3], frag_c);

        asm("cp.async.wait_group 0;\n" ::);

        // it seems compute correctly without this sync.
        // if without this sync, the runtime is reduced by 10us
        __syncthreads();
    }

    int s_a_addr = s_a_db_offset;
    int s_b_addr = s_b_db_offset + wid * 16;

    wmma::load_matrix_sync(frag_a[0], &s_a[s_a_addr], LDK);
    wmma::load_matrix_sync(frag_a[1], &s_a[s_a_addr + 16], LDK);
    wmma::load_matrix_sync(frag_a[2], &s_a[s_a_addr + 32], LDK);
    wmma::load_matrix_sync(frag_a[3], &s_a[s_a_addr + 48], LDK);

    wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDN);
    wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16 * LDN], LDN);
    wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32 * LDN], LDN);
    wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48 * LDN], LDN);

    wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);
    wmma::mma_sync(frag_c, frag_a[2], frag_b[2], frag_c);
    wmma::mma_sync(frag_c, frag_a[3], frag_b[3], frag_c);

    wmma::store_matrix_sync(&smem[wid * 16], frag_c, LDN, wmma::mem_row_major);

    __syncthreads();

    int store_c_smem_addr = OFFSET(load_a_smem_m, load_b_smem_n, LDN);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_b_gmem_n, N);

    if (load_a_gmem_m < M) {
        if (gridDim.z > 1) {
            atomicAdd(((half2 *)(&c[store_c_gmem_addr])),
                      *((half2 *)(&smem[store_c_smem_addr])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2])),
                      *((half2 *)(&smem[store_c_smem_addr + 2])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 4])),
                      *((half2 *)(&smem[store_c_smem_addr + 4])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 6])),
                      *((half2 *)(&smem[store_c_smem_addr + 6])));
        } else {
            *((float4*)(&c[store_c_gmem_addr])) = *((float4*)(&smem[store_c_smem_addr]));
        }
    }
}


// BM = 16, BN = 128, BK = 64
// LDK = BK + APAD = 72
// LDN = BN + BPAD = 136
template <int BM, int BN, int BK, int LDK, int LDN>
__global__ void eed_hgemm_m8n128k64x4_v8_tr(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int wid = tid >> 5; // 0, 1, 2, 3, 4, 5, 6, 7

    // only support dim-M [1, 8]
    if (bx >= N / BN)
        return;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * LDK;
    int s_a_db_offset = BM * LDK;
    int s_b_db_offset = BN * LDK;

    wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::col_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 16, 16, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);       // 0 ~ 15
    int load_a_smem_k = (tid & 15) << 2;  // 0 ~ 60
    int load_b_smem_n = (tid >> 3) << 2;  // 0 ~ 120
    int load_b_smem_k = (tid & 7) << 3;  // 0 ~ 60

    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int B_UNIT = LDK * sizeof(half);
    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, LDK) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_n, load_b_smem_k, LDK) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     B_UNIT;
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * B_UNIT;
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * B_UNIT;

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_n, load_b_gmem_k, K);

    // load the first tile of mat_a & mat_b
    {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 8;\n" :
                : "r"(load_a_smem_addr_0),
                  "l"(&a[load_a_gmem_addr]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * K]));
    
        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK;

        int loop_offset_a = smem_sel_next * s_a_db_offset * (int)sizeof(half);
        int loop_offset_b = smem_sel_next * s_b_db_offset * (int)sizeof(half);

        // async load the other tile of mat_a & mat_b
        // bk is odd?
        // if (bk % 2 == 0) {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 8;\n" :
                    : "r"(load_a_smem_addr_0 + loop_offset_a),
                      "l"(&a[load_a_gmem_addr]));
        }

        // }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + loop_offset_b), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + loop_offset_b), "l"(&b[load_b_gmem_addr +     K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + loop_offset_b), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + loop_offset_b), "l"(&b[load_b_gmem_addr + 3 * K]));
    
        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        int s_a_addr = smem_sel * s_a_db_offset;
        int s_b_addr = smem_sel * s_b_db_offset + wid * 16 * LDK;
        
        wmma::load_matrix_sync(frag_a[0], &s_a[s_a_addr], LDK);
        wmma::load_matrix_sync(frag_a[1], &s_a[s_a_addr + 16], LDK);
        wmma::load_matrix_sync(frag_a[2], &s_a[s_a_addr + 32], LDK);
        wmma::load_matrix_sync(frag_a[3], &s_a[s_a_addr + 48], LDK);

        wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDK);
        wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16], LDK);
        wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32], LDK);
        wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48], LDK);

        wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
        wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);
        wmma::mma_sync(frag_c, frag_a[2], frag_b[2], frag_c);
        wmma::mma_sync(frag_c, frag_a[3], frag_b[3], frag_c);

        asm("cp.async.wait_group 0;\n" ::);

        // it seems compute correctly without this sync.
        // if without this sync, the runtime is reduced by 10us
        __syncthreads();
    }

    int s_a_addr = s_a_db_offset;
    int s_b_addr = s_b_db_offset + wid * 16 * LDK;

    wmma::load_matrix_sync(frag_a[0], &s_a[s_a_addr], LDK);
    wmma::load_matrix_sync(frag_a[1], &s_a[s_a_addr + 16], LDK);
    wmma::load_matrix_sync(frag_a[2], &s_a[s_a_addr + 32], LDK);
    wmma::load_matrix_sync(frag_a[3], &s_a[s_a_addr + 48], LDK);

    wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDK);
    wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16], LDK);
    wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32], LDK);
    wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48], LDK);

    wmma::mma_sync(frag_c, frag_a[0], frag_b[0], frag_c);
    wmma::mma_sync(frag_c, frag_a[1], frag_b[1], frag_c);
    wmma::mma_sync(frag_c, frag_a[2], frag_b[2], frag_c);
    wmma::mma_sync(frag_c, frag_a[3], frag_b[3], frag_c);

    wmma::store_matrix_sync(&smem[wid * 16], frag_c, LDN, wmma::mem_row_major);

    __syncthreads();

    int load_c_smem_n = (tid & 15) << 3;  // 0 ~ 120
    int load_c_gmem_n = bx * BN + load_c_smem_n;
    int store_c_smem_addr = OFFSET(load_a_smem_m, load_c_smem_n, LDN);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_c_gmem_n, N);

    if (load_a_gmem_m < M) {
        if (gridDim.z > 1) {
            atomicAdd(((half2 *)(&c[store_c_gmem_addr])),
                      *((half2 *)(&smem[store_c_smem_addr])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2])),
                      *((half2 *)(&smem[store_c_smem_addr + 2])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 4])),
                      *((half2 *)(&smem[store_c_smem_addr + 4])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 6])),
                      *((half2 *)(&smem[store_c_smem_addr + 6])));
        } else {
            *((float4*)(&c[store_c_gmem_addr])) = *((float4*)(&smem[store_c_smem_addr]));
        }
    }
}


/***
 * BM=8 BN=256 BK=32
 * LDK = 2 * BK + APAD = 72
 * LDN = BN + PAD = 264
*/
template <int BM, int BN, int BK, int LDK, int LDN>
__global__ void eed_hgemm_m8n256k32x8(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif
    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int wid = tid >> 5;         // WARP id

    // bx for N, if bx is out of range, return
    if (bx >= N / BN)
        return;

    __shared__ half smem[BM * (LDK) + 2 * BK * (LDN)];
    half *s_a = smem;
    half *s_b = smem + BM * (LDK);
    // double buffer offset
    int s_b_db_offset = BK * (LDN);

    //                             M   N   K
    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[2];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[2];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    /**
     * 通过位运算获取每个thread对应的索引位置
     * load_a 每个warp访问1*64个元素，通过cp.async指定访问8B即4个half完成
     * load_b 每个warp访问4*256个元素，通过cp.async指定访问16B即8个half完成
    */
    int load_a_smem_m = (tid >> 5);      // 0 ~ 7    | 0 1  2 ...  7   每个索引32个一组 共8组
    int load_a_smem_k = (tid & 31) << 1; // 0 ~ 60    | 0 2  4 ... 60 (32个数)  循环8组  间隔是2个half 8B
    int load_b_smem_k = (tid >> 5) << 2; // 0 ~ 28   | 0 8 16 ... 28   每个索引32个一组 共8组
    int load_b_smem_n = (tid & 31) << 3; // 0 ~ 248  | 0 8 16 ... 248(32个数)  循环8组  间隔是8个half 16B

    // ptx address space conversion
    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, LDK) * sizeof(half);
    int load_b_smem_addrs[4];
    #pragma unroll
    for(int i=0; i<4; i++)
        load_b_smem_addrs[i] = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, LDN) * sizeof(half) + i * (LDN) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_k, load_b_gmem_n, N);

    // load the first tile of mat_a & mat_b
    if (load_a_gmem_m < M) {
        asm("cp.async.ca.shared.global [%0], [%1], 4;\n" :
            : "r"(load_a_smem_addr_0),
                "l"(&a[load_a_gmem_addr]));
    }
    #pragma unroll
    for(int i=0; i<4; i++)
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addrs[i]), "l"(&b[load_b_gmem_addr + i * N]));

    asm ("cp.async.commit_group;\n" ::);
    asm ("cp.async.wait_group 0;\n" ::);
    __syncthreads();
    // if(bx==0&&tid==32){
    //     for(int i=0; i<M; i++){
    //         bool correct = true;
    //         for(int j=0; j<64; j++){
    //             if(abs( __half2float(s_a[OFFSET(i,j,BK*2+APAD)]) - __half2float(a[OFFSET(i, j + k_start, K)]))>1e-5){
    //                 printf("wrong(%d,%d,%d) %f|%f ", i, j, bz, __half2float(s_a[OFFSET(i,j+k_start,BK*2+APAD)]), __half2float(a[OFFSET(i, j, K)]));
    //                 correct = false;
    //             }
    //         }
    //         if(!correct)
    //             printf("\n");
    //     }
    // }

    #pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = smem_sel ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        /**
         * async load the other tile of mat_a & mat_b
         * 由于a_smem是在BK维度进行double buffer
         * 而一次读进来的数据是够两轮使用的
         * 因此当bk为偶数时进行新的读取
        */
        if (bk % 2 == 0) {
            if (load_a_gmem_m < M) {
                asm("cp.async.ca.shared.global [%0], [%1], 4;\n" :
                    : "r"(load_a_smem_addr_0),
                        "l"(&a[load_a_gmem_addr]));
            }
        }
        int load_b_smem_bias = smem_sel_next * s_b_db_offset * (int)sizeof(half);
        #pragma unroll
        for(int i=0; i<4; i++)
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_b_smem_addrs[i] + load_b_smem_bias), "l"(&b[load_b_gmem_addr + i * N]));

        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        #pragma unroll
        for(int i=0; i<2; i++)
            wmma::load_matrix_sync(frag_a[i], &s_a[(bk - 1) % 2 * BK + i * 16], LDK);
        #pragma unroll
        for(int i=0; i<2; i++)
            wmma::load_matrix_sync(frag_b[i], &s_b[smem_sel * s_b_db_offset + i * 16 * (LDN) + wid * 32], LDN);
        
        #pragma unroll
        for (int i = 0; i < 2; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        asm("cp.async.wait_group 0;\n" ::);
        __syncthreads();
    }

    int smem_sel = ((K / gridDim.z) / BK - 1) & 1;

    #pragma unroll
    for(int i=0; i<2; i++)
        wmma::load_matrix_sync(frag_a[i], &s_a[smem_sel * BK + i * 16], LDK);
    #pragma unroll
    for(int i=0; i<2; i++)
        wmma::load_matrix_sync(frag_b[i], &s_b[smem_sel * s_b_db_offset + i * 16 * LDN + wid * 32], LDN);

    #pragma unroll
    for (int i = 0; i < 2; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }
    // if(tid==0&&bx==0) printf("%d %f %f %f %f\n", bz, __half2float(frag_c.x[0]), __half2float(frag_c.x[1]), __half2float(frag_c.x[2]), __half2float(frag_c.x[3]));
    wmma::store_matrix_sync(&smem[wid * 32], frag_c, LDN, wmma::mem_row_major);

    // 这里同步是因为写回策略不是按照frac_c来进行的
    // 可以尝试改变策略来进行不同步的写回

    // int store_c_m = (tid & 31) >> 2, store_c_n = (tid & 3) << 3 + wid * 32;
    // int store_c_gmem_addr = store_c_m * N + store_c_n + bx * BN;
    // int store_c_smem_addr = store_c_m * LDN + store_c_n;
    // if (store_c_m < M) {
    //     #pragma unroll
    //     for(int i = 0; i < 4; i++)
    //         atomicAdd(((half2 *)(&c[store_c_gmem_addr + i * 2])),
    //                 *((half2 *)(&smem[store_c_smem_addr + i * 2])));
    // }

    __syncthreads();
    int store_c_smem_addr = OFFSET(load_a_smem_m, load_b_smem_n, LDN);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_b_gmem_n, N);

    if (load_a_gmem_m < M) {
        #pragma unroll
        for(int i=0; i<4; i++)
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2 * i])),
                      *((half2 *)(&smem[store_c_smem_addr + 2 * i])));
    }
}


template <int SPLITK>
__global__ void eed_hgemv_m1n128k64x4_v6(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 128;
    const int BK = 64;

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;
    int k_start = K / SPLITK * bz;
    int k_end = K / SPLITK * (bz + 1);
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    half pads[8] = {__float2half(0.0f)};

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 2 + APAD);
    int s_a_db_offset = BM * (BK * 2 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);
    int load_a_smem_k = (tid & 15) << 3;
    int load_b_smem_k = (tid >> 4) << 3;
    int load_b_smem_n = (tid & 15) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 2 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_smem_addr = OFFSET(load_a_smem_m, load_a_smem_k, BK * 2 + APAD);
    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_k, load_b_gmem_n, N);

    *((float4*)(s_a + load_a_smem_addr + 0 * s_a_db_offset)) = (load_a_smem_m == 0) ? 
        *((float4*)(&a[load_a_gmem_addr])) : 
        *((float4*)(&pads[0]));

    *((float4*)(s_a + load_a_smem_addr + 1 * s_a_db_offset)) = (load_a_smem_m == 0) ? 
        *((float4*)(&a[load_a_gmem_addr])) : 
        *((float4*)(&pads[0]));

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 8
    for (int bk = 1; bk < (K / SPLITK) / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 0 ], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 16], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 32], 2 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 2 * BK + 48], 2 * BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

        #pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        if (bk % 2 == 0 && load_a_smem_m == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
            asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 1 * BK + 0], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 1 * BK + 16], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 1 * BK + 32], 2 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 1 * BK + 48], 2 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    wmma::store_matrix_sync(&smem[wid * 32], frag_c, BN + BPAD, wmma::mem_row_major);

    __syncthreads();

    int store_c_smem_m = 0;
    int store_c_smem_n = tid;
    int store_c_gmem_m = by * BM + store_c_smem_m;
    int store_c_gmem_n = bx * BN + store_c_smem_n;

    atomicAdd(&c[store_c_gmem_n], smem[store_c_smem_n]);
#endif
}


template <int SPLITK>
__global__ void eed_hgemv_m1n256k64x4_v8(
    half * __restrict__ a, half * __restrict__ b, half * __restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ >= 800

    const int BM = 8;
    const int BN = 256;
    const int BK = 64;

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;
    int k_start = K / SPLITK * bz;
    int k_end = K / SPLITK * (bz + 1);
    int tid = threadIdx.x;
    int wid = tid >> 5;

    if (bx >= N / BN)
        return;

    const int APAD = 8;
    const int BPAD = 8;

    half pads[8] = {__float2half(0.0f)};

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + 2 * BM * (BK * 4 + APAD);
    int s_a_db_offset = BM * (BK * 4 + APAD);
    int s_b_db_offset = BK * (BN + BPAD);

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::row_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 5);
    int load_a_smem_k = (tid & 31) << 3;
    int load_b_smem_k = (tid >> 5) << 3;
    int load_b_smem_n = (tid & 31) << 3;

    int s_a_base_addr = __cvta_generic_to_shared(s_a);
    int s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, BK * 4 + APAD) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_k, load_b_smem_n, BN + BPAD) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 +     (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * (BN + BPAD) * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * (BN + BPAD) * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_smem_addr = OFFSET(load_a_smem_m, load_a_smem_k, BK * 4 + APAD);
    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_k, load_b_gmem_n, N);

    *((float4*)(s_a + load_a_smem_addr + 0 * s_a_db_offset)) = (load_a_smem_m == 0) ? 
        *((float4*)(&a[load_a_gmem_addr])) : 
        *((float4*)(&pads[0]));

    *((float4*)(s_a + load_a_smem_addr + 1 * s_a_db_offset)) = (load_a_smem_m == 0) ? 
        *((float4*)(&a[load_a_gmem_addr])) : 
        *((float4*)(&pads[0]));

    {
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    #pragma unroll 32
    for (int bk = 1; bk < (K / SPLITK) / BK; bk++) {

        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK * N;

        // compute A X B for this bk
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 0 ], 4 * BK + APAD);
        wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 16], 4 * BK + APAD);
        wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 32], 4 * BK + APAD);
        wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + (bk - 1) % 4 * BK + 48], 4 * BK + APAD);

        wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
        wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

        #pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        // if (bk % 4 == 0 && load_a_smem_m == 0){
        //     asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //         : "r"(load_a_smem_addr_0 + 0 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        //     asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
        //         : "r"(load_a_smem_addr_0 + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[load_a_gmem_addr        ]));
        // }
        if (bk % 4 == 0){
            asm ("cp.async.ca.shared.global [%0], [%1], 4;\n" :
                : "r"(s_a_base_addr + (tid & 127 << 1) * (int)sizeof(half) + (tid >> 7) * s_a_db_offset * (int)sizeof(half)), "l"(&a[k_start + bk * BK + (tid & 127 << 1)]));
            // asm ("cp.async.ca.shared.global [%0], [%1], 4;\n" :
            //     : "r"(s_a_base_addr + tid * (int)sizeof(half) + 1 * s_a_db_offset * (int)sizeof(half)), "l"(&a[k_start + tid + bk * BK]));
        }
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr        ]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr +     N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * N]));
        asm ("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * N]));

        asm ("cp.async.commit_group;\n" ::);
        asm ("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int smem_sel = ((K / BK) & 1) ^ 1;

    wmma::load_matrix_sync(frag_a[0], &s_a[smem_sel * s_a_db_offset + 1 * BK + 0 ], 4 * BK + APAD);
    wmma::load_matrix_sync(frag_a[1], &s_a[smem_sel * s_a_db_offset + 1 * BK + 16], 4 * BK + APAD);
    wmma::load_matrix_sync(frag_a[2], &s_a[smem_sel * s_a_db_offset + 1 * BK + 32], 4 * BK + APAD);
    wmma::load_matrix_sync(frag_a[3], &s_a[smem_sel * s_a_db_offset + 1 * BK + 48], 4 * BK + APAD);

    wmma::load_matrix_sync(frag_b[0], &s_b[smem_sel * s_b_db_offset +                    wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[1], &s_b[smem_sel * s_b_db_offset + 16 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[2], &s_b[smem_sel * s_b_db_offset + 32 * (BN + BPAD) + wid * 32], BN + BPAD);
    wmma::load_matrix_sync(frag_b[3], &s_b[smem_sel * s_b_db_offset + 48 * (BN + BPAD) + wid * 32], BN + BPAD);

    #pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    wmma::store_matrix_sync(&smem[wid * 32], frag_c, BN + BPAD, wmma::mem_row_major);

    __syncthreads();

    int store_c_smem_m = 0;
    int store_c_smem_n = tid;
    int store_c_gmem_m = by * BM + store_c_smem_m;
    int store_c_gmem_n = bx * BN + store_c_smem_n;

    atomicAdd(&c[store_c_gmem_n], smem[store_c_smem_n]);
#endif
}


template <int BM, int BN, int BK, int LDK_A, int LDK_B>
__global__ void eed_hgemm_m8n128k64x4_v8_bt(
    half *__restrict__ a, half *__restrict__ b, half *__restrict__ c,
    const int M, const int N, const int K) {
#if __CUDA_ARCH__ < 800
    return;
#endif

    int bx = blockIdx.x;
    int by = blockIdx.y;
    int bz = blockIdx.z;

    int k_start = K / gridDim.z * bz;

    int tid = threadIdx.x;
    int warp_id = tid / 32;

    // only support dim-M [1, 8]
    if (bx >= N / BN)
        return;

    extern __shared__ half smem[];
    half *s_a = smem;
    half *s_b = smem + BM * LDK_A;
    int s_b_db_offset = BN * LDK_B;

    wmma::fragment<wmma::matrix_a, 8, 32, 16, half, wmma::row_major> frag_a[4];
    wmma::fragment<wmma::matrix_b, 8, 32, 16, half, wmma::col_major> frag_b[4];
    wmma::fragment<wmma::accumulator, 8, 32, 16, half> frag_c;

    wmma::fill_fragment(frag_c, __float2half(0.0f));

    int load_a_smem_m = (tid >> 4);       // 0 ~ 7
    int load_a_smem_k = (tid & 15) << 3;  // 0 ~ 120

    // B tile : 128 x 64 (BN, BK)
    // each row: 64 * sizeof(half) = 128 Bytes, load float4 ---> 128 Bytes / 16Bytes per thread = 8 threads
    int load_b_smem_k = (tid % 8) * 8;  // 0 ~ 56
    int load_b_smem_n = (tid / 8) * 8;  // 0 ~ 120

    size_t s_a_base_addr = __cvta_generic_to_shared(s_a);
    size_t s_b_base_addr = __cvta_generic_to_shared(s_b);

    int load_a_smem_addr_0 = s_a_base_addr + OFFSET(load_a_smem_m, load_a_smem_k, LDK_A) * sizeof(half);
    int load_b_smem_addr_0 = s_b_base_addr + OFFSET(load_b_smem_n, load_b_smem_k, LDK_B) * sizeof(half);
    int load_b_smem_addr_1 = load_b_smem_addr_0 + LDK_B * sizeof(half);
    int load_b_smem_addr_2 = load_b_smem_addr_0 + 2 * LDK_B * sizeof(half);
    int load_b_smem_addr_3 = load_b_smem_addr_0 + 3 * LDK_B * sizeof(half);
    int load_b_smem_addr_4 = load_b_smem_addr_0 + 4 * LDK_B * sizeof(half);
    int load_b_smem_addr_5 = load_b_smem_addr_0 + 5 * LDK_B * sizeof(half);
    int load_b_smem_addr_6 = load_b_smem_addr_0 + 6 * LDK_B * sizeof(half);
    int load_b_smem_addr_7 = load_b_smem_addr_0 + 7 * LDK_B * sizeof(half);

    int load_a_gmem_m = by * BM + load_a_smem_m;
    int load_b_gmem_n = bx * BN + load_b_smem_n;
    int load_a_gmem_k = k_start + load_a_smem_k;
    int load_b_gmem_k = k_start + load_b_smem_k;

    int load_a_gmem_addr = OFFSET(load_a_gmem_m, load_a_gmem_k, K);
    int load_b_gmem_addr = OFFSET(load_b_gmem_n, load_b_gmem_k, K);

    // load the first tile of mat_a & mat_b
    {
        if (load_a_gmem_m < M) {
            asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                : "r"(load_a_smem_addr_0),
                  "l"(&a[load_a_gmem_addr]));
        }
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0), "l"(&b[load_b_gmem_addr]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1), "l"(&b[load_b_gmem_addr + K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3), "l"(&b[load_b_gmem_addr + 3 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4), "l"(&b[load_b_gmem_addr + 4 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5), "l"(&b[load_b_gmem_addr + 5 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6), "l"(&b[load_b_gmem_addr + 6 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7), "l"(&b[load_b_gmem_addr + 7 * K]));

        asm("cp.async.commit_group;\n" ::);
        asm("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

#pragma unroll 32
    for (int bk = 1; bk < (K / gridDim.z) / BK; bk++) {
        int smem_sel = (bk & 1) ^ 1;
        int smem_sel_next = ((bk - 1) & 1) ^ 1;

        load_a_gmem_addr += BK;
        load_b_gmem_addr += BK;

        // async load the other tile of mat_a & mat_b
        // loop time is odd?
        if (bk % 2 == 0) {
            if (load_a_gmem_m < M) {
                asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
                    : "r"(load_a_smem_addr_0),
                      "l"(&a[load_a_gmem_addr]));
            }
        }
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_0 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_1 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_2 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 2 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_3 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 3 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_4 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 4 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_5 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 5 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_6 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 6 * K]));
        asm("cp.async.ca.shared.global [%0], [%1], 16;\n" :
            : "r"(load_b_smem_addr_7 + smem_sel_next * s_b_db_offset * (int)sizeof(half)), "l"(&b[load_b_gmem_addr + 7 * K]));

        asm("cp.async.commit_group;\n" ::);  // issue cp.async.wait_group at the end of loop body

        // compute A X B for this bk
        int s_a_addr = (bk - 1) % 2 * BK;
        int s_b_addr = smem_sel * s_b_db_offset + warp_id * 32 * LDK_B;
        // note that BK / TILE_K = 2
        wmma::load_matrix_sync(frag_a[0], &s_a[s_a_addr + 0 ], LDK_A);
        wmma::load_matrix_sync(frag_a[1], &s_a[s_a_addr + 16], LDK_A);
        wmma::load_matrix_sync(frag_a[2], &s_a[s_a_addr + 32], LDK_A);
        wmma::load_matrix_sync(frag_a[3], &s_a[s_a_addr + 48], LDK_A);

        // 32 x 16
        wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDK_B);
        wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16], LDK_B);
        wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32], LDK_B);
        wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48], LDK_B);

#pragma unroll
        for (int i = 0; i < 4; i++) {
            wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
        }

        asm("cp.async.wait_group 0;\n" ::);

        __syncthreads();
    }

    int s_b_addr = (((K / BK) & 1) ^ 1) * s_b_db_offset + warp_id * 32 * LDK_B;

    wmma::load_matrix_sync(frag_a[0], &s_a[BK + 0 ], LDK_A);
    wmma::load_matrix_sync(frag_a[1], &s_a[BK + 16], LDK_A);
    wmma::load_matrix_sync(frag_a[2], &s_a[BK + 32], LDK_A);
    wmma::load_matrix_sync(frag_a[3], &s_a[BK + 48], LDK_A);

    wmma::load_matrix_sync(frag_b[0], &s_b[s_b_addr], LDK_B);
    wmma::load_matrix_sync(frag_b[1], &s_b[s_b_addr + 16], LDK_B);
    wmma::load_matrix_sync(frag_b[2], &s_b[s_b_addr + 32], LDK_B);
    wmma::load_matrix_sync(frag_b[3], &s_b[s_b_addr + 48], LDK_B);

#pragma unroll
    for (int i = 0; i < 4; i++) {
        wmma::mma_sync(frag_c, frag_a[i], frag_b[i], frag_c);
    }

    wmma::store_matrix_sync(&smem[warp_id * 32], frag_c, LDK_B, wmma::mem_row_major);

    __syncthreads();

    load_b_smem_n = (tid % 16) * 8;
    load_b_gmem_n = bx * BN + load_b_smem_n;

    int store_c_smem_addr = OFFSET(load_a_smem_m, load_b_smem_n, LDK_B);
    int store_c_gmem_addr = OFFSET(load_a_gmem_m, load_b_gmem_n, N);

    if (load_a_gmem_m < M) {
        if (gridDim.z > 1) {
            atomicAdd(((half2 *)(&c[store_c_gmem_addr])),
                      *((half2 *)(&smem[store_c_smem_addr])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 2])),
                      *((half2 *)(&smem[store_c_smem_addr + 2])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 4])),
                      *((half2 *)(&smem[store_c_smem_addr + 4])));
            atomicAdd(((half2 *)(&c[store_c_gmem_addr + 6])),
                      *((half2 *)(&smem[store_c_smem_addr + 6])));
        } else {
            *((float4*)(&c[store_c_gmem_addr])) = *((float4*)(&smem[store_c_smem_addr]));
        }
    }
}