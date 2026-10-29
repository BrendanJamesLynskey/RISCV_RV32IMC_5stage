// riscv_test.h — minimal bare-metal environment for running the riscv-tests
// ISA suites (rv32ui, rv32um, rv32uc) on BRV32P.
//
// BRV32P has machine mode only, no virtual memory and no host interface, so
// this replaces the upstream env: each test reports through a store to
// `tohost`, which the testbench sees on the core's retire trace.
//   tohost = 1                  pass
//   tohost = (testnum << 1) | 1 fail in test case `testnum`
// Any trap is unexpected in these suites and reports testnum 1337.

#ifndef BRV32P_RISCV_TEST_H
#define BRV32P_RISCV_TEST_H

#define TESTNUM gp

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U
#define RVTEST_RV32M RVTEST_RV32U
#define RVTEST_RV64M RVTEST_RV32U

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl  _start;                                                 \
_start:                                                                 \
        la      t0, trap_vector;                                        \
        csrw    mtvec, t0;                                              \
        li      TESTNUM, 0;                                             \
        init;                                                           \
        j       reset_done;                                             \
        .align  2;                                                      \
trap_vector:                                                            \
        li      TESTNUM, (1337 << 1) | 1;                               \
        la      t6, tohost;                                             \
        sw      TESTNUM, 0(t6);                                         \
1:      j       1b;                                                     \
reset_done:

#define RVTEST_CODE_END unimp

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li      TESTNUM, 1;                                             \
        la      t6, tohost;                                             \
        sw      TESTNUM, 0(t6);                                         \
1:      j       1b;

#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz    TESTNUM, 1b;                                            \
        sll     TESTNUM, TESTNUM, 1;                                    \
        or      TESTNUM, TESTNUM, 1;                                    \
        la      t6, tohost;                                             \
        sw      TESTNUM, 0(t6);                                         \
2:      j       2b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .pushsection .tohost, "aw", @progbits;                          \
        .align  6; .global tohost; tohost: .dword 0;                    \
        .align  6; .global fromhost; fromhost: .dword 0;                \
        .popsection;                                                    \
        .align  4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
