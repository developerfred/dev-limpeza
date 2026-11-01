//! Parallel bulk directory walker for macOS. One pool of threads does both
//! jobs: discovering caches (names, types and mtimes come back from a single
//! getattrlistbulk call per directory, so markers like package.json need no
//! extra syscalls) and sizing them (allocated bytes), overlapping the two.
const std = @import("std");
const builtin = @import("builtin");
const tg = @import("targets.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("walker.zig uses getattrlistbulk and only supports macOS");
}

const alloc = std.heap.c_allocator;

const Attrlist = extern struct {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};
extern "c" fn getattrlistbulk(dirfd: c_int, alist: *Attrlist, buf: *anyopaque, size: usize, options: u64) c_int;

const ATTR_CMN_NAME: u32 = 0x1;
const ATTR_CMN_OBJTYPE: u32 = 0x8;
const ATTR_CMN_MODTIME: u32 = 0x400;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const ATTR_FILE_ALLOCSIZE: u32 = 0x4;
const VREG: u32 = 1;
const VDIR: u32 = 2;

const buf_size = 256 * 1024;

pub const Found = struct {
    /// Owned by the caller after `run` (allocated with the C allocator).
    path: []const u8,
    label: []const u8,
    total: *std.atomic.Value(u64),
    /// Newest mtime among the project's own entries (ns since epoch).
    last_used: i128,
};

const Kind = enum { discover, size };

const Job = struct {
    path: [:0]u8,
    kind: Kind,
    depth: u32 = 0,
    total: ?*std.atomic.Value(u64) = null,
};

pub const Pool = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    stack: std.ArrayList(Job) = .empty,
    found: std.ArrayList(Found) = .empty,
    pending: usize = 0,

    fn lock(self: *Pool) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *Pool) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn push(self: *Pool, job: Job) void {
        self.lock();
        defer self.unlock();
        self.stack.append(alloc, job) catch {
            alloc.free(job.path);
            return;
        };
        self.pending += 1;
        _ = std.c.pthread_cond_signal(&self.cond);
    }

    fn next(self: *Pool) ?Job {
        self.lock();
        defer self.unlock();
        while (self.stack.items.len == 0) {
            if (self.pending == 0) return null;
            _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        return self.stack.pop();
    }

    fn finish(self: *Pool) void {
        self.lock();
        defer self.unlock();
        self.pending -= 1;
        if (self.pending == 0) _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    fn worker(self: *Pool) void {
        const buf = alloc.alignedAlloc(u8, .@"8", buf_size) catch return;
        defer alloc.free(buf);
        while (self.next()) |job| {
            switch (job.kind) {
                .discover => discoverDir(self, job, buf),
                .size => sizeDir(self, job, buf),
            }
            alloc.free(job.path);
            self.finish();
        }
    }

    /// Starts the workers and returns when every queued job is done. The walk is
    /// bound by kernel directory enumeration, where threads spend much of their time
    /// blocked or contending, so oversubscribing the CPUs pays off (measured on an
    /// 8-core M-series: 32 threads beat 8 by about 2x). DCC_THREADS overrides.
    fn run(self: *Pool) !void {
        var n = std.math.clamp((std.Thread.getCpuCount() catch 4) * 4, 8, 64);
        if (std.c.getenv("DCC_THREADS")) |v| n = @max(1, std.fmt.parseInt(usize, std.mem.span(v), 10) catch n);
        const threads = try alloc.alloc(std.Thread, n);
        defer alloc.free(threads);
        var started: usize = 0;
        for (threads) |*t| {
            t.* = std.Thread.spawn(.{}, worker, .{self}) catch break;
            started += 1;
        }
        for (threads[0..started]) |t| t.join();
        self.stack.deinit(alloc);
    }

    /// Walks `root`, returning every cache found with its size counter filled in.
    /// `depth` is how many levels `root` already sits below the original scan root, so a partial
    /// rescan of a subfolder finds exactly the caches a full scan would.
    pub fn scan(self: *Pool, root: []const u8, depth: u32) ![]Found {
        self.push(.{ .path = try dupeZ(root), .kind = .discover, .depth = depth });
        try self.run();
        return self.found.toOwnedSlice(alloc);
    }

    /// Sizes known directories in parallel; `totals[i]` receives the bytes of `paths[i]`.
    pub fn sizePaths(self: *Pool, paths: []const []const u8, totals: []std.atomic.Value(u64)) !void {
        for (paths, totals) |p, *t| self.push(.{ .path = try dupeZ(p), .kind = .size, .total = t });
        try self.run();
    }
};

fn dupeZ(s: []const u8) ![:0]u8 {
    const z = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(z, s);
    return z;
}

fn joinZ(parent: []const u8, name: []const u8) ![:0]u8 {
    const p = try alloc.allocSentinel(u8, parent.len + 1 + name.len, 0);
    @memcpy(p[0..parent.len], parent);
    p[parent.len] = '/';
    @memcpy(p[parent.len + 1 ..], name);
    return p;
}

const Parsed = struct {
    name: []const u8,
    objtype: u32,
    mtime: i128,
    alloc_size: u64,
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Decodes the entry at `p.*` of a getattrlistbulk buffer and advances `p`.
fn parseEntry(buf: []const u8, p: *usize) Parsed {
    const len = rd32(buf, p.*);
    var q = p.* + 4;
    const ret_common = rd32(buf, q);
    const ret_file = rd32(buf, q + 12);
    q += 20;
    var out: Parsed = .{ .name = "", .objtype = 0, .mtime = 0, .alloc_size = 0 };
    if (ret_common & ATTR_CMN_NAME != 0) {
        const off: i32 = @bitCast(rd32(buf, q));
        const nlen = rd32(buf, q + 4);
        const start: usize = @intCast(@as(isize, @intCast(q)) + off);
        out.name = buf[start .. start + nlen -| 1];
        q += 8;
    }
    if (ret_common & ATTR_CMN_OBJTYPE != 0) {
        out.objtype = rd32(buf, q);
        q += 4;
    }
    if (ret_common & ATTR_CMN_MODTIME != 0) {
        const sec = std.mem.readInt(i64, buf[q..][0..8], .little);
        const nsec = std.mem.readInt(i64, buf[q + 8 ..][0..8], .little);
        out.mtime = @as(i128, sec) * std.time.ns_per_s + nsec;
        q += 16;
    }
    if (ret_file & ATTR_FILE_ALLOCSIZE != 0) {
        out.alloc_size = std.mem.readInt(u64, buf[q..][0..8], .little);
    }
    p.* += len;
    return out;
}

fn openDir(path: [:0]const u8) ?c_int {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    return if (fd < 0) null else fd;
}

fn attrs() Attrlist {
    return .{
        .bitmapcount = 5,
        .reserved = 0,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = ATTR_FILE_ALLOCSIZE,
        .forkattr = 0,
    };
}

fn sizeDir(pool: *Pool, job: Job, buf: []align(8) u8) void {
    const fd = openDir(job.path) orelse return;
    defer _ = std.c.close(fd);
    var al = attrs();
    var sum: u64 = 0;
    while (true) {
        const count = getattrlistbulk(fd, &al, buf.ptr, buf.len, 0);
        if (count <= 0) break;
        var p: usize = 0;
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const e = parseEntry(buf, &p);
            if (e.objtype == VDIR) {
                const child = joinZ(job.path, e.name) catch continue;
                pool.push(.{ .path = child, .kind = .size, .total = job.total });
            } else if (e.objtype == VREG) {
                sum += e.alloc_size;
            }
        }
    }
    _ = job.total.?.fetchAdd(sum, .monotonic);
}

const Entry = struct { off: u32, len: u32, objtype: u32, mtime: i128 };

fn discoverDir(pool: *Pool, job: Job, buf: []align(8) u8) void {
    const fd = openDir(job.path) orelse return;
    defer _ = std.c.close(fd);

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(alloc);
    var ents: std.ArrayList(Entry) = .empty;
    defer ents.deinit(alloc);

    var al = attrs();
    while (true) {
        const count = getattrlistbulk(fd, &al, buf.ptr, buf.len, 0);
        if (count <= 0) break;
        var p: usize = 0;
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const e = parseEntry(buf, &p);
            ents.append(alloc, .{
                .off = @intCast(names.items.len),
                .len = @intCast(e.name.len),
                .objtype = e.objtype,
                .mtime = e.mtime,
            }) catch continue;
            names.appendSlice(alloc, e.name) catch {
                _ = ents.pop();
            };
        }
    }

    // Project activity = newest mtime among entries that are not caches themselves.
    var newest: i128 = 0;
    for (ents.items) |e| {
        const name = names.items[e.off..][0..e.len];
        if (tg.isCacheName(name)) continue;
        if (e.mtime > newest) newest = e.mtime;
    }

    for (ents.items) |e| {
        if (e.objtype != VDIR) continue;
        const name = names.items[e.off..][0..e.len];

        if (matchTarget(names.items, ents.items, name)) |t| {
            const full = joinZ(job.path, name) catch continue;
            const total = alloc.create(std.atomic.Value(u64)) catch {
                alloc.free(full);
                continue;
            };
            total.* = std.atomic.Value(u64).init(0);
            const keep = alloc.dupe(u8, full) catch {
                alloc.free(full);
                alloc.destroy(total);
                continue;
            };
            pool.lock();
            // A project holding nothing but caches has no sibling activity: fall back to the cache's own mtime.
            const last_used = if (newest != 0) newest else e.mtime;
            pool.found.append(alloc, .{ .path = keep, .label = t.label, .total = total, .last_used = last_used }) catch {};
            pool.unlock();
            pool.push(.{ .path = full, .kind = .size, .total = total });
            continue;
        }

        if (job.depth >= tg.max_depth or tg.isSkipped(name)) continue;
        const child = joinZ(job.path, name) catch continue;
        pool.push(.{ .path = child, .kind = .discover, .depth = job.depth + 1 });
    }
}

fn matchTarget(names: []const u8, ents: []const Entry, name: []const u8) ?tg.Target {
    for (tg.targets) |t| {
        if (!std.mem.eql(u8, t.name, name)) continue;
        if (t.marker) |m| {
            var present = false;
            for (ents) |e| {
                if (std.mem.eql(u8, names[e.off..][0..e.len], m)) {
                    present = true;
                    break;
                }
            }
            if (!present) return null;
        }
        return t;
    }
    return null;
}
