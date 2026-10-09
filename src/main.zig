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
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const recorder_mod = @import("recorder.zig");
const source = @import("source.zig");
const view = @import("view.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

/// How often the window is drawn again, while values change.
const refresh_ns = 100 * std.time.ns_per_ms;

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
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
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ sys.system.user_dir, s.name_buf[0..s.name_len] }) catch {
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

fn run(init: std.process.Init.Minimal) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print(sys.log_error ++ "dazzle-data-logger: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var font_buf: [512]u8 = undefined;
    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, sys.fontFile(&font_buf, font.default_font_file), 32 * 1024 * 1024) catch break :blk null;
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

    var recorder = recorder_mod.Recorder.init(gpa);
    try recorder.start();
    defer recorder.deinit();
    var form: view.Form = .{};
    var actions: view.Actions = .{};
    var time: view.TimeView = .{};
    var live: [recorder_mod.max_tracks]view.Live = @splat(.{});
    var saver: Saver = .{};
    var message_buf: [160]u8 = undefined;
    var message: []const u8 = "";

    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var dirty = true;
    var idle = false;
    var suspended = false;
    var next_refresh: u64 = 0;
    while (true) {
        const waited = if (idle) blk: {
            const timeout: u64 = if (window_ui.needs_frame and !suspended) 16 * std.time.ns_per_ms else if (suspended) 60 * std.time.ns_per_s else next_refresh -| sys.nowNs() + std.time.ns_per_ms;
            break :blk win.wait(timeout);
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print(sys.log_error ++ "dazzle-data-logger: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) {
            recorder.stop();
            if (saver.thread) |t| t.join();
            return;
        }
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            dirty = true;
        }
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else dirty = true;
        }
        const now = sys.nowNs();
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };

        if (apply(&actions, &recorder, &form, &time, &saver, gpa, &message)) dirty = true;
        if (saver.finished()) {
            message = if (saver.err) |err|
                std.fmt.bufPrint(&message_buf, "It could not be saved ({s})", .{@errorName(err)}) catch ""
            else
                std.fmt.bufPrint(&message_buf, "Saved in your files as \u{201c}{s}\u{201d}", .{saver.name_buf[0..saver.name_len]}) catch "";
            dirty = true;
        }
        // The values now, and what is being recorded, a few times a second.
        if (!suspended and now >= next_refresh) {
            next_refresh = now + refresh_ns;
            if (recorder.mutex.tryLock()) {
                defer recorder.mutex.unlock();
                for (recorder.tracks[0..recorder.count], live[0..recorder.count]) |*t, *l| {
                    const was = l.*;
                    l.* = .{ .value = t.value, .failure = t.failure, .line = t.last_line };
                    if (!std.meta.eql(was.value, l.value) or !sameText(was.failure, l.failure) or was.line.len != l.line.len or was.line.at != l.line.at) dirty = true;
                }
            }
            if (recorder.isRecording()) {
                // The time line follows the recording.
                time.end = @max(recorder.seconds(), time.span);
                dirty = true;
            }
        }

        idle = true;
        if (!suspended and (dirty or window_ui.needs_frame)) {
            dirty = false;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Logger{
                .recorder = &recorder,
                .live = live[0..recorder.count],
                .form = &form,
                .actions = &actions,
                .time = time,
                .message = message,
                .saving = saver.busy(),
                .width = @floatFromInt(width),
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
                try win.showDamaged(damage[0..changed.len]);
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

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-data-logger: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Data Logger") catch |err| {
        print(sys.log_warning ++ "dazzle-data-logger: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-data-logger");
    return win;
}

test {
    _ = source;
    _ = recorder_mod;
    _ = view;
}
