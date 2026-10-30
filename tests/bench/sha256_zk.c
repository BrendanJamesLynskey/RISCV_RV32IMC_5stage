/* sha256_zk.c — the same SHA-256, built with Zbkb and Zknh: the four sigma
   functions are single instructions, and GCC turns ROTR into ror/rori */
#define SHA256_NAME sha256_zk
#define SIG0(x) __builtin_riscv_sha256sig0(x)
#define SIG1(x) __builtin_riscv_sha256sig1(x)
#define SUM0(x) __builtin_riscv_sha256sum0(x)
#define SUM1(x) __builtin_riscv_sha256sum1(x)
#include "sha256_impl.h"
