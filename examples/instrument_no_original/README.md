# instrument_no_original

This example traps one instruction and replaces its result in the callback with
`zighook.instrument_no_original(...)`.

The C target exposes a symbol named `target_add_patchpoint` that points at the
single add instruction. The hook library resolves that symbol and forces the
result to `99` without replaying the original instruction.

## Build

macOS / AArch64:

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

```bash
zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

Linux x86_64:

```bash
cc -O3 -DNDEBUG -rdynamic -o target target.c -ldl
```

```bash
zig build-lib -dynamic -OReleaseFast -femit-bin=hook.so \
  ../../c_deps/x86_64/decoder_zydis.c \
  -I ../../c_deps/zydis \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

## Run

```bash
DYLD_INSERT_LIBRARIES=$PWD/hook.dylib ./target
```

Linux x86_64:

```bash
LD_PRELOAD=$PWD/hook.so ./target
```

## Expected Output

```text
result=99
```
