# instrument_with_original

This example traps one instruction and then replays it with edited registers by
using `zighook.instrument(...)`.

The callback rewrites the integer argument registers before the trapped add
instruction executes, so the final program result becomes `42`.

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
(cd ../.. && zig build --fetch)
ZYDIS_BRIDGE_C="$(../../scripts/zydis-package-path.sh bridge-c)"

zig build-lib -dynamic -OReleaseFast -femit-bin=hook.so \
  "$ZYDIS_BRIDGE_C" \
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
result=42
```
