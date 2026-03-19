# prepatched_inline_hook

This example demonstrates `zighook.prepatched.inline_hook(...)`.

The C target already contains a trap instruction at the function entry:

- `brk #0` on AArch64
- `int3` on x86_64

The hook library only needs to register runtime state for that address. The
callback returns a synthetic value directly to the caller.

This is also the recommended template for the iOS deployment model:

- prepatch the target Mach-O offline
- build the payload as a dylib
- insert that dylib into the app bundle
- re-sign and install the app

## Build

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

Linux x86_64 CI uses the corresponding native ELF build:

```bash
cc -O3 -DNDEBUG -rdynamic -o target target.c -ldl
```

```bash
zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

Linux x86_64 fetches the pinned `zydis-zig` package and compiles its bridge C
source as well:

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
result=77
```
