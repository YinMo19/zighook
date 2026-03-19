//! Original-instruction trampoline support for x86_64.
//!
//! The x86_64 backend replays displaced instructions out of line. Zydis tells
//! us how large the instruction is and where any relative branch or RIP-relative
//! fields live, and this file performs the final relocation into a tiny RX
//! trampoline.

const std = @import("std");

const constants = @import("constants.zig");
const decoder = @import("decoder.zig");
const HookError = @import("../../error.zig").HookError;
const memory = @import("../../memory.zig");

const TrampolineEmitter = struct {
    mapped: []align(std.heap.page_size_min) u8,
    base_pc: u64,
    offset: usize = 0,

    fn currentPc(self: *const TrampolineEmitter) u64 {
        return self.base_pc + self.offset;
    }

    fn emit(self: *TrampolineEmitter, bytes: []const u8) HookError!void {
        if (self.offset + bytes.len > self.mapped.len) return error.TrampolineAllocationFailed;
        @memcpy(self.mapped[self.offset .. self.offset + bytes.len], bytes);
        self.offset += bytes.len;
    }

    fn emitAbsoluteJump(self: *TrampolineEmitter, target: u64) HookError!void {
        // `jmp qword ptr [rip+0]` followed by an inline 64-bit literal.
        // This stays position-independent and always occupies 14 bytes.
        const opcode = [_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 };
        const literal = std.mem.toBytes(std.mem.nativeToLittle(u64, target));
        try self.emit(opcode[0..]);
        try self.emit(literal[0..]);
    }

    fn emitAbsolutePush(self: *TrampolineEmitter, value: u64) HookError!void {
        // `push qword ptr [rip+0]` followed by an inline literal. This is used
        // to synthesize the architectural "return address push" side effect of
        // a displaced `call`.
        const opcode = [_]u8{ 0xFF, 0x35, 0x00, 0x00, 0x00, 0x00 };
        const literal = std.mem.toBytes(std.mem.nativeToLittle(u64, value));
        try self.emit(opcode[0..]);
        try self.emit(literal[0..]);
    }
};

fn writeRelativeOffset(bytes: []u8, offset: usize, size: u8, value: i64) HookError!void {
    switch (size) {
        1 => {
            if (value < std.math.minInt(i8) or value > std.math.maxInt(i8)) {
                return error.ReplayUnsupported;
            }
            bytes[offset] = @bitCast(@as(i8, @intCast(value)));
        },
        4 => {
            if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
                return error.ReplayUnsupported;
            }
            const int_bytes: *[4]u8 = @ptrCast(bytes[offset .. offset + 4]);
            std.mem.writeInt(i32, int_bytes, @intCast(value), .little);
        },
        // The replay machinery only supports the relative sizes emitted by the
        // currently accepted control-flow instructions.
        else => return error.ReplayUnsupported,
    }
}

fn patchRelativeImmediate(
    bytes: []u8,
    decoded: decoder.DecodedInstruction,
    instruction_pc: u64,
    target: u64,
) HookError!void {
    const next_pc = @as(i128, @intCast(instruction_pc + decoded.length));
    const displacement = @as(i128, @intCast(target)) - next_pc;
    try writeRelativeOffset(bytes, decoded.imm_offset, decoded.imm_size, @intCast(displacement));
}

fn patchRipRelativeDisplacement(
    bytes: []u8,
    decoded: decoder.DecodedInstruction,
    instruction_pc: u64,
) HookError!void {
    if (!decoded.hasRipRelativeMemory()) return;

    // Zydis gives the original absolute target; the trampoline needs the new
    // displacement that reaches the same target from the relocated instruction.
    const next_pc = @as(i128, @intCast(instruction_pc + decoded.length));
    const displacement = @as(i128, @intCast(decoded.absolute_target)) - next_pc;
    try writeRelativeOffset(bytes, decoded.disp_offset, decoded.disp_size, @intCast(displacement));
}

fn rewriteIndirectCallToJump(bytes: []u8, decoded: decoder.DecodedInstruction) HookError!void {
    if (decoded.modrm_offset == 0 or decoded.modrm_offset >= bytes.len) {
        return error.ReplayUnsupported;
    }
    // The trampoline explicitly pushes the synthetic return address first, so
    // the copied instruction must become a `jmp r/m64` instead of `call r/m64`
    // to avoid pushing twice.
    bytes[decoded.modrm_offset] = (bytes[decoded.modrm_offset] & 0xC7) | 0x20;
}

fn copyInstruction(original_bytes: []const u8, step_len: u8) HookError![16]u8 {
    const len = @as(usize, step_len);
    if (original_bytes.len != len or original_bytes.len == 0 or original_bytes.len > 16) {
        return error.InvalidAddress;
    }

    var bytes = [_]u8{0} ** 16;
    @memcpy(bytes[0..original_bytes.len], original_bytes);
    return bytes;
}

pub fn createOriginalTrampoline(address: u64, original_bytes: []const u8, step_len: u8) HookError!u64 {
    const decoded = try decoder.decodeInstruction(address, original_bytes);
    if (decoded.length != step_len) return error.InvalidAddress;

    const page_size = std.heap.pageSize();
    const page_mask = @as(u64, @intCast(page_size - 1));
    const hint_addr = address & ~page_mask;
    const hint: ?[*]align(std.heap.page_size_min) u8 = @ptrFromInt(@as(usize, @intCast(hint_addr)));
    const mapped = std.posix.mmap(
        hint,
        page_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        },
        -1,
        0,
    ) catch return error.TrampolineAllocationFailed;
    errdefer std.posix.munmap(mapped);

    var emitter = TrampolineEmitter{
        .mapped = mapped,
        .base_pc = @intFromPtr(mapped.ptr),
    };
    const next_pc = address + step_len;

    switch (decoded.control) {
        .plain => {
            // Fallthrough instruction: replay the bytes, repair RIP-relative
            // addressing if needed, then jump back to the original next PC.
            var bytes = try copyInstruction(original_bytes, step_len);
            try patchRipRelativeDisplacement(bytes[0..@as(usize, step_len)], decoded, emitter.currentPc());
            try emitter.emit(bytes[0..@as(usize, step_len)]);
            if (decoded.hasFallthrough()) {
                try emitter.emitAbsoluteJump(next_pc);
            }
        },
        .direct_call => {
            // Preserve call semantics without using a relative encoding that
            // depends on trampoline placement.
            try emitter.emitAbsolutePush(next_pc);
            try emitter.emitAbsoluteJump(decoded.absolute_target);
        },
        .indirect_call => {
            if (decoded.usesStackPointerMemory()) return error.ReplayUnsupported;

            try emitter.emitAbsolutePush(next_pc);
            var bytes = try copyInstruction(original_bytes, step_len);
            try rewriteIndirectCallToJump(bytes[0..@as(usize, step_len)], decoded);
            try patchRipRelativeDisplacement(bytes[0..@as(usize, step_len)], decoded, emitter.currentPc());
            try emitter.emit(bytes[0..@as(usize, step_len)]);
        },
        .direct_jump => {
            try emitter.emitAbsoluteJump(decoded.absolute_target);
        },
        .indirect_jump => {
            // Indirect jumps already describe the final target in registers or
            // memory, so replay is mostly "copy bytes and fix RIP-relative
            // memory if present".
            var bytes = try copyInstruction(original_bytes, step_len);
            try patchRipRelativeDisplacement(bytes[0..@as(usize, step_len)], decoded, emitter.currentPc());
            try emitter.emit(bytes[0..@as(usize, step_len)]);
        },
        .conditional_branch => {
            // Shape:
            //   jcc taken_stub
            //   jmp next_pc
            // taken_stub:
            //   jmp original_target
            var bytes = try copyInstruction(original_bytes, step_len);
            const branch_pc = emitter.currentPc();
            const taken_pc = branch_pc + step_len + 14;
            try patchRelativeImmediate(bytes[0..@as(usize, step_len)], decoded, branch_pc, taken_pc);
            try emitter.emit(bytes[0..@as(usize, step_len)]);
            try emitter.emitAbsoluteJump(next_pc);
            try emitter.emitAbsoluteJump(decoded.absolute_target);
        },
        .ret => {
            // `ret` is already self-contained. Replaying it directly from the
            // trampoline preserves the original control transfer.
            try emitter.emit(original_bytes);
        },
        .unsupported => return error.ReplayUnsupported,
    }

    // Complete all writes before RX protection is restored.
    memory.flushInstructionCache(mapped.ptr, emitter.offset);

    std.posix.mprotect(mapped, std.posix.PROT.READ | std.posix.PROT.EXEC) catch {
        return error.TrampolineProtectFailed;
    };

    return @intFromPtr(mapped.ptr);
}

pub fn freeOriginalTrampoline(trampoline_pc: u64) void {
    if (trampoline_pc == 0) return;

    const page_size = std.heap.pageSize();
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(@as(usize, @intCast(trampoline_pc)));
    std.posix.munmap(ptr[0..page_size]);
}
