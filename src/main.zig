//! Dazzle's Data Logger: records GPIO pins, analog inputs on I2C
//! converters, I2C devices' registers and serial ports, side by side on a
//! time line, as an audio editor records tracks (see view.zig). A thread
//! reads them all at the rate chosen (see recorder.zig); what is recorded
//! can be saved as CSV in the user's files. The GPIO button opens
//! Settings' GPIO page, to set the pins up.
//!
//!     dazzle-data-logger
//!
//! It runs until its window is closed.

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const recorder_mod = @import("recorder.zig");
const source = @import("source.zig");
const view = @import("view.zig");

const print = sys.print;

/// How often the window is drawn again, while values change.
const refresh_ns = 100 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-data-logger: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Saving a recording, on a thread of its own (it can be long).
const Saver = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    err: ?anyerror = null,

    fn start(s: *Saver, gpa: std.mem.Allocator, r: *recorder_mod.Recorder) void {
        const name = recorder_mod.fileName(&s.name_buf, realNow());
        s.name_len = name.len;
        s.err = null;
        s.done.store(false, .release);
        s.thread = std.Thread.spawn(.{}, save, .{ s, gpa, r }) catch |err| {
            s.err = err;
            s.done.store(true, .release);
            return;
        };
    }

    fn save(s: *Saver, gpa: std.mem.Allocator, r: *recorder_mod.Recorder) void {
        defer s.done.store(true, .release);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        r.writeCsv(&out.writer) catch |err| {
            s.err = err;
            return;
        };
        var path_buf: [128]u8 = undefined;
        const path = std.mem.printSentinel(&path_buf, "{s}/{s}", .{ sys.system.user_dir, s.name_buf[0..s.name_len] }, 0) catch {
            s.err = error.NameTooLong;
            return;
        };
        sys.files.writeNew(path, out.written()) catch |err| {
            s.err = err;
        };
    }

    fn busy(s: *const Saver) bool {
        return s.thread != null;
    }

    /// Whether it has finished (once).
    fn finished(s: *Saver) bool {
        const t = s.thread orelse return false;
        if (!s.done.load(.acquire)) return false;
        t.join();
        s.thread = null;
        return true;
    }
};

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.ptr == b.?.ptr;
}

fn realNow() i64 {
    return sys.realtimeSec();
}

/// The window's root: the logger as it is now.
const Root = struct {
    recorder: *const recorder_mod.Recorder,
    live: []const view.Live,
    form: *view.Form,
    actions: *view.Actions,
    time: *const view.TimeView,
    message: *const []const u8,
    saver: *const Saver,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        const width: f32 = if (cx.window()) |w| @floatFromInt(w.size()[0]) else 1280;
        return cx.make(view.Logger{
            .recorder = r.recorder,
            .live = r.live[0..r.recorder.count],
            .form = r.form,
            .actions = r.actions,
            .time = r.time.*,
            .message = r.message.*,
            .saving = r.saver.busy(),
            .width = width,
        });
    }
};

fn run(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-data-logger" });
    defer host.deinit();

    var recorder = recorder_mod.Recorder.init(gpa);
    try recorder.start();
    defer recorder.deinit();
    var form: view.Form = .{};
    var actions: view.Actions = .{};
    var time: view.TimeView = .{};
    var live: [recorder_mod.max_tracks]view.Live = @splat(.{});
    var saver: Saver = .{};
    defer {
        recorder.stop();
        if (saver.thread) |t| t.join();
    }
    var message_buf: [160]u8 = undefined;
    var message: []const u8 = "";

    const root: Root = .{ .recorder = &recorder, .live = &live, .form = &form, .actions = &actions, .time = &time, .message = &message, .saver = &saver };
    const window = try host.app.openWindow(.{
        .title = "Data Logger",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
    });

    var next_refresh: u64 = 0;
    while (try host.step(if (window.suspended) 60 * std.time.ns_per_s else next_refresh -| sys.nowNs() + std.time.ns_per_ms)) {
        const now = sys.nowNs();
        if (apply(&actions, &recorder, &form, &time, &saver, gpa, &message)) host.redraw();
        if (saver.finished()) {
            message = if (saver.err) |err|
                std.fmt.bufPrint(&message_buf, "It could not be saved ({s})", .{@errorName(err)}) catch ""
            else
                std.fmt.bufPrint(&message_buf, "Saved in your files as \u{201c}{s}\u{201d}", .{saver.name_buf[0..saver.name_len]}) catch "";
            host.redraw();
        }
        // The values now, and what is being recorded, a few times a second.
        if (!window.suspended and now >= next_refresh) {
            next_refresh = now + refresh_ns;
            if (recorder.mutex.tryLock()) {
                defer recorder.mutex.unlock();
                for (recorder.tracks[0..recorder.count], live[0..recorder.count]) |*t, *l| {
                    const was = l.*;
                    l.* = .{ .value = t.value, .failure = t.failure, .line = t.last_line };
                    if (!std.meta.eql(was.value, l.value) or !sameText(was.failure, l.failure) or was.line.len != l.line.len or was.line.at != l.line.at) host.redraw();
                }
            }
            if (recorder.isRecording()) {
                // The time line follows the recording.
                time.end = @max(recorder.seconds(), time.span);
                host.redraw();
            }
        }
    }
}

/// Does what the window asked. Returns whether anything changed.
fn apply(
    actions: *view.Actions,
    r: *recorder_mod.Recorder,
    form: *view.Form,
    time: *view.TimeView,
    saver: *Saver,
    gpa: std.mem.Allocator,
    message: *[]const u8,
) bool {
    const a = actions.*;
    actions.* = .{};
    var changed = false;
    if (a.record and !saver.busy()) {
        r.record();
        time.end = time.span;
        message.* = "";
        changed = true;
    }
    if (a.stop) {
        r.stop();
        changed = true;
    }
    if (a.clear) {
        r.clear();
        message.* = "";
        changed = true;
    }
    if (a.save and !saver.busy() and !r.isRecording()) {
        saver.start(gpa, r);
        changed = true;
    }
    if (a.open_gpio) {
        if (!sys.shell.open("dazzle-settings", "gpio")) message.* = "Settings could not be opened";
        changed = true;
    }
    if (a.dismiss_message) {
        message.* = "";
        changed = true;
    }
    if (a.rate) |rate| {
        r.setRate(rate);
        changed = true;
    }
    if (a.remove) |i| {
        r.remove(i);
        changed = true;
    }
    if (a.add) {
        switch (form.source_()) {
            .ok => |s| if (r.add(s, form.name.text())) {
                form.open = false;
                form.name.set("");
                var buf: [96]u8 = undefined;
                print("dazzle-data-logger: row {s}\n", .{s.describe(&buf)});
            } else |err| {
                form.failure = switch (err) {
                    error.TooMany => "there are as many rows as there can be",
                    error.Recording => "stop recording first",
                    else => "there is not enough memory",
                };
            },
            .bad => |why| form.failure = why,
        }
        changed = true;
    }
    if (a.zoom != 0) {
        const span = if (a.zoom > 0) time.span / 2 else time.span * 2;
        time.span = std.math.clamp(span, 0.01, 4 * 3600);
        changed = true;
    }
    if (a.pan != 0 or a.zoom != 0) {
        // Not before the start, nor (much) after the end.
        time.end = std.math.clamp(time.end + a.pan, time.span, @max(r.seconds(), time.span));
        changed = true;
    }
    return changed;
}

test {
    _ = source;
    _ = recorder_mod;
    _ = view;
}
