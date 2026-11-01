//! Portable walker for Linux and Windows: single-threaded, std.Io based. Sizes are apparent
//! (file length), not allocated bytes, and symbolic links are never followed.
const std = @import("std");
const tg = @import("targets.zig");

pub const alloc = std.heap.page_allocator;

pub const Found = struct {
    path: []const u8,
    label: []const u8,
    total: *std.atomic.Value(u64),
    /// Newest mtime among the project's own entries (ns since epoch).
    last_used: i128,
};

pub fn nowNs() i128 {
    var th = std.Io.Threaded.init_single_threaded;
    return std.Io.Timestamp.now(th.io(), .real).nanoseconds;
}

pub fn exists(path: []const u8) bool {
    var th = std.Io.Threaded.init_single_threaded;
    const io = th.io();
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

const Entry = struct { name: []const u8, is_dir: bool };

pub const Pool = struct {
    found: std.ArrayList(Found) = .empty,

    pub fn scan(self: *Pool, root: []const u8, depth: u32) ![]Found {
        var th = std.Io.Threaded.init_single_threaded;
        const io = th.io();
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        discover(self, io, dir, root, depth);
        return self.found.toOwnedSlice(alloc);
    }

    pub fn sizePaths(self: *Pool, paths: []const []const u8, totals: []std.atomic.Value(u64)) !void {
        _ = self;
        var th = std.Io.Threaded.init_single_threaded;
        const io = th.io();
        for (paths, totals) |p, *t| {
            var d = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true }) catch continue;
            defer d.close(io);
            t.store(sizeDir(io, d), .monotonic);
        }
    }
};

fn sizeDir(io: std.Io, dir: std.Io.Dir) u64 {
    var sum: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        switch (e.kind) {
            .file => {
                const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch continue;
                sum += st.size;
            },
            .directory => {
                var sub = dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                defer sub.close(io);
                sum += sizeDir(io, sub);
            },
            else => {},
        }
    }
    return sum;
}

fn hasName(entries: []const Entry, name: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

fn discover(pool: *Pool, io: std.Io, dir: std.Io.Dir, path: []const u8, depth: u32) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const name = a.dupe(u8, e.name) catch continue;
        entries.append(a, .{ .name = name, .is_dir = e.kind == .directory }) catch {};
    }

    // Project activity = newest mtime among entries that are not caches themselves.
    var newest: i128 = 0;
    for (entries.items) |e| {
        if (tg.isCacheName(e.name)) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (st.mtime.nanoseconds > newest) newest = st.mtime.nanoseconds;
    }

    for (entries.items) |e| {
        if (!e.is_dir) continue;

        if (matchTarget(entries.items, e.name)) |t| {
            const full = std.fs.path.join(alloc, &.{ path, e.name }) catch continue;
            const total = alloc.create(std.atomic.Value(u64)) catch continue;
            var size: u64 = 0;
            if (dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false })) |sub_const| {
                var sub = sub_const;
                defer sub.close(io);
                size = sizeDir(io, sub);
            } else |_| {}
            total.* = std.atomic.Value(u64).init(size);
            var last_used = newest;
            if (last_used == 0) {
                const st = dir.statFile(io, e.name, .{}) catch null;
                if (st) |s| last_used = s.mtime.nanoseconds;
            }
            pool.found.append(alloc, .{ .path = full, .label = t.label, .total = total, .last_used = last_used }) catch {};
            continue;
        }

        if (depth >= tg.max_depth or tg.isSkipped(e.name)) continue;
        var sub = dir.openDir(io, e.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer sub.close(io);
        const full = std.fs.path.join(alloc, &.{ path, e.name }) catch continue;
        defer alloc.free(full);
        discover(pool, io, sub, full, depth + 1);
    }
}

fn matchTarget(entries: []const Entry, name: []const u8) ?tg.Target {
    for (tg.targets) |t| {
        if (!std.mem.eql(u8, t.name, name)) continue;
        if (t.marker) |m| {
            if (!hasName(entries, m)) return null;
        }
        return t;
    }
    return null;
}
