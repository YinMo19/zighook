#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif

.text
.p2align 4

// Demo add target used by instruction-level replay tests.
.globl SYM(demo_add_target)
.globl SYM(demo_add_patchpoint)
SYM(demo_add_target):
SYM(demo_add_patchpoint):
    leal (%rdi,%rsi), %eax
    ret

// Simple prepatched entry-hook target for x86_64 tests. The first byte is
// already `int3`, so `prepatched.inline_hook(...)` only needs to register
// runtime dispatch state.
.globl SYM(demo_prepatched_target)
SYM(demo_prepatched_target):
    int3
    ret
