//! Fetching in the background on the app's `std.Io` (`zig build run-fetch`):
//! a button starts an HTTP request with `io.async`, which runs while the
//! UI waits in `app.step` (both on the same `Io`). When it is done it puts
//! what it found where the UI will look, and wakes the UI (`Shared.waker`)
//! to show it.

const std = @import("std");
const facet = @import("facet");

const url = "https://ziglang.org/download/index.json";

/// The fetch, shared by its task and the UI.
const Fetch = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    waker: facet.Waker,
    /// The task, while there is one (awaited once it says it is done).
    task: ?std.Io.Future(void) = null,
    /// What it found: written by the task, read by the UI.
    mutex: std.Io.Mutex = .init,
    status: Status = .idle,

    const Status = union(enum) {
        idle,
        fetching,
        fetched: struct { bytes: usize, ms: i64 },
        failed: []const u8,
    };

    fn start(f: *Fetch) void {
        if (f.task != null) return;
        f.set(.fetching);
        f.task = f.io.async(run, .{f});
    }

    /// Fetches `url` (on the `Io`, perhaps on another thread).
    fn run(f: *Fetch) void {
        const began = std.Io.Clock.awake.now(f.io);
        var client: std.http.Client = .{ .allocator = f.gpa, .io = f.io };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(f.gpa);
        defer body.deinit();
        const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |e| {
            return f.set(.{ .failed = @errorName(e) });
        };
        if (res.status != .ok) return f.set(.{ .failed = @tagName(res.status) });
        const ms = began.durationTo(std.Io.Clock.awake.now(f.io)).toMilliseconds();
        f.set(.{ .fetched = .{ .bytes = body.written().len, .ms = ms } });
    }

    fn set(f: *Fetch, status: Status) void {
        f.mutex.lockUncancelable(f.io);
        f.status = status;
        f.mutex.unlock(f.io);
        // The UI draws it (from any thread or task).
        f.waker.wake();
    }

    /// What it found, the task awaited (at once) once it is done.
    fn get(f: *Fetch) Status {
        f.mutex.lockUncancelable(f.io);
        const status = f.status;
        f.mutex.unlock(f.io);
        if (status != .fetching) if (f.task) |*t| {
            t.await(f.io);
            f.task = null;
        };
        return status;
    }

    fn deinit(f: *Fetch) void {
        if (f.task) |*t| t.cancel(f.io);
    }
};

const FetchView = struct {
    fetch: *Fetch,

    pub fn build(self: *const FetchView, cx: *facet.Context) facet.Widget {
        const status = self.fetch.get();
        const text = switch (status) {
            .idle => "Not fetched yet",
            .fetching => "Fetching…",
            .fetched => |r| cx.fmt("{d} bytes, in {d} ms", .{ r.bytes, r.ms }),
            .failed => |why| cx.fmt("Failed: {s}", .{why}),
        };
        return cx.make(facet.Center{ .child = cx.make(facet.Column{
            .main_axis_size = .min,
            .cross_axis_alignment = .center,
            .spacing = 16,
            .children = &.{
                cx.make(facet.Text{ .text = url }),
                cx.make(facet.Text{ .text = text }),
                cx.make(facet.FilledButton{
                    .label = "Fetch",
                    .icon = .download,
                    .on_press = if (status == .fetching) null else .of(self.fetch, Fetch.start),
                }),
            },
        }) });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try facet.App.init(init.gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();
    var fetch: Fetch = .{ .io = init.io, .gpa = init.gpa, .waker = app.shared.waker() };
    defer fetch.deinit();

    const root = FetchView{ .fetch = &fetch };
    _ = try app.openWindow(.{
        .title = "Fetch in the background",
        .root = .of(&root),
        .size = .{ 560, 320 },
        .on_close_request = .close,
    });
    try app.run();
}
