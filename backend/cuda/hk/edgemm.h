#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>

void edgemm(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n256k64(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k64(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k128(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemv_m1n128k64x4(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k64x4(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k64x4_bt(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemv_m1n256k64x4(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k64x4_amd(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n256k32x8(at::Tensor A, at::Tensor B, at::Tensor C);
void edgemm_m8n128k64x4_tr_amd(at::Tensor A, at::Tensor B, at::Tensor C);