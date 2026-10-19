//! Loading images in the background, for `Image`: from files, URLs
//! (`http://`, `https://`, `file://`, `data:`), or a file's bytes; PNG or
//! JPEG, made smaller to fit `gfx.Image.max_size` if they are bigger.
//!
//! Loads are done by up to `max_workers` threads, which wake the UI when
//! one is done (`wakeFd`), and the UI takes what is done (`collect`). An
//! image is kept while it shows, and for `keep_ns` after it last did, so
//! one shown again soon is not loaded again.

const std = @import("std");
const linux = std.os.linux;
const gfx = @import("gfx");

/// Shared with the workers, so thread-safe.
const alloc = std.heap.smp_allocator;

pub const max_workers = 4;
pub const keep_ns = 30 * std.time.ns_per_s;

/// Where an image comes from.
pub const Source = union(enum) {
    /// Pixels in memory, shown at once (they must last as long as they
    /// show).
    image: *const gfx.Image,
    /// A PNG or JPEG file.
    file: []const u8,
    /// `http://`, `https://`, `file://`, or `data:` (base64 or not).
    url: []const u8,
    /// A PNG or JPEG file's bytes, copied (and known by where they are: the
    /// same place with other bytes is not loaded again).
    bytes: []const u8,
};

/// How loading an image is going.
pub const Status = union(enum) {
    loading,
    ready: *const gfx.Image,
    failed,
};

pub const Cache = struct {
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    shared: ?*Shared = null,

    const Entry = struct {
        key: []u8,
        status: enum { loading, ready, failed } = .loading,
        pixels: []u32 = &.{},
        image: gfx.Image = undefined,
        last_used_ns: u64,
    };

    pub fn deinit(c: *Cache) void {
        var it = c.entries.valueIterator();
        while (it.next()) |e| free(e.*);
        c.entries.deinit(alloc);
        if (c.shared) |s| s.close();
        c.* = .{};
    }

    fn free(e: *Entry) void {
        alloc.free(e.pixels);
        alloc.free(e.key);
        alloc.destroy(e);
    }

    /// How loading `source` is going, starting it if it has not been.
    pub fn get(c: *Cache, source: Source, now_ns: u64) Status {
        if (source == .image) return .{ .ready = source.image };
        var key_buf: [64]u8 = undefined;
        const key = keyOf(source, &key_buf);
        if (c.entries.get(key)) |e| {
            e.last_used_ns = now_ns;
            return switch (e.status) {
                .loading => .loading,
                .ready => .{ .ready = &e.image },
                .failed => .failed,
            };
        }
        const e = c.start(source, key, now_ns) catch return .failed;
        return if (e.status == .failed) .failed else .loading;
    }

    fn keyOf(source: Source, buf: []u8) []const u8 {
        return switch (source) {
            .image => unreachable,
            .file => |p| p,
            .url => |u| u,
            // Not a path or URL: those start "/", or a scheme.
            .bytes => |b| std.fmt.bufPrint(buf, ":bytes:{x}:{d}", .{ @intFromPtr(b.ptr), b.len }) catch unreachable,
        };
    }

    fn start(c: *Cache, source: Source, key: []const u8, now_ns: u64) !*Entry {
        const e = try alloc.create(Entry);
        errdefer alloc.destroy(e);
        e.* = .{ .key = try alloc.dupe(u8, key), .last_used_ns = now_ns };
        errdefer alloc.free(e.key);
        try c.entries.put(alloc, e.key, e);
        errdefer _ = c.entries.remove(e.key);
        const job = try alloc.create(Job);
        errdefer alloc.destroy(job);
        job.* = .{
            .key = try alloc.dupe(u8, key),
            .what = switch (source) {
                .image => unreachable,
                .file => |p| .{ .file = try alloc.dupe(u8, p) },
                .url => |u| .{ .url = try alloc.dupe(u8, u) },
                .bytes => |b| .{ .bytes = try alloc.dupe(u8, b) },
            },
        };
        if (c.shared == null) c.shared = try Shared.create();
        c.shared.?.add(job) catch {
            job.deinit();
            e.status = .failed;
        };
        return e;
    }

    /// The fd that is readable when a load is done (to wait on with the
    /// window's), once any has started.
    pub fn wakeFd(c: *const Cache) ?linux.fd_t {
        return if (c.shared) |s| s.fd else null;
    }

    /// Takes the loads that are done; true if there were any.
    pub fn collect(c: *Cache) bool {
        const s = c.shared orelse return false;
        var buf: [8]u8 = undefined;
        _ = linux.read(s.fd, &buf, buf.len);
        var any = false;
        while (true) {
            s.lock();
            const job = s.done.pop() orelse {
                s.unlock();
                break;
            };
            s.unlock();
            defer job.deinit();
            any = true;
            const e = c.entries.get(job.key) orelse continue;
            if (job.result) |r| {
                e.pixels = r.pixels;
                e.image = .init(r.pixels, r.width, r.height);
                e.status = .ready;
                job.result = null;
            } else e.status = .failed;
        }
        return any;
    }

    /// Lets go of images not shown for `keep_ns` (not those loading).
    pub fn evict(c: *Cache, now_ns: u64) void {
        var it = c.entries.iterator();
        var stale: [16][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (e.status == .loading or now_ns -| e.last_used_ns < keep_ns) continue;
            stale[n] = kv.key_ptr.*;
            n += 1;
            if (n == stale.len) break;
        }
        for (stale[0..n]) |key| if (c.entries.fetchRemove(key)) |kv| free(kv.value);
    }
};

/// What a load needs, and what it made.
const Job = struct {
    key: []u8,
    what: union(enum) { file: []u8, url: []u8, bytes: []u8 },
    result: ?Decoded = null,

    fn deinit(j: *Job) void {
        alloc.free(j.key);
        switch (j.what) {
            inline else => |b| alloc.free(b),
        }
        if (j.result) |r| alloc.free(r.pixels);
        alloc.destroy(j);
    }
};

const Decoded = gfx.png.Decoded;

/// The loads waiting and done, shared by the UI and the workers: freed by
/// whichever lets go of it last.
const Shared = struct {
    mutex: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(*Job) = .empty,
    done: std.ArrayList(*Job) = .empty,
    workers: u8 = 0,
    /// The UI and each worker.
    refs: u32 = 1,
    closed: bool = false,
    fd: linux.fd_t,

    fn create() !*Shared {
        const rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const s = try alloc.create(Shared);
        s.* = .{ .fd = @intCast(rc) };
        return s;
    }

    fn lock(s: *Shared) void {
        while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(s: *Shared) void {
        s.mutex.unlock();
    }

    /// Queues a load, with a worker for it if there are fewer than
    /// `max_workers`.
    fn add(s: *Shared, job: *Job) !void {
        s.lock();
        defer s.unlock();
        try s.pending.append(alloc, job);
        if (s.workers < max_workers) {
            s.workers += 1;
            s.refs += 1;
            const t = std.Thread.spawn(.{}, work, .{s}) catch {
                s.workers -= 1;
                s.refs -= 1;
                _ = s.pending.pop();
                return error.SystemResources;
            };
            t.detach();
        }
    }

    /// The UI lets go of it: what is waiting is dropped, and what finishes
    /// is freed as it does.
    fn close(s: *Shared) void {
        s.lock();
        s.closed = true;
        for (s.pending.items) |j| j.deinit();
        s.pending.clearRetainingCapacity();
        for (s.done.items) |j| j.deinit();
        s.done.clearRetainingCapacity();
        s.release();
    }

    /// Lets go of a reference (locked; unlocks, or frees it).
    fn release(s: *Shared) void {
        s.refs -= 1;
        if (s.refs > 0) return s.unlock();
        s.pending.deinit(alloc);
        s.done.deinit(alloc);
        _ = linux.close(s.fd);
        alloc.destroy(s);
    }

    fn work(s: *Shared) void {
        var http: ?*Http = null;
        defer if (http) |h| h.destroy();
        while (true) {
            s.lock();
            if (s.pending.items.len == 0 or s.closed) {
                s.workers -= 1;
                return s.release();
            }
            const job = s.pending.orderedRemove(0);
            s.unlock();
            job.result = load(job, &http);
            s.lock();
            if (s.closed) {
                job.deinit();
            } else if (s.done.append(alloc, job)) {
                const one: u64 = 1;
                _ = linux.write(s.fd, std.mem.asBytes(&one), 8);
            } else |_| job.deinit();
            s.unlock();
        }
    }
};

/// A worker's HTTP client (made for its first URL).
const Http = struct {
    threaded: std.Io.Threaded,
    client: std.http.Client,

    fn create() ?*Http {
        const h = alloc.create(Http) catch return null;
        h.threaded = .init(alloc, .{});
        h.client = .{ .allocator = alloc, .io = h.threaded.io() };
        return h;
    }

    fn destroy(h: *Http) void {
        h.client.deinit();
        h.threaded.deinit();
        alloc.destroy(h);
    }

    fn get(h: *Http, url: []const u8) ?[]u8 {
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        const res = h.client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch return null;
        if (res.status != .ok) return null;
        return body.toOwnedSlice() catch null;
    }
};

/// Fetches and decodes a job's image (in a worker).
fn load(job: *const Job, http: *?*Http) ?Decoded {
    const data: []u8 = switch (job.what) {
        .bytes => |b| return decodeFit(b),
        .file => |p| readFile(p) orelse return null,
        .url => |u| fetch(u, http) orelse return null,
    };
    defer alloc.free(data);
    return decodeFit(data);
}

fn fetch(url: []const u8, http: *?*Http) ?[]u8 {
    if (std.mem.startsWith(u8, url, "file://")) {
        const path = percentDecoded(url["file://".len..]) orelse return null;
        defer alloc.free(path);
        return readFile(path);
    }
    if (std.mem.startsWith(u8, url, "data:")) return dataUrl(url);
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) {
        if (http.* == null) http.* = Http.create();
        return (http.* orelse return null).get(url);
    }
    return null;
}

/// A `data:` URL's bytes: `data:image/png;base64,iVBOR...`.
fn dataUrl(url: []const u8) ?[]u8 {
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return null;
    const meta = url["data:".len..comma];
    const payload = url[comma + 1 ..];
    if (std.mem.endsWith(u8, meta, ";base64")) {
        const trimmed = std.mem.trimEnd(u8, payload, "=");
        const out = alloc.alloc(u8, std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return null) catch return null;
        std.base64.standard_no_pad.Decoder.decode(out, trimmed) catch {
            alloc.free(out);
            return null;
        };
        return out;
    }
    return percentDecoded(payload);
}

/// `%41` → `A`.
fn percentDecoded(s: []const u8) ?[]u8 {
    const out = alloc.alloc(u8, s.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
            out[n] = b;
            n += 1;
            i += 2;
            continue;
        } else |_| {};
        out[n] = s[i];
        n += 1;
    }
    defer alloc.free(out);
    return alloc.dupe(u8, out[0..n]) catch null;
}

fn readFile(path: []const u8) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    const rc = linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    while (out.items.len < 256 << 20) {
        out.ensureUnusedCapacity(alloc, 256 << 10) catch {
            out.deinit(alloc);
            return null;
        };
        const n = linux.read(fd, out.unusedCapacitySlice().ptr, out.unusedCapacitySlice().len);
        if (linux.errno(n) != .SUCCESS) {
            out.deinit(alloc);
            return null;
        }
        if (n == 0) break;
        out.items.len += n;
    }
    return out.toOwnedSlice(alloc) catch null;
}

/// A PNG or JPEG decoded, made smaller if it is bigger than the GPU takes.
fn decodeFit(data: []const u8) ?Decoded {
    const img = (if (gfx.jpeg.is(data))
        gfx.jpeg.decode(alloc, data)
    else
        gfx.png.decode(alloc, data)) catch return null;
    const max = gfx.Image.max_size;
    if (img.width <= max and img.height <= max) return img;
    defer alloc.free(img.pixels);
    return shrink(img, max) catch null;
}

/// `img` made to fit within `max` across and down, each pixel the average
/// of those it covers.
fn shrink(img: Decoded, max: u32) !Decoded {
    const scale = @max(@as(f64, @floatFromInt(img.width)) / @as(f64, @floatFromInt(max)), @as(f64, @floatFromInt(img.height)) / @as(f64, @floatFromInt(max)));
    const w: u32 = @intCast(@max(1, @min(max, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.width)) / scale))))));
    const h: u32 = @intCast(@max(1, @min(max, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(img.height)) / scale))))));
    const out = try alloc.alloc(u32, @as(usize, w) * h);
    for (0..h) |y| {
        const y0 = y * img.height / h;
        const y1 = @max(y0 + 1, (y + 1) * img.height / h);
        for (0..w) |x| {
            const x0 = x * img.width / w;
            const x1 = @max(x0 + 1, (x + 1) * img.width / w);
            var sum: [4]u64 = @splat(0);
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const p = img.pixels[sy * img.width + sx];
                for (&sum, 0..) |*s, i| s.* += (p >> @intCast(i * 8)) & 0xff;
            };
            const count = (y1 - y0) * (x1 - x0);
            var px: u32 = 0;
            for (sum, 0..) |s, i| px |= @as(u32, @intCast(s / count)) << @intCast(i * 8);
            out[y * w + x] = px;
        }
    }
    return .{ .pixels = out, .width = w, .height = h };
}
