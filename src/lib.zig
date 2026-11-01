//! C ABI for the macOS app. Deletion is deliberately not here: the app moves
//! items to the Trash so every cleanup is reversible.
const std = @import("std");
const core = @import("core.zig");

const Out = struct {
    path: []const u8,
    label: []const u8,
    size: u64,
    idle_days: i64,
    /// Newest activity of the owning project, seconds since the epoch.
    last_used: i64,
};

fn scanJson(root: []const u8, depth: u32) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = core.scanFrom(a, root, depth) catch return null;
    const out = a.alloc(Out, items.len) catch return null;
    for (items, out) |it, *o| o.* = .{
        .path = it.path,
        .label = it.label,
        .size = it.size,
        .idle_days = @intCast(core.idleDays(it)),
        .last_used = @intCast(@divTrunc(it.last_used, std.time.ns_per_s)),
    };
    const json = std.json.Stringify.valueAlloc(a, out, .{}) catch return null;
    const res = std.heap.c_allocator.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(res, json);
    return res.ptr;
}

/// Scans `root` and returns a malloc'd JSON array (release with dcc_free), or null on error.
export fn dcc_scan(root: [*:0]const u8) ?[*:0]u8 {
    return scanJson(std.mem.span(root), 0);
}

/// Rescans one subfolder that sits `depth` levels below the original scan root.
export fn dcc_scan_sub(root: [*:0]const u8, depth: u32) ?[*:0]u8 {
    return scanJson(std.mem.span(root), depth);
}

/// Sizes `n` directories in parallel; out[i] receives the allocated bytes of paths[i]. Returns 0 on success.
export fn dcc_size_paths(paths: [*]const [*:0]const u8, n: usize, out: [*]u64) c_int {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slices = a.alloc([]const u8, n) catch return -1;
    for (slices, paths[0..n]) |*s, p| s.* = std.mem.span(p);
    const sizes = core.sizePaths(a, slices) catch return -1;
    @memcpy(out[0..n], sizes);
    return 0;
}

export fn dcc_free(p: ?[*:0]u8) void {
    if (p) |ptr| std.heap.c_allocator.free(std.mem.span(ptr));
}

const GlobalOut = struct {
    id: []const u8,
    tool: []const u8,
    name: []const u8,
    path: []const u8,
    description: []const u8,
    loses: []const u8,
    category: []const u8,
    risk: []const u8,
    size: u64,
};

/// Sizes the global tool caches in the catalog and returns a malloc'd JSON array (release with dcc_free).
export fn dcc_scan_global() ?[*:0]u8 {
    return globalJson(&.{});
}

/// Like dcc_scan_global but does not walk the `n` absolute catalog paths in `skip` (the caller reuses them).
export fn dcc_scan_global_partial(skip: ?[*]const [*:0]const u8, n: usize) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const slices = arena.allocator().alloc([]const u8, n) catch return null;
    if (skip) |s| {
        for (slices, s[0..n]) |*d, p| d.* = std.mem.span(p);
    }
    return globalJson(slices);
}

fn globalJson(skip: []const []const u8) ?[*:0]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = core.scanGlobal(a, skip) catch return null;
    const out = a.alloc(GlobalOut, items.len) catch return null;
    for (items, out) |it, *o| o.* = .{
        .id = it.entry.id,
        .tool = it.entry.tool,
        .name = it.entry.name,
        .path = it.path,
        .description = it.entry.description,
        .loses = it.entry.loses,
        .category = @tagName(it.entry.category),
        .risk = @tagName(it.entry.risk),
        .size = it.size,
    };
    const json = std.json.Stringify.valueAlloc(a, out, .{}) catch return null;
    const res = std.heap.c_allocator.allocSentinel(u8, json.len, 0) catch return null;
    @memcpy(res, json);
    return res.ptr;
}
