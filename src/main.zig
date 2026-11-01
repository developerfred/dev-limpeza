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

fn cmdScan(alloc: std.mem.Allocator, out: *std.Io.Writer, root: []const u8, days: i128) !void {
    const items = try core.scanAll(alloc, root);

    var stale_total: u64 = 0;
    var total: u64 = 0;
    var sb: [32]u8 = undefined;

    try out.print("{s:>10}  {s:>6}  {s:<9} {s}\n", .{ "SIZE", "IDLE", "TYPE", "PATH" });
    for (items) |item| {
        const idle = core.idleDays(item);
        const stale = idle >= days;
        total += item.size;
        if (stale) stale_total += item.size;
        try out.print("{s:>10}  {d:>5}d  {s:<9} {s}{s}\n", .{
            fmtSize(&sb, item.size), @as(i64, @intCast(idle)), item.label, item.path,
            if (stale) "  [stale]" else "",
        });
    }
    var sb2: [32]u8 = undefined;
    try out.print("\n{d} caches, {s} total, {s} unused for >= {d} days\n", .{
        items.len, fmtSize(&sb, total), fmtSize(&sb2, stale_total), days,
    });
}

/// Sizes one directory with the parallel walker (used for benchmarking).
fn cmdSize(alloc: std.mem.Allocator, out: *std.Io.Writer, path: []const u8) !void {
    const walker = @import("walker.zig");
    var pool: walker.Pool = .{};
    var totals = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)};
    try pool.sizePaths(&.{path}, &totals);
    _ = alloc;
    var sb: [32]u8 = undefined;
    try out.print("{s}  {s}\n", .{ fmtSize(&sb, totals[0].load(.monotonic)), path });
}

fn cmdGlobal(alloc: std.mem.Allocator, out: *std.Io.Writer) !void {
    const items = try core.scanGlobal(alloc);
    var total: u64 = 0;
    var sb: [32]u8 = undefined;
    try out.print("{s:>10}  {s:<12} {s:<7} {s:<14} {s}\n", .{ "SIZE", "TYPE", "RISK", "TOOL", "WHAT" });
    for (items) |it| {
        total += it.size;
        try out.print("{s:>10}  {s:<12} {s:<7} {s:<14} {s}  ({s})\n", .{
            fmtSize(&sb, it.size), @tagName(it.entry.category), @tagName(it.entry.risk),
            it.entry.tool,         it.entry.name,                it.path,
        });
    }
    try out.print("\n{d} locations, {s} total\n", .{ items.len, fmtSize(&sb, total) });
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
            \\  dev-cache-clean global                   (package managers, AI agents, editors, Xcode)
            \\  dev-cache-clean docker
            \\
        , .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "size") and args.len > 2) return cmdSize(alloc, out, args[2]);
    if (std.mem.eql(u8, args[1], "global")) return cmdGlobal(alloc, out);
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
        return cmdScan(alloc, out, root, days);
    }
    try out.print("unknown command: {s}\n", .{args[1]});
}
