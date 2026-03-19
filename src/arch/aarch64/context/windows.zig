//! Windows AArch64 exception-context remapping.
//!
//! Windows ARM64 exposes breakpoint state through the native `CONTEXT` record.
//! This module copies that record into zighook's stable callback-facing
//! `HookContext` layout and writes callback edits back into the Windows record
//! before execution resumes.

const std = @import("std");

const types = @import("types.zig");

const windows = std.os.windows;

fn readU128(bytes: []const u8) u128 {
    return std.mem.readInt(u128, bytes[0..16], .little);
}

fn writeU128(bytes: []u8, value: u128) void {
    std.mem.writeInt(u128, bytes[0..16], value, .little);
}

fn captureFromContext(context: *const windows.CONTEXT) types.HookContext {
    var ctx = std.mem.zeroes(types.HookContext);

    for (context.DUMMYUNIONNAME.X, 0..) |reg, index| {
        ctx.regs.x[index] = reg;
    }
    ctx.sp = context.Sp;
    ctx.pc = context.Pc;
    ctx.cpsr = context.Cpsr;
    ctx.pad = 0;

    for (context.V, 0..) |vreg, index| {
        ctx.fpregs.v[index] = readU128(std.mem.asBytes(&vreg));
    }
    ctx.fpsr = context.Fpsr;
    ctx.fpcr = context.Fpcr;

    return ctx;
}

fn writeBackToContext(context: *windows.CONTEXT, ctx: *const types.HookContext) void {
    for (ctx.regs.x, 0..) |reg, index| {
        context.DUMMYUNIONNAME.X[index] = reg;
    }
    context.Sp = ctx.sp;
    context.Pc = ctx.pc;
    context.Cpsr = ctx.cpsr;

    for (ctx.fpregs.v, 0..) |vreg, index| {
        writeU128(std.mem.asBytes(&context.V[index]), vreg);
    }
    context.Fpsr = ctx.fpsr;
    context.Fpcr = ctx.fpcr;
}

pub fn captureMachineContext(context_opaque: ?*anyopaque) ?types.HookContext {
    if (context_opaque == null) return null;

    const context: *align(1) const windows.CONTEXT = @ptrCast(context_opaque.?);
    return captureFromContext(@alignCast(context));
}

pub fn writeBackMachineContext(context_opaque: ?*anyopaque, ctx: *const types.HookContext) bool {
    if (context_opaque == null) return false;

    const context: *align(1) windows.CONTEXT = @ptrCast(context_opaque.?);
    writeBackToContext(@alignCast(context), ctx);
    return true;
}

comptime {
    std.debug.assert(@sizeOf(windows.NEON128) == 16);
}
