const builtin = @import("builtin");
const std = @import("std");
const zighook = @import("zighook");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_inline_hook_smoke only supports Windows targets");
    }
    switch (builtin.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => @compileError("windows_inline_hook_smoke only supports x86_64 and AArch64"),
    }
}

fn setReturnValue(ctx: *zighook.HookContext, value: u64) void {
    switch (builtin.cpu.arch) {
        .x86_64 => ctx.regs.named.rax = value,
        .aarch64 => ctx.regs.named.x0 = value,
        else => unreachable,
    }
}

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    setReturnValue(ctx, 42);
}

pub export fn zighook_example_install() callconv(.c) void {
    const main_module = kernel32.GetModuleHandleW(null) orelse return;
    const symbol = kernel32.GetProcAddress(main_module, "target_add") orelse return;
    _ = zighook.inline_hook(@intFromPtr(symbol), onHit) catch {};
}
