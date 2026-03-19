//! Minimal x86_64 replay interface.
//!
//! Unlike the AArch64 backend, x86_64 does not hand-decode instruction bit
//! fields in Zig. `Zydis` provides length and relocation metadata, and the
//! x86_64 backend uses that metadata to decide whether a displaced instruction
//! can be replayed from an out-of-line trampoline.

const HookError = @import("../../error.zig").HookError;
const HookContext = @import("context/root.zig").HookContext;
const SavedInstruction = @import("../../saved_instruction.zig").SavedInstruction;
const decoder = @import("decoder.zig");

pub const ReplayPlan = union(enum) {
    skip: void,
    trampoline: void,

    pub fn requiresTrampoline(plan: ReplayPlan) bool {
        return switch (plan) {
            .trampoline => true,
            .skip => false,
        };
    }
};

pub fn planReplay(_: u64, _: u32) HookError!ReplayPlan {
    return error.ReplayUnsupported;
}

pub fn planReplayInstruction(address: u64, instruction: SavedInstruction) HookError!ReplayPlan {
    const decoded = try decoder.decodeInstruction(address, instruction.slice());
    if (decoded.control == .unsupported) return error.ReplayUnsupported;
    if (decoded.control == .indirect_call and decoded.usesStackPointerMemory()) {
        // `call [rsp + ...]` is deliberately rejected. The trampoline path
        // needs to synthesize a return address push, which would change the
        // effective operand address and therefore change program semantics.
        return error.ReplayUnsupported;
    }
    return .{ .trampoline = {} };
}

pub fn applyReplay(_: ReplayPlan, _: u64, _: *HookContext) HookError!void {
    return error.ReplayUnsupported;
}
