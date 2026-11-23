// The same trap sequences as Henge's ios/Henge/Native/henge-brk.S.
.section __TEXT,__text,regular,pure_instructions
.globl _probe_brk_get_jit_mapping
.p2align 2
_probe_brk_get_jit_mapping:
    mov x16, #1
    brk #0xf00d
    ret
.globl _probe_brk_jit_detach
.p2align 2
_probe_brk_jit_detach:
    mov x16, #0
    brk #0xf00d
    ret
.globl _probe_brk_probe
.p2align 2
_probe_brk_probe:
    brk #0x69
    ret
