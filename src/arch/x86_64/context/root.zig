//! Public x86_64 context facade.
//!
//! Files under `context/` are split by platform family:
//! - `types.zig`: stable public register/context layout
//! - `unix/*`: Unix signal-frame bridges
//! - `windows.zig`: Windows `CONTEXT` bridge
//!
//! The register layout itself is OS-independent, but trap delivery is not.
//! Keeping that split explicit makes it much easier to add new backends
//! without perturbing the callback-facing API.

const builtin = @import("builtin");
const types = @import("types.zig");

const backend = switch (builtin.os.tag) {
    .macos => @import("unix/darwin.zig"),
    .linux => @import("unix/linux.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("x86_64 context remapping is currently implemented for macOS, Linux-family targets, and Windows."),
};

pub const HookContext = types.HookContext;
pub const InstrumentCallback = types.InstrumentCallback;
pub const GpRegisters = types.GpRegisters;
pub const GpRegistersNamed = types.GpRegistersNamed;
pub const FpRegisters = types.FpRegisters;
pub const FpRegistersNamed = types.FpRegistersNamed;

pub const captureMachineContext = backend.captureMachineContext;
pub const writeBackMachineContext = backend.writeBackMachineContext;
