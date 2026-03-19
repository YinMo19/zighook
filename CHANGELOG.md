# Changelog

## v0.3.0

Released: 2026-03-20

Highlights:

- Added the initial public x86_64 hook backend for macOS and Linux, including entry hooks, trap-based instruction hooks, and execute-original replay through out-of-line trampolines.
- Added Zydis-backed x86_64 instruction decoding and relocation metadata handling for replayable direct calls, indirect calls, direct jumps, indirect jumps, conditional branches, and RIP-relative memory operands.
- Added x86_64 callback-visible FP register access, including indexed and named `xmm0..xmm15` views plus `mxcsr`.
- Added Linux x86_64 runtime smoke coverage in CI and expanded integration coverage for execute-original replay, including direct-call and stack-pointer indirect-call paths.
- Moved the Zydis bridge into the standalone `hookforge/zydis-zig` Zig package and removed the vendored third-party C payload from `zighook` history.

## v0.2.0

Released: 2026-03-19

Highlights:

- Added strict AArch64 execute-original replay support for common PC-relative instructions, including `adr`, `adrp`, literal `ldr*`, `b`, `bl`, `b.cond`, `cbz/cbnz`, and `tbz/tbnz`.
- Added callback-visible AArch64 FP/SIMD register access, including indexed and named `v0..v31` views plus `fpsr` and `fpcr`.
- Refactored AArch64 replay decoding around packed bitfield layouts and `@bitCast`, so instruction parsers map directly onto the in-memory opcode layout.
- Split platform-specific AArch64 context backends into dedicated backend modules for Darwin and Linux-family systems, covering macOS, iOS, Linux, and Android backend targets.
- Restructured examples into standalone mini-projects with per-example documentation and exact expected outputs.
- Added Linux AArch64 runtime smoke coverage in CI alongside the existing macOS runtime smoke coverage.

## v0.1.0

Initial public release.
