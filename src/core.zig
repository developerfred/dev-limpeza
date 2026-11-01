//! Scanner core shared by the CLI and the C-ABI library.
const std = @import("std");
const sizer = @import("sizer.zig");

pub const Target = struct {
    name: []const u8,
    /// File that must exist next to the cache dir (null = no check).
    marker: ?[]const u8,
    label: []const u8,
};

pub const targets = [_]Target{
    .{ .name = "node_modules", .marker = "package.json", .label = "node" },
    .{ .name = ".next", .marker = "package.json", .label = "next" },
    .{ .name = "target", .marker = "Cargo.toml", .label = "rust" },
    .{ .name = ".zig-cache", .marker = "build.zig", .label = "zig" },
    .{ .name = ".venv", .marker = null, .label = "python" },
    .{ .name = "__pycache__", .marker = null, .label = "python" },
    .{ .name = "Pods", .marker = "Podfile", .label = "cocoapods" },
};

const skip_dirs = [_][]const u8{ ".git", "Library", ".Trash", ".cache", "Applications" };
const max_depth = 8;
pub const ns_per_day: i128 = 24 * 60 * 60 * std.time.ns_per_s;

pub const Item = struct {
    path: []const u8,
    label: []const u8,
    size: u64,
    total: *std.atomic.Value(u64),
    /// Newest mtime among the project's own files (ns since epoch).
    last_used: i128,
};

fn matchTarget(io: std.Io, parent: std.Io.Dir, name: []const u8) ?Target {
    for (targets) |t| {
        if (!std.mem.eql(u8, t.name, name)) continue;
        if (t.marker) |m| {
            parent.access(io, m, .{}) catch return null;
        }
        return t;
    }
    return null;
}

fn isCacheName(name: []const u8) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// Newest mtime of the project's top-level entries, ignoring cache dirs.
fn lastActivity(io: std.Io, dir: std.Io.Dir) i128 {
    var newest: i128 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (isCacheName(e.name)) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (st.mtime.nanoseconds > newest) newest = st.mtime.nanoseconds;
    }
    return newest;
}

fn discover(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, depth: u32, out: *std.ArrayList(Item)) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (matchTarget(io, dir, e.name)) |t| {
            const full = std.fs.path.join(alloc, &.{ path, e.name }) catch continue;
            const total = alloc.create(std.atomic.Value(u64)) catch continue;
            total.* = std.atomic.Value(u64).init(0);
            out.append(alloc, .{
                .path = full,
                .label = t.label,
                .size = 0,
                .total = total,
                .last_used = lastActivity(io, dir),
            }) catch {};
            continue;
        }
        if (depth >= max_depth) continue;
        var skip = false;
        for (skip_dirs) |s| {
            if (std.mem.eql(u8, s, e.name)) skip = true;
        }
        if (skip) continue;
        var sub = dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        const full = std.fs.path.join(alloc, &.{ path, e.name }) catch continue;
        discover(alloc, io, sub, full, depth + 1, out);
    }
}

fn lessBySize(_: void, a: Item, b: Item) bool {
    return a.size > b.size;
}

/// Finds every cache under `root` and sizes it in parallel. Result is sorted by size, largest first.
pub fn scanAll(alloc: std.mem.Allocator, io: std.Io, root: []const u8) ![]Item {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var items: std.ArrayList(Item) = .empty;
    discover(alloc, io, dir, root, 0, &items);

    var pool: sizer.Pool = .{ .io = io };
    for (items.items) |item| {
        const z = try std.heap.c_allocator.allocSentinel(u8, item.path.len, 0);
        @memcpy(z, item.path);
        pool.push(.{ .path = z, .total = item.total });
    }
    try pool.run();
    for (items.items) |*item| item.size = item.total.load(.monotonic);
    std.mem.sort(Item, items.items, {}, lessBySize);
    return items.items;
}

pub fn idleDays(io: std.Io, item: Item) i128 {
    const now = std.Io.Timestamp.now(io, .real).nanoseconds;
    return @divTrunc(now - item.last_used, ns_per_day);
}
