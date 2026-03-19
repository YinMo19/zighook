const builtin = @import("builtin");
const zighook = @import("zighook");

const init_section = switch (builtin.os.tag) {
    .macos, .ios => "__DATA,__mod_init_func",
    .linux => ".init_array",
    else => @compileError("example payload constructors are only implemented for Mach-O and ELF targets."),
};

extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

fn rtldDefault() ?*anyopaque {
    return switch (builtin.os.tag) {
        .macos, .ios => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
        .linux => null,
        else => @compileError("RTLD_DEFAULT is only implemented for Mach-O and ELF targets."),
    };
}

var patchpoint_addr: u64 = 0;

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    switch (builtin.cpu.arch) {
        .aarch64 => ctx.regs.named.x0 = 123,
        .x86_64 => ctx.regs.named.rax = 123,
        else => @compileError("example payload only supports AArch64 and x86_64"),
    }
}

fn install() callconv(.c) void {
    const symbol = dlsym(rtldDefault(), "target_add_patchpoint");
    if (symbol == null) return;

    patchpoint_addr = @intFromPtr(symbol.?);
    _ = zighook.instrument_no_original(patchpoint_addr, onHit) catch {};
}

pub export fn zighook_example_unhook() callconv(.c) void {
    if (patchpoint_addr == 0) return;
    zighook.unhook(patchpoint_addr) catch {};
}

const InitFn = *const fn () callconv(.c) void;
pub export const example_init: InitFn linksection(init_section) = &install;
