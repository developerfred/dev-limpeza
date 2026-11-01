//! Scanner core shared by the CLI and the C-ABI library.
const std = @import("std");
const walker = @import("walker.zig");
const tg = @import("targets.zig");

pub const Item = struct {
    path: []const u8,
    label: []const u8,
    size: u64,
    /// Newest mtime among the project's own files (ns since epoch).
    last_used: i128,
};

fn lessBySize(_: void, a: Item, b: Item) bool {
    return a.size > b.size;
}

/// Finds every cache under `root` and sizes it in parallel. Result is sorted by size, largest first.
pub fn scanAll(alloc: std.mem.Allocator, root: []const u8) ![]Item {
    var pool: walker.Pool = .{};
    const found = try pool.scan(root);
    defer std.heap.c_allocator.free(found);

    const items = try alloc.alloc(Item, found.len);
    for (found, items) |f, *it| {
        it.* = .{
            .path = try alloc.dupe(u8, f.path),
            .label = f.label,
            .size = f.total.load(.monotonic),
            .last_used = f.last_used,
        };
        std.heap.c_allocator.free(f.path);
        std.heap.c_allocator.destroy(f.total);
    }
    std.mem.sort(Item, items, {}, lessBySize);
    return items;
}

pub fn idleDays(io: std.Io, item: Item) i128 {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @divTrunc(now - item.last_used, tg.ns_per_day);
}
