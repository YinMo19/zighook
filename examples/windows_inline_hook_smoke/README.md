# windows_inline_hook_smoke

This example is the minimal native Windows runtime smoke for `zighook`.

Unlike the Mach-O / ELF examples, Windows does not use `DYLD_INSERT_LIBRARIES`
or `LD_PRELOAD`. Instead, the target process loads `hook.dll` explicitly with
`LoadLibraryA`, resolves the exported `zighook_example_install` function, and
lets that function install `zighook.inline_hook(...)` on the exported
`target_add` symbol.

The example is intentionally simple so it validates the essential Windows path:

- executable page patching through `VirtualProtect`
- trap delivery through a vectored exception handler (VEH)
- `CONTEXT` remapping into `zighook.HookContext`
- `inline_hook(...)` return-to-caller behavior

## Build

Build the C target in release mode:

```bash
zig cc -O3 -DNDEBUG -o target.exe target.c
```

Build the Zig hook DLL in release mode:

```bash
(cd ../.. && zig build --fetch)
ZYDIS_BRIDGE_C="$(../../scripts/zydis-package-path.sh bridge-c)"

zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dll \
  "$ZYDIS_BRIDGE_C" \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

## Run

```bash
./target.exe
```

## Expected Output

```text
result=42
```
