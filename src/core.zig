//! Scanner core shared by the CLI and the C-ABI library.
const std = @import("std");
const walker = @import("walker.zig");
const tg = @import("targets.zig");
const catalog = @import("catalog.zig");

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
    return scanFrom(alloc, root, 0);
}

/// Like `scanAll` for a subfolder that sits `depth` levels below the scan root.
pub fn scanFrom(alloc: std.mem.Allocator, root: []const u8, depth: u32) ![]Item {
    // A missing or unreadable root must be an error, not an empty "clean" result.
    const root_z = try alloc.allocSentinel(u8, root.len, 0);
    @memcpy(root_z, root);
    if (std.c.access(root_z, 0) != 0) return error.RootNotFound;

    var pool: walker.Pool = .{};
    const found = try pool.scan(root, depth);
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

pub fn idleDays(item: Item) i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    return @divTrunc(now - item.last_used, tg.ns_per_day);
}

pub const GlobalItem = struct {
    entry: catalog.Entry,
    path: []const u8,
    size: u64,
};

fn lessGlobalBySize(_: void, a: GlobalItem, b: GlobalItem) bool {
    return a.size > b.size;
}

/// Sizes every catalog entry that exists under the home directory, largest first. Empty ones are dropped.
/// Sizes the given directories in parallel (allocated bytes); missing ones count as 0.
pub fn sizePaths(alloc: std.mem.Allocator, paths: []const []const u8) ![]u64 {
    const totals = try alloc.alloc(std.atomic.Value(u64), paths.len);
    for (totals) |*t| t.* = std.atomic.Value(u64).init(0);
    var pool: walker.Pool = .{};
    try pool.sizePaths(paths, totals);
    const out = try alloc.alloc(u64, paths.len);
    for (totals, out) |*t, *o| o.* = t.load(.monotonic);
    return out;
}

/// `skip` lists absolute catalog paths the caller already knows; they are not walked again.
pub fn scanGlobal(alloc: std.mem.Allocator, skip: []const []const u8) ![]GlobalItem {
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);

    var paths: std.ArrayList([]const u8) = .empty;
    var idx: std.ArrayList(usize) = .empty;
    for (catalog.entries, 0..) |e, i| {
        const full = try std.fs.path.join(alloc, &.{ home, e.path });
        if (isSkipped(full, skip)) continue;
        const z = try alloc.allocSentinel(u8, full.len, 0);
        @memcpy(z, full);
        if (std.c.access(z, 0) != 0) continue;
        try paths.append(alloc, full);
        try idx.append(alloc, i);
    }

    const totals = try alloc.alloc(std.atomic.Value(u64), paths.items.len);
    for (totals) |*t| t.* = std.atomic.Value(u64).init(0);
    var pool: walker.Pool = .{};
    try pool.sizePaths(paths.items, totals);

    var out: std.ArrayList(GlobalItem) = .empty;
    for (paths.items, idx.items, totals) |p, i, *t| {
        const size = t.load(.monotonic);
        if (size == 0) continue;
        try out.append(alloc, .{ .entry = catalog.entries[i], .path = p, .size = size });
    }
    std.mem.sort(GlobalItem, out.items, {}, lessGlobalBySize);
    return out.items;
}

fn isSkipped(path: []const u8, skip: []const []const u8) bool {
    for (skip) |s| {
        if (std.mem.eql(u8, s, path)) return true;
    }
    return false;
}
