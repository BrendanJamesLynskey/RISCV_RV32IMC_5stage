/* sha256.c — SHA-256 in plain RV32IMC C (the baseline) */
#define SHA256_NAME sha256
#define SIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))
#define SUM0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define SUM1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#include "sha256_impl.h"
