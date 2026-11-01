//! C ABI for the macOS app. Deletion is deliberately not here: the app moves
//! items to the Trash so every cleanup is reversible.
const std = @import("std");
const core = @import("core.zig");

const Out = struct {
    path: []const u8,
    label: []const u8,
    size: u64,
    idle_days: i64,
};

/// Scans `root` and returns a malloc'd JSON array (release with dcc_free), or null on error.
export fn dcc_scan(root: [*:0]const u8) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const items = core.scanAll(a, std.mem.span(root)) catch return null;
    const out = a.alloc(Out, items.len) catch return null;
    for (items, out) |it, *o| o.* = .{
        .path = it.path,
        .label = it.label,
        .size = it.size,
        .idle_days = @intCast(core.idleDays(io, it)),
    };
    const json = std.json.Stringify.valueAlloc(a, out, .{}) catch return null;
    const res = std.heap.c_allocator.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(res, json);
    return res.ptr;
}

export fn dcc_free(p: ?[*:0]u8) void {
    if (p) |ptr| std.heap.c_allocator.free(std.mem.span(ptr));
}
