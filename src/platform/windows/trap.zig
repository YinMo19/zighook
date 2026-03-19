//! Windows trap-handler installation and exception dispatch.
//!
//! Windows does not expose Unix `sigaction`, so zighook uses a vectored
//! exception handler (VEH) to intercept breakpoint exceptions and translate the
//! native `CONTEXT` record into the same architecture-neutral runtime dispatch
//! flow used by the Unix backends.

const std = @import("std");

const HookError = @import("../../error.zig").HookError;
const arch = @import("../../arch/root.zig");
const dispatch = @import("../../runtime/dispatch.zig");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

// Windows reports a software `int3` as STATUS_BREAKPOINT / EXCEPTION_BREAKPOINT.
const exception_breakpoint: u32 = 0x8000_0003;
const exception_continue_execution: c_long = -1;

var handler_installed = false;
var handler_handle: ?windows.LPVOID = null;

fn trapHandler(exception_info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const record = exception_info.ExceptionRecord;
    if (record.ExceptionCode != exception_breakpoint) {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    }

    // The architecture layer owns the stable callback-facing register layout.
    // The Windows backend only needs to bridge the native `CONTEXT` pointer
    // into that view and then reuse the shared runtime dispatch policy.
    var ctx = arch.captureMachineContext(exception_info.ContextRecord) orelse {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    };
    const trap_address = arch.trapAddress(&ctx) catch {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    };
    arch.normalizeTrapContext(&ctx, trap_address);

    if (!(arch.isTrapInstruction(trap_address) catch false)) {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    }

    if (!dispatch.handleTrap(trap_address, &ctx)) {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    }

    if (!arch.writeBackMachineContext(exception_info.ContextRecord, &ctx)) {
        return windows.EXCEPTION_CONTINUE_SEARCH;
    }

    return exception_continue_execution;
}

/// Installs zighook's process-global Windows exception backend.
///
/// Unlike the Unix backend, Windows naturally chains vectored exception
/// handlers for us. Returning `EXCEPTION_CONTINUE_SEARCH` leaves unrelated
/// breakpoints or debugger traffic untouched, while returning
/// `EXCEPTION_CONTINUE_EXECUTION` resumes execution with the callback-edited
/// machine context.
pub fn ensureHandlersInstalled() HookError!void {
    if (handler_installed) return;

    handler_handle = kernel32.AddVectoredExceptionHandler(1, trapHandler) orelse {
        return error.TrapHandlerInstallFailed;
    };
    handler_installed = true;
}
