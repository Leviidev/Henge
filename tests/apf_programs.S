// Apple's x86 flags (ACTLR_EL1.EnAPFLG, see core/translate.c): flag-setting instructions, each followed by an
// MRS NZCV into its own register. Natively (the host has the extension off) bits 26 and 27 read 0; test_apf.c
// adds what the hardware would put there and compares with the JIT. Inputs (x0..x7, x15, x28, SP) are never
// written; x6, x7, x15 and x28 live in the HvCpu, so they test the loads.
#include "harness.h"

    .text
    .p2align 14
    .globl _apf_programs_begin
    .globl _apf_programs_finish
_apf_programs_begin:

PROGRAM apf_cases
    adds x19, x0, x1
    mrs x19, nzcv
    subs w20, w2, w3
    mrs x20, nzcv
    cmp x6, x7
    mrs x21, nzcv
    adds x22, sp, #0x123
    mrs x22, nzcv
    subs w23, w4, w5, lsl #3
    mrs x23, nzcv
    adds x24, x0, w2, sxtb #2
    mrs x24, nzcv
    adcs x25, x1, x15
    mrs x25, nzcv
    sbcs w26, w3, w28
    mrs x26, nzcv
    ands x27, x0, x1
    mrs x27, nzcv
    tst w4, #0xff
    mrs x29, nzcv
    bics x30, x5, x28
    mrs x30, nzcv
    negs x9, x2
    mrs x9, nzcv
    adds x10, x0, x1        // dead: the SUBS sets them again first
    subs x10, x2, x3
    mrs x10, nzcv
    movz x8, #0x6c00, lsl #16
    msr nzcv, x8            // Z, C, AF, PF
    mrs x11, nzcv
    adds x12, x0, x1
    cfinv                   // CFINV, SETF8, RMIF keep PF and AF
    setf8 w2
    rmif x3, #0, #2
    mrs x12, nzcv
    movz x8, #0x7ff8, lsl #48
    fmov d16, x8
    fmov d17, #1.0
    movz x8, #0x0800, lsl #16
    msr nzcv, x8            // AF set (a POPF), then Rosetta's UCOMISD: PF unordered, AF clear
    fcmp d16, d17
    axflag
    mrs x13, nzcv
    adds x14, x0, x1
    fcmp d17, d17           // FCMP alone keeps them
    mrs x14, nzcv
    adds w16, w0, #0x10
    mrs x16, nzcv
    adds x17, x6, x6, lsr #3
    mrs x17, nzcv
END apf_cases

// MRS and MSR with registers that live in the HvCpu, and an ADDS writing one.
PROGRAM apf_stolen
    movz x8, #0x0800, lsl #16
    msr nzcv, x8            // AF alone
    mrs x6, nzcv
    adds x7, x0, x1
    mrs x15, nzcv
    msr nzcv, x28
    mrs x9, nzcv
    subs x28, x28, x3       // Rd = Rn, in the HvCpu
    mrs x10, nzcv
    fmov d17, #1.0
    fcmp d17, d17           // ordered: PF and AF clear
    axflag
    mrs x11, nzcv
END apf_stolen

// Through branches: the flags are read on one way only, or set again both ways before they are read.
PROGRAM apf_branch
    adds x19, x0, x1
    cbz x2, 1f
    subs x20, x2, x3
    mrs x20, nzcv
    b 2f
1:  mrs x20, nzcv           // x2 == 0: the ADDS's
2:  adds x21, x4, x5        // set again both ways below
    tbz w4, #0, 3f
    subs x22, x0, x2
    b 4f
3:  ands x22, x1, x3
4:  mrs x22, nzcv
    adds x23, x0, x3        // read after a loop that does not set them
    mov x24, #3
5:  sub x24, x24, #1
    cbnz x24, 5b
    mrs x23, nzcv
END apf_branch

_apf_programs_finish:
