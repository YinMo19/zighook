//! Public x86_64 backend facade.
//!
//! x86_64 differs from the AArch64 backend in two important ways:
//! - trap patching is byte-oriented (`int3` plus `nop` padding), not `u32` opcode-oriented
//! - execute-original replay depends on decoded instruction length and relocation metadata
//!
//! The backend therefore exposes the same high-level runtime contract as
//! AArch64 while deriving more of its behavior from `SavedInstruction` bytes.

const HookError = @import("../error.zig").HookError;
const SavedInstruction = @import("../saved_instruction.zig").SavedInstruction;
const memory = @import("../memory.zig");
const arch_constants = @import("x86_64/constants.zig");
const arch_context = @import("x86_64/context/root.zig");
const arch_decoder = @import("x86_64/decoder.zig");
const arch_instruction = @import("x86_64/instruction.zig");
const arch_trampoline = @import("x86_64/trampoline.zig");

pub const trap_opcode = arch_constants.int3_opcode;

pub const HookContext = arch_context.HookContext;
pub const InstrumentCallback = arch_context.InstrumentCallback;
pub const GpRegisters = arch_context.GpRegisters;
pub const GpRegistersNamed = arch_context.GpRegistersNamed;
pub const XRegisters = GpRegisters;
pub const XRegistersNamed = GpRegistersNamed;
pub const FpRegisters = arch_context.FpRegisters;
pub const FpRegistersNamed = arch_context.FpRegistersNamed;
pub const captureMachineContext = arch_context.captureMachineContext;
pub const writeBackMachineContext = arch_context.writeBackMachineContext;

pub const ReplayPlan = arch_instruction.ReplayPlan;
pub const planReplay = arch_instruction.planReplay;
pub const applyReplay = arch_instruction.applyReplay;

pub const createOriginalTrampoline = arch_trampoline.createOriginalTrampoline;
pub const freeOriginalTrampoline = arch_trampoline.freeOriginalTrampoline;

pub fn planReplayInstruction(address: u64, instruction: SavedInstruction) HookError!ReplayPlan {
    return arch_instruction.planReplayInstruction(address, instruction);
}

pub fn supportsPatchCode() bool {
    return false;
}

pub fn trapPatchBytes() []const u8 {
    return arch_constants.int3_bytes[0..];
}

pub fn makeTrapPatch(step_len: u8) HookError!SavedInstruction {
    if (step_len == 0) return error.InvalidAddress;

    // Runtime-installed x86 traps always preserve the full displaced
    // instruction footprint: byte 0 becomes `int3`, the remainder becomes NOPs.
    var bytes = [_]u8{arch_constants.nop_opcode} ** 16;
    bytes[0] = arch_constants.int3_opcode;
    return SavedInstruction.fromSlice(bytes[0..@as(usize, step_len)]);
}

pub fn validateAddress(address: u64) HookError!void {
    if (address == 0) return error.InvalidAddress;
}

pub fn instructionWidth(address: u64) HookError!u8 {
    var bytes = [_]u8{0} ** 16;
    try memory.readInto(address, bytes[0..]);
    // x86_64 instruction width is not derivable from the address alone; decode
    // enough bytes to let Zydis identify the first complete instruction.
    const decoded = try arch_decoder.decodeInstruction(address, bytes[0..]);
    return decoded.length;
}

pub fn isTrapInstruction(address: u64) HookError!bool {
    var opcode = [_]u8{0};
    try memory.readInto(address, opcode[0..]);
    return opcode[0] == arch_constants.int3_opcode;
}

pub fn trapAddress(ctx: *const HookContext) HookError!u64 {
    if (ctx.pc == 0) return error.InvalidAddress;
    // INT3 reports `rip` after the one-byte trap opcode, so normalize back to
    // the actual instruction start before registry lookup.
    return ctx.pc - 1;
}

pub fn normalizeTrapContext(ctx: *HookContext, address: u64) void {
    ctx.pc = address;
}

pub fn returnToCaller(ctx: *HookContext) HookError!void {
    var return_address_bytes = [_]u8{0} ** 8;
    // The signal path models "return from the current function" by consuming
    // the stored return address from the interrupted stack frame.
    try memory.readInto(ctx.sp, return_address_bytes[0..]);
    ctx.pc = std.mem.readInt(u64, return_address_bytes[0..], .little);
    ctx.sp += 8;
}

const std = @import("std");
