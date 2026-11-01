//! What counts as a development cache and where the scanner does not look.
const std = @import("std");

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

pub const skip_dirs = [_][]const u8{ ".git", "Library", ".Trash", ".cache", "Applications" };
pub const max_depth = 8;
pub const ns_per_day: i128 = 24 * 60 * 60 * std.time.ns_per_s;

pub fn isCacheName(name: []const u8) bool {
    for (targets) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

pub fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}
