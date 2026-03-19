//! Windows x86_64 exception-context remapping.
//!
//! Windows delivers breakpoint traps through a native `CONTEXT` record rather
//! than a Unix `ucontext_t`. This module copies that record into zighook's
//! stable public `HookContext` layout and writes it back after callback
//! dispatch completes.

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

    ctx.regs.named.rax = context.Rax;
    ctx.regs.named.rbx = context.Rbx;
    ctx.regs.named.rcx = context.Rcx;
    ctx.regs.named.rdx = context.Rdx;
    ctx.regs.named.rdi = context.Rdi;
    ctx.regs.named.rsi = context.Rsi;
    ctx.regs.named.rbp = context.Rbp;
    ctx.regs.named.r8 = context.R8;
    ctx.regs.named.r9 = context.R9;
    ctx.regs.named.r10 = context.R10;
    ctx.regs.named.r11 = context.R11;
    ctx.regs.named.r12 = context.R12;
    ctx.regs.named.r13 = context.R13;
    ctx.regs.named.r14 = context.R14;
    ctx.regs.named.r15 = context.R15;
    ctx.sp = context.Rsp;

    // Windows reports `Rip` at the one-byte `int3` instruction itself, while
    // the existing x86_64 backend normalizes from the Unix-style post-trap PC
    // convention. Store `pc = Rip + 1` here so the architecture-level
    // `trapAddress(...)` logic can stay ISA-centric and shared across platforms.
    ctx.pc = context.Rip + 1;
    ctx.flags = context.EFlags;
    ctx.cs = context.SegCs;
    ctx.gs = context.SegGs;
    ctx.fs = context.SegFs;
    ctx.ss = context.SegSs;

    const float_state = &context.DUMMYUNIONNAME.FltSave;
    for (float_state.XmmRegisters, 0..) |xmm, index| {
        ctx.fpregs.xmm[index] = readU128(std.mem.asBytes(&xmm));
    }
    ctx.mxcsr = context.MxCsr;

    return ctx;
}

fn writeBackToContext(context: *windows.CONTEXT, ctx: *const types.HookContext) void {
    context.Rax = ctx.regs.named.rax;
    context.Rbx = ctx.regs.named.rbx;
    context.Rcx = ctx.regs.named.rcx;
    context.Rdx = ctx.regs.named.rdx;
    context.Rdi = ctx.regs.named.rdi;
    context.Rsi = ctx.regs.named.rsi;
    context.Rbp = ctx.regs.named.rbp;
    context.R8 = ctx.regs.named.r8;
    context.R9 = ctx.regs.named.r9;
    context.R10 = ctx.regs.named.r10;
    context.R11 = ctx.regs.named.r11;
    context.R12 = ctx.regs.named.r12;
    context.R13 = ctx.regs.named.r13;
    context.R14 = ctx.regs.named.r14;
    context.R15 = ctx.regs.named.r15;
    context.Rsp = ctx.sp;
    context.Rip = ctx.pc;
    context.EFlags = @truncate(ctx.flags);
    context.SegCs = @truncate(ctx.cs);
    context.SegGs = @truncate(ctx.gs);
    context.SegFs = @truncate(ctx.fs);
    context.SegSs = @truncate(ctx.ss);

    var float_state = &context.DUMMYUNIONNAME.FltSave;
    for (ctx.fpregs.xmm, 0..) |xmm, index| {
        writeU128(std.mem.asBytes(&float_state.XmmRegisters[index]), xmm);
    }
    context.MxCsr = ctx.mxcsr;
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
    std.debug.assert(@sizeOf(windows.M128A) == 16);
}
