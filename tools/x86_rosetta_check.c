/* Rosetta 2 check: what x86_64 code computes, for comparing a Mac's own Rosetta with the one in a Henge guest.
   Build on the Mac: clang -arch x86_64 -O1 -o x86_rosetta_check x86_rosetta_check.c
   Run both, diff the output. Every line but the TSO one must match; "bad" there must be 0.

   The flag table runs each x86 instruction from the binary (Rosetta's ahead-of-time translation, when oahd made
   one) and from a copy in writable memory (its JIT), on 24 x 24 inputs and two starting flag states, and prints
   a hash of the RFLAGS bits CF PF AF ZF SF OF it leaves. PF and AF come from Apple's x86 flag extension (NZCV bits
   26 and 27), so they show whether the CPU (or Henge) computes them as the Mac does. */
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
volatile double a = 1.0, b = NAN, c = 2.0;
static volatile int flag, data;
static int mp_n;
static void *producer(void *x) { (void)x; for (int i = 1; i <= mp_n; i++) { data = i; __atomic_store_n(&flag, i, __ATOMIC_RELAXED); while (__atomic_load_n(&flag, __ATOMIC_RELAXED) == i) ; } return 0; }

/* One x86 instruction between a POPF of the starting flags (rdx) and a PUSHF: rdi, rsi are the operands
   (xmm0, xmm1 their bits, for the float compares); returns RFLAGS. Position independent, so they can be copied. */
#define OP(name, body) \
    __asm__(".text\n.p2align 4\n.globl _op_" #name "\n_op_" #name ":\n" \
            "  movq %rdi, %xmm0\n  movq %rsi, %xmm1\n  movq %rdi, %rax\n  movq %rsi, %rcx\n" \
            "  pushq %rdx\n  popfq\n" body "\n  pushfq\n  popq %rax\n  ret\n" \
            ".globl _op_" #name "_end\n_op_" #name "_end:\n  nop\n");
#define OPS(X) \
    X(add8, "addb %cl, %al") X(add16, "addw %cx, %ax") X(add32, "addl %ecx, %eax") X(add64, "addq %rcx, %rax") \
    X(addimm, "addl $0x1f, %eax") X(sub8, "subb %cl, %al") X(sub16, "subw %cx, %ax") X(sub32, "subl %ecx, %eax") \
    X(sub64, "subq %rcx, %rax") X(cmp8, "cmpb %cl, %al") X(cmp32, "cmpl %ecx, %eax") X(cmp64imm, "cmpq $0x1234, %rax") \
    X(adc8, "adcb %cl, %al") X(adc32, "adcl %ecx, %eax") X(sbb16, "sbbw %cx, %ax") X(sbb64, "sbbq %rcx, %rax") \
    X(neg8, "negb %al") X(neg32, "negl %eax") X(inc8, "incb %al") X(inc32, "incl %eax") X(dec16, "decw %ax") \
    X(dec64, "decq %rax") X(and8, "andb %cl, %al") X(and32, "andl %ecx, %eax") X(or16, "orw %cx, %ax") \
    X(xor64, "xorq %rcx, %rax") X(test8, "testb %cl, %al") X(test32, "testl %ecx, %eax") X(andimm, "andb $0x3c, %al") \
    X(shl32, "shll $3, %eax") X(shr8, "shrb $1, %al") X(sar32, "sarl $5, %eax") X(shlcl, "shll %cl, %eax") \
    X(rol32, "roll $1, %eax") X(ror8, "rorb $1, %al") X(rcl32, "rcll $1, %eax") X(shld, "shldl $4, %ecx, %eax") \
    X(imul32, "imull %ecx, %eax") X(mul64, "mulq %rcx") X(bt32, "btl %ecx, %eax") X(bts64, "btsq $3, %rax") \
    X(bsf32, "bsfl %ecx, %eax") X(popcnt, "popcntl %ecx, %eax") X(tzcnt, "tzcntl %ecx, %eax") \
    X(xadd32, "xaddl %eax, %ecx") X(cmpxchg, "cmpxchgl %ecx, %edx") X(sahf, "shll $8, %eax\n  sahf") \
    X(ucomisd, "ucomisd %xmm1, %xmm0") X(comisd, "comisd %xmm1, %xmm0") X(ucomiss, "ucomiss %xmm1, %xmm0")
#define DEFINE(name, body) OP(name, body)
OPS(DEFINE)
#define DECL(name, body) extern char op_##name[], op_##name##_end[];
OPS(DECL)
#define ENTRY(name, body) {#name, op_##name, op_##name##_end},
static const struct { const char *name; char *start, *end; } ops[] = {OPS(ENTRY)};
typedef uint64_t (*op_fn)(uint64_t, uint64_t, uint64_t);

static int verbose; /* -v NAME: every result of that instruction instead of the hash */

static uint64_t flags_hash(op_fn f, int is_float) {
    static const uint64_t in[] = {0, 1, 3, 0xf, 0x10, 0x1f, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xffff, 0x7fffffff,
                                  0x80000000, 0xffffffff, 0x123456789abcdef0, 0x8000000000000000, 0xffffffffffffffff,
                                  0xd7, 0x2d5, 0x3c3c, 0xfffffff0, 0x1234};
    static const uint64_t fin[] = {0, 0x8000000000000000, 0x3ff0000000000000, 0x4000000000000000, 0xbff0000000000000,
                                   0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff0000000000001,
                                   0xfff8000000000000, 1, 0x3f8000003fc00000, 0x7fc000007f800000, 0x40000000ffc00000};
    const uint64_t *v = is_float ? fin : in;
    int n = is_float ? (int)(sizeof fin / sizeof *fin) : (int)(sizeof in / sizeof *in);
    uint64_t h = 0xcbf29ce484222325ull;
    for (int s = 0; s < 2; s++)
        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++) {
                uint64_t r = f(v[i], v[j], s ? 0x8d7 : 0x2) & 0x8d5; /* CF PF AF ZF SF OF */
                h = (h ^ r) * 0x100000001b3ull;
                if (verbose) printf("  %d %016llx %016llx -> %03llx\n", s, (unsigned long long)v[i], (unsigned long long)v[j], (unsigned long long)r);
            }
    return h;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc > 2 && !strcmp(argv[1], "-v")) { /* x86_rosetta_check -v ucomisd: its results one by one, then its JIT copy's */
        verbose = 1;
        for (size_t i = 0; i < sizeof ops / sizeof *ops; i++) {
            if (strcmp(ops[i].name, argv[2])) continue;
            int fl_op = strstr(ops[i].name, "comis") != NULL;
            printf("%s:\n", ops[i].name);
            flags_hash((op_fn)ops[i].start, fl_op);
            size_t len = (size_t)(ops[i].end - ops[i].start) + 1;
            char *jit = mmap(0, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
            if (jit != MAP_FAILED) {
                memcpy(jit, ops[i].start, len);
                printf("%s (JIT):\n", ops[i].name);
                flags_hash((op_fn)jit, fl_op);
            }
        }
        return 0;
    }
    int mp = argc > 1 ? atoi(argv[1]) : 200000;
    printf("nan: lt=%d eq=%d ne=%d isnan=%d; num: lt=%d gt=%d\n", a < b, a == b, a != b, isnan(b), a < c, a > c);
    unsigned char p1, p2, ah, cf;
    unsigned x = 3, y = 1;
    __asm__ volatile("addl $0, %1; setp %0" : "=r"(p1) : "r"(x));
    __asm__ volatile("addl $0, %1; setp %0" : "=r"(p2) : "r"(y));
    printf("parity: 3->%d 1->%d\n", p1, p2);
    __asm__ volatile("movb $0x0f, %%al; addb $1, %%al; lahf; movb %%ah, %0" : "=Q"(ah)::"eax");
    printf("AF after 0x0f+1: %d\n", (ah >> 4) & 1);

    /* NaN checks the way compilers write them: UCOMISD/COMISD and the parity flag. */
    double nan = b, one = a, two = c;
    unsigned char un, co, ord, nanself;
    int jp;
    __asm__ volatile("ucomisd %2, %1; setp %0" : "=r"(un) : "x"(nan), "x"(one));
    __asm__ volatile("comisd %2, %1; setp %0" : "=r"(co) : "x"(one), "x"(nan));
    __asm__ volatile("ucomisd %2, %1; setp %0" : "=r"(ord) : "x"(one), "x"(two));
    __asm__ volatile("ucomisd %1, %1; setp %0" : "=r"(nanself) : "x"(nan));
    __asm__ volatile("xorl %0, %0; ucomisd %2, %1; jnp 1f; movl $1, %0; 1:" : "=&r"(jp) : "x"(nan), "x"(nan));
    __asm__ volatile("ucomisd %2, %1; lahf; movb %%ah, %0" : "=Q"(ah) : "x"(nan), "x"(one) : "eax");
    printf("float compare: ucomisd(nan,1) PF=%d comisd(1,nan) PF=%d ucomisd(1,2) PF=%d isnan(nan) PF=%d jp(nan)=%d lahf(nan)=%02x\n",
           un, co, ord, nanself, jp, ah & 0xd5);
    volatile double vals[] = {1.0, NAN, -0.0, INFINITY};
    int nans = 0;
    for (int i = 0; i < 4; i++) nans += isnan(vals[i]) ? 1 << i : 0;
    printf("isnan of 1, nan, -0, inf: %x\n", nans);
    unsigned long long fl;
    __asm__ volatile("movb $0x0f, %%al; addb $1, %%al; pushfq; popq %0" : "=r"(fl)::"eax");
    printf("pushf after 0x0f+1: %03llx\n", fl & 0x8d5);
    __asm__ volatile("xorl %%eax, %%eax; cmpl $3, %%eax; pushfq; popq %0" : "=r"(fl)::"eax");
    printf("pushf after cmp 0,3: %03llx\n", fl & 0x8d5);
    int parity_jumps = 0;
    for (unsigned k = 0; k < 256; k++) {
        int t;
        __asm__ volatile("xorl %0, %0; cmpl $0, %1; jnp 1f; movl $1, %0; 1:" : "=&r"(t) : "r"(k));
        parity_jumps += t;
    }
    printf("jp after cmp k,0 for k < 256: %d taken\n", parity_jumps);

    volatile float f = 1.5f, g = 2.25f, tiny = 1e-40f;
    printf("sse: %.4f %.4f %.4f denorm %g\n", f * g, f / g, sqrtf(g), tiny * 1.0f);
    double s = 0;
    for (int i = 1; i <= 1000000; i++) s += 1.0 / i;
    printf("harmonic: %.10f\n", s);
    unsigned long long u = 5, v = 7;
    __asm__ volatile("subq %2, %1; setc %0" : "=r"(cf), "+r"(u) : "r"(v));
    printf("borrow: %d\n", cf);

    /* The flag table, ahead-of-time code and JIT code. */
    size_t nops = sizeof ops / sizeof *ops, total = 0;
    for (size_t i = 0; i < nops; i++) total += (size_t)(ops[i].end - ops[i].start) + 64;
    char *jit = mmap(0, total + 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (jit == MAP_FAILED) jit = NULL;
    size_t off = 0;
    int jit_diff = 0;
    for (size_t i = 0; i < nops; i++) {
        int fl_op = strstr(ops[i].name, "comis") != NULL;
        uint64_t h = flags_hash((op_fn)ops[i].start, fl_op), hj = h;
        if (jit) {
            size_t len = (size_t)(ops[i].end - ops[i].start) + 1;
            memcpy(jit + off, ops[i].start, len);
            hj = flags_hash((op_fn)(jit + off), fl_op);
            off = (off + len + 63) & ~(size_t)63;
        }
        printf("flags %-8s %016llx%s\n", ops[i].name, (unsigned long long)h, hj == h ? "" : " JIT DIFFERS");
        jit_diff += hj != h;
    }
    printf("flags: %zu instructions, JIT %s\n", nops, !jit ? "not run" : jit_diff ? "differs" : "same");

    mp_n = mp;
    pthread_t t; pthread_create(&t, 0, producer, 0);
    int bad = 0;
    for (int i = 1; i <= mp; i++) { while (__atomic_load_n(&flag, __ATOMIC_RELAXED) != i) continue; if (data != i) bad++; __atomic_store_n(&flag, -i, __ATOMIC_RELAXED); }
    pthread_join(t, 0);
    printf("tso message passing: %d bad of %d\n", bad, mp);
    return 0;
}
