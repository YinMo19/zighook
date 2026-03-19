# instrument_unhook_restore

This example shows that `zighook.unhook(...)` restores the original code bytes
for a runtime-installed trap hook.

The hook library installs `instrument_no_original(...)` on a single `add`
instruction and exports a helper named `zighook_example_unhook`. The target
program calls the target function once while hooked, resolves that helper with
`dlsym`, invokes it, and calls the target again after restoration.

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
hooked=123
restored=5
```
