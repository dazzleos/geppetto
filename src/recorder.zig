//! The recorder: the rows (tracks) and what they have recorded. A thread
//! of its own reads every row at the rate chosen (a tick), all together,
//! and while recording keeps each value: one sample a row a tick, in
//! storage set aside when the row is added, so the window can draw what
//! has been recorded while more comes. Serial rows keep the lines that came
//! in instead, each with the tick it ended in. While not recording, the
//! rows are still read, a few times a second, for their values now.
//!
//! The rows change (added, removed) only while not recording; their live
//! values are read under `mutex`. What is recorded is published by the
//! counts (`samples`, a row's `event_count`): what is below them is written.

const std = @import("std");
const sys = @import("sys");
const source = @import("source.zig");

const Source = source.Source;
const Atomic = std.atomic.Value;

pub const max_tracks = 8;
/// The most samples a row keeps (at 100 a second, nearly three hours).
pub const capacity: u32 = 1 << 20;
/// The most lines a serial row keeps, and the longest kept.
pub const max_events = 4096;
pub const max_line = 120;
/// How often rows are read while not recording.
const idle_rate = 10;

pub const Event = struct {
    /// The tick it ended in.
    at: u32,
    len: u8 = 0,
    text_buf: [max_line]u8 = undefined,

    pub fn text(e: *const Event) []const u8 {
        return e.text_buf[0..e.len];
    }
};

pub const Track = struct {
    source: Source,
    name_buf: [40]u8 = undefined,
    name_len: u8 = 0,
    /// What it recorded (NaN where it could not be read), `capacity` long.
    samples: []f32 = &.{},
    /// A serial row's lines, `max_events` long, and how many there are.
    events: []Event = &.{},
    event_count: Atomic(u32) = .init(0),
    // Under the recorder's mutex:
    /// Its value now, if it could be read, and why not otherwise.
    value: ?f32 = null,
    failure: ?[]const u8 = null,
    /// A serial row's last line, and the one it is receiving.
    last_line: Event = .{ .at = 0 },
    line: Event = .{ .at = 0 },
    port: ?sys.serial.Port = null,

    pub fn name(t: *const Track) []const u8 {
        return t.name_buf[0..t.name_len];
    }

    pub fn setName(t: *Track, n: []const u8) void {
        t.name_len = @intCast(@min(n.len, t.name_buf.len));
        @memcpy(t.name_buf[0..t.name_len], n[0..t.name_len]);
    }

    /// The lines recorded so far.
    pub fn recordedEvents(t: *const Track) []const Event {
        return t.events[0..t.event_count.load(.acquire)];
    }
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    mutex: Lock = .{},
    tracks: [max_tracks]Track = undefined,
    count: usize = 0,
    /// Samples a second while recording.
    rate: u32 = 100,
    thread: ?std.Thread = null,
    stopping: Atomic(bool) = .init(false),
    recording: Atomic(bool) = .init(false),
    /// Ticks recorded: each row has this many samples.
    samples: Atomic(u32) = .init(0),
    /// Ticks the thread was too late for (the rows took too long to read).
    late: Atomic(u32) = .init(0),
    /// Recording stopped as there was no more room.
    full: Atomic(bool) = .init(false),
    /// The rate the recording was made at.
    recorded_rate: u32 = 100,
    // The sampler's:
    regs: ?sys.gpio.Registers = null,
    regs_failure: ?[]const u8 = null,
    bus: ?sys.i2c.Bus = null,
    bus_failure: ?[]const u8 = null,
    /// Read the hardware (false in tests, which give values by hand).
    hardware: bool = true,

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa };
    }

    /// Starts reading the rows, on a thread.
    pub fn start(r: *Recorder) !void {
        r.thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, run, .{r});
    }

    pub fn deinit(r: *Recorder) void {
        r.stopping.store(true, .release);
        if (r.thread) |t| t.join();
        while (r.count > 0) r.removeLocked(r.count - 1);
        if (r.regs) |*g| g.close();
        if (r.bus) |*b| b.close();
    }

    pub fn isRecording(r: *const Recorder) bool {
        return r.recording.load(.acquire);
    }

    pub fn sampleCount(r: *const Recorder) u32 {
        return r.samples.load(.acquire);
    }

    /// Adds a row (not while recording).
    pub fn add(r: *Recorder, s: Source, name: []const u8) !void {
        if (r.isRecording()) return error.Recording;
        r.mutex.lock();
        defer r.mutex.unlock();
        if (r.count == max_tracks) return error.TooMany;
        var t: Track = .{ .source = s };
        var buf: [40]u8 = undefined;
        t.setName(if (name.len > 0) name else s.defaultName(&buf));
        if (s == .serial) {
            t.events = try r.gpa.alloc(Event, max_events);
        } else {
            t.samples = try r.gpa.alloc(f32, capacity);
        }
        // Rows added after a recording have nothing for it.
        if (t.samples.len > 0) @memset(t.samples[0..r.samples.load(.acquire)], std.math.nan(f32));
        r.tracks[r.count] = t;
        r.count += 1;
    }

    /// Removes row `i` (not while recording).
    pub fn remove(r: *Recorder, i: usize) void {
        if (r.isRecording()) return;
        r.mutex.lock();
        defer r.mutex.unlock();
        r.removeLocked(i);
    }

    fn removeLocked(r: *Recorder, i: usize) void {
        if (i >= r.count) return;
        const t = &r.tracks[i];
        if (t.port) |*p| p.close();
        if (t.samples.len > 0) r.gpa.free(t.samples);
        if (t.events.len > 0) r.gpa.free(t.events);
        std.mem.copyForwards(Track, r.tracks[i .. r.count - 1], r.tracks[i + 1 .. r.count]);
        r.count -= 1;
    }

    /// Starts recording afresh.
    pub fn record(r: *Recorder) void {
        if (r.isRecording()) return;
        r.mutex.lock();
        defer r.mutex.unlock();
        r.samples.store(0, .release);
        for (r.tracks[0..r.count]) |*t| t.event_count.store(0, .release);
        r.late.store(0, .release);
        r.full.store(false, .release);
        r.recorded_rate = r.rate;
        r.recording.store(true, .release);
    }

    pub fn stop(r: *Recorder) void {
        r.recording.store(false, .release);
    }

    /// Forgets what was recorded.
    pub fn clear(r: *Recorder) void {
        if (r.isRecording()) return;
        r.mutex.lock();
        defer r.mutex.unlock();
        r.samples.store(0, .release);
        for (r.tracks[0..r.count]) |*t| t.event_count.store(0, .release);
    }

    pub fn setRate(r: *Recorder, rate: u32) void {
        if (r.isRecording()) return;
        r.rate = rate;
    }

    /// Seconds recorded.
    pub fn seconds(r: *const Recorder) f64 {
        return @as(f64, @floatFromInt(r.sampleCount())) / @as(f64, @floatFromInt(r.recorded_rate));
    }

    fn run(r: *Recorder) void {
        var next = sys.nowNs();
        while (!r.stopping.load(.acquire)) {
            const rate: u64 = if (r.isRecording()) r.recorded_rate else @min(r.rate, idle_rate);
            const period = std.time.ns_per_s / rate;
            next += period;
            const now = sys.nowNs();
            if (now > next + period) {
                // Behind: count the ticks missed, and go on from now.
                if (r.isRecording()) _ = r.late.fetchAdd(@intCast(@min((now - next) / period, 1000)), .monotonic);
                next = now;
            } else sys.sleepUntil(next);
            r.mutex.lock();
            defer r.mutex.unlock();
            r.tick();
        }
    }

    /// Reads every row once (holding the mutex); keeps the values if
    /// recording.
    pub fn tick(r: *Recorder) void {
        const recording = r.isRecording();
        const n = r.samples.load(.monotonic);
        var levels: ?sys.gpio.State = null;
        for (r.tracks[0..r.count]) |*t| {
            const v: ?f32 = switch (t.source) {
                .digital => |pin| blk: {
                    if (levels == null) levels = r.readLevels();
                    const l = levels orelse {
                        t.failure = r.regs_failure;
                        break :blk null;
                    };
                    break :blk if (l.level(pin)) 1 else 0;
                },
                .analog => |a| r.readI2c(t, a),
                .i2c => |reg| r.readI2c(t, reg),
                .serial => {
                    r.readSerial(t, recording, n);
                    continue;
                },
            };
            if (v != null) t.failure = null;
            t.value = v;
            if (recording) t.samples[n] = v orelse std.math.nan(f32);
        }
        if (recording) {
            r.samples.store(n + 1, .release);
            if (n + 1 == capacity) {
                r.full.store(true, .release);
                r.recording.store(false, .release);
            }
        }
    }

    fn readLevels(r: *Recorder) ?sys.gpio.State {
        if (!r.hardware) return null;
        if (r.regs == null and r.regs_failure == null) {
            r.regs = sys.gpio.Registers.open() catch |err| blk: {
                r.regs_failure = source.describeError(err);
                break :blk null;
            };
        }
        return if (r.regs) |*g| g.read() else null;
    }

    fn readI2c(r: *Recorder, t: *Track, what: anytype) ?f32 {
        if (!r.hardware) return t.value;
        if (r.bus == null) {
            r.bus = sys.i2c.Bus.open(sys.i2c.headerBus()) catch |err| {
                t.failure = source.describeError(err);
                return null;
            };
        }
        const bus = &r.bus.?;
        const v = switch (@TypeOf(what)) {
            source.Analog => source.readAnalog(bus, what),
            source.Register => source.readRegister(bus, what),
            else => unreachable,
        } catch |err| {
            t.failure = source.describeError(err);
            return null;
        };
        return v;
    }

    fn readSerial(r: *Recorder, t: *Track, recording: bool, n: u32) void {
        if (!r.hardware) return;
        const s = &t.source.serial;
        if (t.port == null) {
            t.port = sys.serial.Port.open(s.port(), s.baud) catch |err| {
                t.failure = source.describeError(err);
                return;
            };
            t.failure = null;
        }
        var buf: [512]u8 = undefined;
        while (true) {
            const got = t.port.?.read(&buf);
            if (got == 0) break;
            for (buf[0..got]) |c| r.serialByte(t, c, recording, n);
        }
    }

    /// A byte from a serial port: a line ends at a newline (a carriage
    /// return before it is dropped), or when it is as long as is kept.
    pub fn serialByte(r: *Recorder, t: *Track, c: u8, recording: bool, n: u32) void {
        _ = r;
        if (c == '\r') return;
        if (c != '\n') {
            t.line.text_buf[t.line.len] = if (c < 0x20 and c != '\t') '?' else c;
            t.line.len += 1;
            if (t.line.len < max_line) return;
        }
        t.line.at = n;
        t.last_line = t.line;
        t.line.len = 0;
        if (!recording) return;
        const i = t.event_count.load(.monotonic);
        if (i == max_events) return;
        t.events[i] = t.last_line;
        t.event_count.store(i + 1, .release);
    }

    // --- Saving ----------------------------------------------------------------

    /// Writes what was recorded as CSV: a column of times in seconds, and
    /// one a row (values; a serial row's lines in the tick they came, in
    /// quotes, several joined with " | ").
    pub fn writeCsv(r: *Recorder, w: *std.Io.Writer) !void {
        r.mutex.lock();
        defer r.mutex.unlock();
        const tracks = r.tracks[0..r.count];
        try w.writeAll("Time (s)");
        for (tracks) |*t| {
            try w.writeByte(',');
            const unit = t.source.unit();
            if (unit.len > 0) {
                var buf: [64]u8 = undefined;
                try writeQuoted(w, std.fmt.bufPrint(&buf, "{s} ({s})", .{ t.name(), unit }) catch t.name());
            } else try writeQuoted(w, t.name());
        }
        try w.writeByte('\n');
        // Where each serial row is in its lines.
        var next_event: [max_tracks]usize = @splat(0);
        const n = r.sampleCount();
        for (0..n) |i| {
            try w.print("{d:.3}", .{@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(r.recorded_rate))});
            for (tracks, 0..) |*t, ti| {
                try w.writeByte(',');
                switch (t.source) {
                    .serial => {
                        const events = t.recordedEvents();
                        var first = true;
                        while (next_event[ti] < events.len and events[next_event[ti]].at <= i) : (next_event[ti] += 1) {
                            try w.writeAll(if (first) "\"" else " | ");
                            first = false;
                            for (events[next_event[ti]].text()) |c| try if (c == '"') w.writeAll("\"\"") else w.writeByte(c);
                        }
                        if (!first) try w.writeByte('"');
                    },
                    .digital => if (!std.math.isNan(t.samples[i])) try w.print("{d}", .{@as(u1, @intFromFloat(t.samples[i]))}),
                    .analog => if (!std.math.isNan(t.samples[i])) try w.print("{d:.4}", .{t.samples[i]}),
                    .i2c => if (!std.math.isNan(t.samples[i])) try w.print("{d}", .{t.samples[i]}),
                }
            }
            try w.writeByte('\n');
        }
    }
};

/// A lock for the little the window and the sampler share: held briefly
/// (a tick), so waiting for it sleeps a little at a time.
pub const Lock = struct {
    held: Atomic(bool) = .init(false),

    pub fn tryLock(l: *Lock) bool {
        return l.held.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    pub fn lock(l: *Lock) void {
        while (!l.tryLock()) sys.sleepUs(50);
    }

    pub fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

fn writeQuoted(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |c| try if (c == '"') w.writeAll("\"\"") else w.writeByte(c);
    try w.writeByte('"');
}

/// A file name for a log made at `secs` (since 1970, UTC):
/// "Data log 2026-10-08 15.30.csv".
pub fn fileName(buf: []u8, secs: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(secs, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "Data log {d}-{d:0>2}-{d:0>2} {d:0>2}.{d:0>2}.{d:0>2}.csv", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "Data log.csv";
}

const testing = std.testing;

test "recording rows, a tick at a time; and saving them" {
    var r = Recorder.init(testing.allocator);
    r.hardware = false;
    defer r.deinit();
    try r.add(.{ .digital = 17 }, "");
    try r.add(.{ .analog = .{} }, "Light");
    try r.add(.{ .serial = .init("ttyUSB0", 9600) }, "");
    try testing.expectEqualStrings("GPIO 17", r.tracks[0].name());
    try testing.expectEqualStrings("Serial ttyUSB0", r.tracks[2].name());
    r.rate = 10;
    r.record();
    // Analog values as the converter would give them (by hand here).
    for (0..5) |i| {
        r.tracks[1].value = @as(f32, @floatFromInt(i)) * 0.5;
        if (i == 2) for ("hello\r\n") |c| r.serialByte(&r.tracks[2], c, true, r.sampleCount());
        if (i == 3) for ("a \"b\"\nc\n") |c| r.serialByte(&r.tracks[2], c, true, r.sampleCount());
        r.tick();
    }
    r.stop();
    try testing.expectEqual(@as(u32, 5), r.sampleCount());
    try testing.expectEqual(@as(f64, 0.5), r.seconds());
    try testing.expectEqual(@as(f32, 2.0), r.tracks[1].samples[4]);
    // No GPIO registers here: not read.
    try testing.expect(std.math.isNan(r.tracks[0].samples[0]));
    try testing.expectEqual(@as(usize, 3), r.tracks[2].recordedEvents().len);
    try testing.expectEqualStrings("c", r.tracks[2].last_line.text());
    // A row added after a recording: nothing recorded for it.
    try r.add(.{ .i2c = .{} }, "");
    try testing.expect(std.math.isNan(r.tracks[3].samples[4]));
    try r.add(.{ .serial = .init("ttyACM0", 9600) }, "");
    r.remove(4);
    r.remove(3);
    try testing.expectEqual(@as(usize, 3), r.count);
    // Rows cannot change while recording.
    r.record();
    try testing.expectError(error.Recording, r.add(.{ .digital = 4 }, ""));
    r.stop();
    r.clear();
    try testing.expectEqual(@as(u32, 0), r.sampleCount());

    r.record();
    for (0..3) |i| {
        r.tracks[1].value = @floatFromInt(i);
        if (i == 1) for ("x,\"y\"\nz\n") |c| r.serialByte(&r.tracks[2], c, true, r.sampleCount());
        r.tick();
    }
    r.stop();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try r.writeCsv(&out.writer);
    try testing.expectEqualStrings(
        \\Time (s),"GPIO 17","Light (V)","Serial ttyUSB0"
        \\0.000,,0.0000,
        \\0.100,,1.0000,"x,""y"" | z"
        \\0.200,,2.0000,
        \\
    , out.written());
}

test "a long line is cut into pieces as long as are kept" {
    var r = Recorder.init(testing.allocator);
    r.hardware = false;
    defer r.deinit();
    try r.add(.{ .serial = .init("ttyAMA0", 115200) }, "");
    r.record();
    for (0..max_line + 10) |_| r.serialByte(&r.tracks[0], 'a', true, 0);
    try testing.expectEqual(@as(usize, 1), r.tracks[0].recordedEvents().len);
    try testing.expectEqual(@as(usize, max_line), r.tracks[0].recordedEvents()[0].text().len);
    try testing.expectEqual(@as(u8, 10), r.tracks[0].line.len);
}

test "file names" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Data log 2026-10-08 15.30.05.csv", fileName(&buf, 1791473405));
}
