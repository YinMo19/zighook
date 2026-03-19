//! Windows executable-memory helpers.
//!
//! Windows uses `VirtualProtect` / `VirtualAlloc` rather than POSIX `mmap` and
//! `mprotect`. The high-level contract remains the same as on Unix:
//! - patch executable pages by making them writable temporarily
//! - flush the instruction cache after self-modifying code
//! - allocate writable scratch pages for trampolines and then seal them RX

const std = @import("std");

const HookError = @import("../../error.zig").HookError;
const TrampolineKind = @import("../types.zig").TrampolineKind;

const windows = std.os.windows;
const kernel32 = windows.kernel32;

extern "kernel32" fn FlushInstructionCache(
    hProcess: windows.HANDLE,
    lpBaseAddress: ?*const anyopaque,
    dwSize: usize,
) callconv(.winapi) windows.BOOL;

const ProtectRange = struct {
    start: usize,
    len: usize,
};

/// Writes raw machine code bytes into an executable page on Windows.
///
/// The helper preserves the page's previous protection value rather than
/// assuming the code section is always RX. That keeps the patching path
/// compatible with debuggers, profilers, or loaders that may have already
/// applied a different executable-page policy.
pub fn patchBytes(address: u64, bytes: []const u8) HookError!void {
    if (address == 0 or bytes.len == 0) return error.InvalidAddress;

    const address_usize: usize = @intCast(address);
    const protect_range = computeProtectRange(address_usize, bytes.len);

    var old_protect: windows.DWORD = 0;
    windows.VirtualProtect(
        @ptrFromInt(protect_range.start),
        protect_range.len,
        windows.PAGE_EXECUTE_READWRITE,
        &old_protect,
    ) catch return error.PageProtectionChangeFailed;
    errdefer {
        var ignored: windows.DWORD = 0;
        windows.VirtualProtect(@ptrFromInt(protect_range.start), protect_range.len, old_protect, &ignored) catch {};
    }

    const destination: [*]u8 = @ptrFromInt(address_usize);
    @memcpy(destination[0..bytes.len], bytes);
    flushInstructionCache(destination, bytes.len);

    var restored_protect: windows.DWORD = 0;
    windows.VirtualProtect(@ptrFromInt(protect_range.start), protect_range.len, old_protect, &restored_protect) catch {
        return error.PageProtectionChangeFailed;
    };
}

/// Flushes the current process instruction cache for a modified code range.
pub fn flushInstructionCache(address: [*]u8, len: usize) void {
    _ = FlushInstructionCache(windows.GetCurrentProcess(), address, len);
}

/// Allocates a writable trampoline page.
///
/// x86_64 RIP-relative replay keeps the existing Linux behavior: search for a
/// scratch page inside the signed 32-bit displacement window first, then fall
/// back to an arbitrary allocation if no nearby region is currently available.
pub fn allocateTrampolinePage(address_hint: u64, kind: TrampolineKind) HookError![]align(std.heap.page_size_min) u8 {
    return switch (kind) {
        .generic => fallbackAllocateTrampolinePage(address_hint),
        .rip_relative => allocateRipRelativeTrampolinePage(address_hint),
    };
}

/// Releases a trampoline page previously allocated by
/// `allocateTrampolinePage(...)`.
pub fn freeTrampolinePage(trampoline_pc: u64) void {
    if (trampoline_pc == 0) return;
    windows.VirtualFree(@ptrFromInt(@as(usize, @intCast(trampoline_pc))), 0, windows.MEM_RELEASE);
}

/// Converts a writable trampoline page into an RX page once code emission is
/// complete.
pub fn sealTrampolinePage(page: []align(std.heap.page_size_min) u8) HookError!void {
    var old_protect: windows.DWORD = 0;
    windows.VirtualProtect(page.ptr, page.len, windows.PAGE_EXECUTE_READ, &old_protect) catch {
        return error.TrampolineProtectFailed;
    };
}

fn fallbackAllocateTrampolinePage(address_hint: u64) HookError![]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    const granularity = allocationGranularity();
    const aligned_hint = alignDown(address_hint, granularity);
    const hint: ?windows.LPVOID = if (aligned_hint != 0)
        @ptrFromInt(@as(usize, @intCast(aligned_hint)))
    else
        null;

    const mapped = windows.VirtualAlloc(
        hint,
        page_size,
        windows.MEM_RESERVE | windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    ) catch return error.TrampolineAllocationFailed;

    const page_ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(mapped));
    return page_ptr[0..page_size];
}

fn tryAllocatePageAt(candidate_addr: u64, page_size: usize) ?[]align(std.heap.page_size_min) u8 {
    const candidate: ?windows.LPVOID = @ptrFromInt(@as(usize, @intCast(candidate_addr)));
    const mapped = kernel32.VirtualAlloc(
        candidate,
        page_size,
        windows.MEM_RESERVE | windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    ) orelse {
        _ = windows.GetLastError();
        return null;
    };

    if (@intFromPtr(mapped) != @as(usize, @intCast(candidate_addr))) {
        windows.VirtualFree(mapped, 0, windows.MEM_RELEASE);
        return null;
    }

    const page_ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(mapped));
    return page_ptr[0..page_size];
}

fn allocateRipRelativeTrampolinePage(address_hint: u64) HookError![]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.pageSize();
    const granularity = allocationGranularity();
    const base_addr = alignDown(address_hint, granularity);
    const granularity_mask = @as(u64, @intCast(granularity - 1));
    const max_distance = @as(u64, std.math.maxInt(i32)) & ~granularity_mask;
    const lower_bound = if (base_addr > max_distance) base_addr - max_distance else 0;
    const upper_bound = std.math.add(u64, base_addr, max_distance) catch (std.math.maxInt(u64) & ~granularity_mask);

    // `VirtualAlloc` with a non-null base address behaves like an exact-address
    // reservation for our purposes: either that region is available and the
    // call succeeds there, or it fails and we continue the search. Walking
    // outward symmetrically keeps the first success as close as possible to the
    // displaced RIP-relative instruction.
    var delta: u64 = 0;
    while (delta <= max_distance) : (delta += granularity) {
        const high_addr = std.math.add(u64, base_addr, delta) catch upper_bound + granularity;
        if (high_addr <= upper_bound) {
            if (tryAllocatePageAt(high_addr, page_size)) |mapped| return mapped;
        }

        if (delta != 0 and base_addr >= lower_bound + delta) {
            const low_addr = base_addr - delta;
            if (tryAllocatePageAt(low_addr, page_size)) |mapped| return mapped;
        }
    }

    return fallbackAllocateTrampolinePage(address_hint);
}

fn allocationGranularity() usize {
    var info = std.mem.zeroes(windows.SYSTEM_INFO);
    kernel32.GetSystemInfo(&info);
    return info.dwAllocationGranularity;
}

fn alignDown(value: u64, alignment: usize) u64 {
    return value & ~@as(u64, @intCast(alignment - 1));
}

fn computeProtectRange(address: usize, len: usize) ProtectRange {
    const page_size = std.heap.pageSize();
    const start = address & ~(page_size - 1);
    const end_inclusive = address + len - 1;
    const end_page = end_inclusive & ~(page_size - 1);

    return .{
        .start = start,
        .len = (end_page + page_size) - start,
    };
}

test "computeProtectRange spans exactly one page" {
    const page_size = std.heap.pageSize();
    const range = computeProtectRange(0x1003, 4);
    try std.testing.expectEqual(@as(usize, 0x1003) & ~(page_size - 1), range.start);
    try std.testing.expectEqual(page_size, range.len);
}

test "alignDown uses the requested allocation granularity" {
    try std.testing.expectEqual(@as(u64, 0x10000), alignDown(0x12345, 0x10000));
    try std.testing.expectEqual(@as(u64, 0x12000), alignDown(0x12345, 0x1000));
}
