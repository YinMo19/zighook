//! Thin x86_64 instruction decoder wrapper backed by Zydis.
//!
//! The public hook API stays architecture-neutral. This module translates the
//! richer Zydis decode result into the minimal relocation metadata that the
//! x86_64 backend needs:
//! - instruction length
//! - whether the instruction is a direct/indirect branch or return
//! - where relative immediates or RIP-relative displacements live in the byte stream
//! - which absolute address those relative fields refer to at the original PC
//!
//! The backend intentionally does not expose raw Zydis types. This wrapper
//! keeps the dependency boundary private and reduces the rest of the runtime to
//! the handful of facts needed for trap patching and trampoline relocation.

const HookError = @import("../../error.zig").HookError;

const CDecodedInstruction = extern struct {
    length: u8,
    control: u8,
    flags: u8,
    imm_offset: u8,
    imm_size: u8,
    disp_offset: u8,
    disp_size: u8,
    modrm_offset: u8,
    mem_base: u8,
    mem_index: u8,
    mem_scale: u8,
    mem_disp: i32,
    absolute_target: u64,
};

extern fn zighook_x86_decode(
    buffer: [*]const u8,
    length: usize,
    runtime_address: u64,
    out: *CDecodedInstruction,
) callconv(.c) c_int;

pub const Control = enum(u8) {
    plain = 0,
    direct_call = 1,
    indirect_call = 2,
    direct_jump = 3,
    indirect_jump = 4,
    conditional_branch = 5,
    ret = 6,
    unsupported = 7,
};

const flag_has_rip_relative_memory: u8 = 1 << 0;
const flag_has_relative_immediate: u8 = 1 << 1;
const flag_uses_stack_pointer_memory: u8 = 1 << 2;
const flag_has_non_default_memory_segment: u8 = 1 << 3;

pub const MemoryRegister = enum(u8) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
    none = 0xFF,
};

pub const DecodedInstruction = struct {
    length: u8,
    control: Control,
    flags: u8,
    imm_offset: u8,
    imm_size: u8,
    disp_offset: u8,
    disp_size: u8,
    modrm_offset: u8,
    mem_base: MemoryRegister,
    mem_index: MemoryRegister,
    mem_scale: u8,
    mem_disp: i32,
    // Interpreted according to `flags` / `control`:
    // - direct branch/call target when a relative immediate is present
    // - absolute memory target for RIP-relative operands
    absolute_target: u64,

    pub fn hasRipRelativeMemory(self: DecodedInstruction) bool {
        return (self.flags & flag_has_rip_relative_memory) != 0;
    }

    pub fn hasRelativeImmediate(self: DecodedInstruction) bool {
        return (self.flags & flag_has_relative_immediate) != 0;
    }

    pub fn usesStackPointerMemory(self: DecodedInstruction) bool {
        return (self.flags & flag_uses_stack_pointer_memory) != 0;
    }

    pub fn hasNonDefaultMemorySegment(self: DecodedInstruction) bool {
        return (self.flags & flag_has_non_default_memory_segment) != 0;
    }

    pub fn canRewriteStackPointerIndirectCall(self: DecodedInstruction) bool {
        if (self.control != .indirect_call or !self.usesStackPointerMemory()) return false;
        if (self.hasNonDefaultMemorySegment()) return false;
        return self.mem_base == .rsp;
    }

    pub fn hasFallthrough(self: DecodedInstruction) bool {
        return switch (self.control) {
            .direct_call, .indirect_call, .conditional_branch, .plain => true,
            .direct_jump, .indirect_jump, .ret, .unsupported => false,
        };
    }
};

pub fn decodeInstruction(runtime_address: u64, bytes: []const u8) HookError!DecodedInstruction {
    if (runtime_address == 0 or bytes.len == 0) return error.InvalidAddress;

    var decoded = CDecodedInstruction{
        .length = 0,
        .control = @intFromEnum(Control.unsupported),
        .flags = 0,
        .imm_offset = 0,
        .imm_size = 0,
        .disp_offset = 0,
        .disp_size = 0,
        .modrm_offset = 0,
        .mem_base = @intFromEnum(MemoryRegister.none),
        .mem_index = @intFromEnum(MemoryRegister.none),
        .mem_scale = 0,
        .mem_disp = 0,
        .absolute_target = 0,
    };

    // The C bridge already applies zighook's conservative policy: if the
    // instruction cannot be decoded or is not safe for the replay machinery to
    // reason about, installation should fail early.
    if (zighook_x86_decode(bytes.ptr, bytes.len, runtime_address, &decoded) == 0) {
        return error.ReplayUnsupported;
    }

    return .{
        .length = decoded.length,
        .control = @enumFromInt(decoded.control),
        .flags = decoded.flags,
        .imm_offset = decoded.imm_offset,
        .imm_size = decoded.imm_size,
        .disp_offset = decoded.disp_offset,
        .disp_size = decoded.disp_size,
        .modrm_offset = decoded.modrm_offset,
        .mem_base = @enumFromInt(decoded.mem_base),
        .mem_index = @enumFromInt(decoded.mem_index),
        .mem_scale = decoded.mem_scale,
        .mem_disp = decoded.mem_disp,
        .absolute_target = decoded.absolute_target,
    };
}

test "Zydis-backed decoder classifies common replay cases" {
    const lea = try decodeInstruction(0x1000, &.{ 0x48, 0x8D, 0x05, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(@as(u8, 7), lea.length);
    try std.testing.expectEqual(Control.plain, lea.control);
    try std.testing.expect(lea.hasRipRelativeMemory());
    try std.testing.expectEqual(@as(u64, 0x1234_667F), lea.absolute_target);

    const call_rel = try decodeInstruction(0x2000, &.{ 0xE8, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(Control.direct_call, call_rel.control);
    try std.testing.expect(call_rel.hasRelativeImmediate());

    const jne_short = try decodeInstruction(0x3000, &.{ 0x75, 0x05 });
    try std.testing.expectEqual(Control.conditional_branch, jne_short.control);
    try std.testing.expectEqual(@as(u8, 2), jne_short.length);

    const call_rsp = try decodeInstruction(0x4000, &.{ 0xFF, 0x54, 0x24, 0x08 });
    try std.testing.expectEqual(Control.indirect_call, call_rsp.control);
    try std.testing.expect(call_rsp.usesStackPointerMemory());
    try std.testing.expect(call_rsp.canRewriteStackPointerIndirectCall());

    const call_stack_top = try decodeInstruction(0x5000, &.{ 0xFF, 0x14, 0x24 });
    try std.testing.expectEqual(Control.indirect_call, call_stack_top.control);
    try std.testing.expect(call_stack_top.usesStackPointerMemory());
    try std.testing.expect(call_stack_top.canRewriteStackPointerIndirectCall());
}

const std = @import("std");
