//! Parallel directory sizing. On macOS each worker reads whole directories
//! with getattrlistbulk (names, types and allocated sizes in one syscall
//! instead of one stat per file); elsewhere it falls back to readdir + fstatat.
const std = @import("std");
const builtin = @import("builtin");

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
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const ATTR_FILE_ALLOCSIZE: u32 = 0x4;
const VREG: u32 = 1;
const VDIR: u32 = 2;

pub const Job = struct {
    path: [:0]u8,
    total: *std.atomic.Value(u64),
};

pub const Pool = struct {
    io: std.Io,
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    stack: std.ArrayList(Job) = .empty,
    pending: usize = 0,

    pub fn push(self: *Pool, job: Job) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.stack.append(alloc, job) catch return;
        self.pending += 1;
        _ = std.c.pthread_cond_signal(&self.cond);
    }

    fn next(self: *Pool) ?Job {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (self.stack.items.len == 0) {
            if (self.pending == 0) return null;
            _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        }
        return self.stack.pop();
    }

    fn finish(self: *Pool) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.pending -= 1;
        if (self.pending == 0) _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    fn worker(self: *Pool) void {
        const buf = alloc.alignedAlloc(u8, .@"8", 256 * 1024) catch return;
        defer alloc.free(buf);
        while (self.next()) |job| {
            processDir(self, job, buf);
            alloc.free(job.path);
            self.finish();
        }
    }

    /// Block until every pushed job (and the subdirs it spawns) is done.
    pub fn run(self: *Pool) !void {
        const n = @max(2, std.Thread.getCpuCount() catch 4);
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
};

fn pushChild(pool: *Pool, parent: [:0]const u8, name: []const u8, total: *std.atomic.Value(u64)) void {
    const p = alloc.allocSentinel(u8, parent.len + 1 + name.len, 0) catch return;
    @memcpy(p[0..parent.len], parent);
    p[parent.len] = '/';
    @memcpy(p[parent.len + 1 ..], name);
    pool.push(.{ .path = p, .total = total });
}

fn processDir(pool: *Pool, job: Job, buf: []align(8) u8) void {
    if (builtin.os.tag == .macos) processDirBulk(pool, job, buf) else processDirPortable(pool, job);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn processDirBulk(pool: *Pool, job: Job, buf: []align(8) u8) void {
    const fd = std.c.open(job.path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var al = Attrlist{
        .bitmapcount = 5,
        .reserved = 0,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = ATTR_FILE_ALLOCSIZE,
        .forkattr = 0,
    };
    var sum: u64 = 0;
    while (true) {
        const count = getattrlistbulk(fd, &al, buf.ptr, buf.len, 0);
        if (count <= 0) break;
        var p: usize = 0;
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            const len = rd32(buf, p);
            var q = p + 4;
            const ret_common = rd32(buf, q);
            const ret_file = rd32(buf, q + 12);
            q += 20;
            var name: []const u8 = "";
            if (ret_common & ATTR_CMN_NAME != 0) {
                const off: i32 = @bitCast(rd32(buf, q));
                const nlen = rd32(buf, q + 4);
                const start: usize = @intCast(@as(isize, @intCast(q)) + off);
                name = buf[start .. start + nlen -| 1];
                q += 8;
            }
            var objtype: u32 = 0;
            if (ret_common & ATTR_CMN_OBJTYPE != 0) {
                objtype = rd32(buf, q);
                q += 4;
            }
            if (objtype == VDIR) {
                pushChild(pool, job.path, name, job.total);
            } else if (objtype == VREG and ret_file & ATTR_FILE_ALLOCSIZE != 0) {
                sum += std.mem.readInt(u64, buf[q..][0..8], .little);
            }
            p += len;
        }
    }
    _ = job.total.fetchAdd(sum, .monotonic);
}

fn processDirPortable(pool: *Pool, job: Job) void {
    const io = pool.io;
    var dir = std.Io.Dir.cwd().openDir(io, job.path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var sum: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        switch (e.kind) {
            .directory => pushChild(pool, job.path, e.name, job.total),
            .file => {
                const st = dir.statFile(io, e.name, .{}) catch continue;
                sum += st.size;
            },
            else => {},
        }
    }
    _ = job.total.fetchAdd(sum, .monotonic);
}
