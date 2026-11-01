//! dev-cache-clean CLI: finds development caches (node_modules, target, .venv, ...)
//! and reports the ones whose project has not been touched for a while.
const std = @import("std");
const core = @import("core.zig");

fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v = f;
    var i: usize = 0;
    while (v >= 1024 and i < units.len - 1) : (i += 1) v /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch "?";
}

fn cmdScan(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, root: []const u8, days: i128) !void {
    const items = try core.scanAll(alloc, root);

    var stale_total: u64 = 0;
    var total: u64 = 0;
    var sb: [32]u8 = undefined;

    try out.print("{s:>10}  {s:>6}  {s:<9} {s}\n", .{ "SIZE", "IDLE", "TYPE", "PATH" });
    for (items) |item| {
        const idle = core.idleDays(io, item);
        const stale = idle >= days;
        total += item.size;
        if (stale) stale_total += item.size;
        try out.print("{s:>10}  {d:>5}d  {s:<9} {s}{s}\n", .{
            fmtSize(&sb, item.size), idle, item.label, item.path,
            if (stale) "  [stale]" else "",
        });
    }
    var sb2: [32]u8 = undefined;
    try out.print("\n{d} caches, {s} total, {s} unused for >= {d} days\n", .{
        items.len, fmtSize(&sb, total), fmtSize(&sb2, stale_total), days,
    });
}

fn cmdDocker(alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !void {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "docker", "system", "df" },
    }) catch {
        try out.print("docker not found\n", .{});
        return;
    };
    if (res.term != .exited or res.term.exited != 0) {
        try out.print("docker daemon not reachable (is Docker running?)\n", .{});
        return;
    }
    try out.print("{s}\nReclaim with: docker system prune (review first)\n", .{res.stdout});
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        try out.print(
            \\dev-cache-clean - find stale development caches
            \\
            \\usage:
            \\  dev-cache-clean scan [path] [--days N]   (default: cwd, 30 days)
            \\  dev-cache-clean docker
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "docker")) return cmdDocker(alloc, io, out);
    if (std.mem.eql(u8, args[1], "scan")) {
        var root: []const u8 = ".";
        var days: i128 = 30;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--days") and i + 1 < args.len) {
                i += 1;
                days = try std.fmt.parseInt(i128, args[i], 10);
            } else root = args[i];
        }
        return cmdScan(alloc, io, out, root, days);
    }
    try out.print("unknown command: {s}\n", .{args[1]});
}
