//! The Data Logger's window, as widgets: like an audio editor's, a row a
//! source, one above the other on a shared time line. Each row has its
//! name, what it reads and its value now on the left, and what it has
//! recorded drawn to the right (a digital pin's highs and lows, a
//! number's line, or a serial port's lines as marks). Along the top are
//! Record and Stop, the rate, zoom, Save and a button to Settings' GPIO
//! page; along the bottom, Add row, which opens a form for the source.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const sys = @import("sys");
const recorder_mod = @import("recorder.zig");
const source = @import("source.zig");

const Recorder = recorder_mod.Recorder;
const Track = recorder_mod.Track;
const Source = source.Source;

pub const min_size = [2]u32{ 720, 480 };

/// The size the window opens at: the readings beside a chart.
pub const open_size = [2]u32{ 1024, 680 };

/// The width of the rows' headers.
const header_width = 240;
const row_height = 96;

/// The rows' colours, in turn.
const palette = [_]gfx.Color{ .rgb(0x4fc3f7), .rgb(0xaed581), .rgb(0xffb74d), .rgb(0xf06292), .rgb(0xba68c8), .rgb(0x4db6ac), .rgb(0xfff176), .rgb(0x90a4ae) };

/// What the window asks for, done between frames (see main.zig).
pub const Actions = struct {
    record: bool = false,
    stop: bool = false,
    clear: bool = false,
    save: bool = false,
    open_gpio: bool = false,
    add: bool = false,
    remove: ?usize = null,
    rate: ?u32 = null,
    /// Zoom in (+1) or out (-1); pan by seconds.
    zoom: i8 = 0,
    pan: f32 = 0,
    dismiss_message: bool = false,

    fn doRecord(a: *Actions) void {
        a.record = true;
    }
    fn doStop(a: *Actions) void {
        a.stop = true;
    }
    fn doClear(a: *Actions) void {
        a.clear = true;
    }
    fn doSave(a: *Actions) void {
        a.save = true;
    }
    fn doOpenGpio(a: *Actions) void {
        a.open_gpio = true;
    }
    fn doZoomIn(a: *Actions) void {
        a.zoom = 1;
    }
    fn doZoomOut(a: *Actions) void {
        a.zoom = -1;
    }
    fn setRate(a: *Actions, r: u32) void {
        a.rate = r;
    }
    fn doPan(a: *Actions, seconds: f32) void {
        a.pan += seconds;
    }
    fn doDismissMessage(a: *Actions) void {
        a.dismiss_message = true;
    }
};

/// The form for a new row.
pub const Form = struct {
    pub const Kind = enum { digital, analog, i2c, serial };

    pub const Field = struct {
        buf: [40]u8 = undefined,
        len: u8 = 0,

        pub fn init(t: []const u8) Field {
            var f: Field = .{};
            f.set(t);
            return f;
        }

        pub fn text(f: *const Field) []const u8 {
            return f.buf[0..f.len];
        }

        pub fn set(f: *Field, t: []const u8) void {
            var n = @min(t.len, f.buf.len);
            while (n > 0 and n < t.len and t[n] & 0xc0 == 0x80) n -= 1;
            f.len = @intCast(n);
            @memcpy(f.buf[0..f.len], t[0..f.len]);
        }
    };

    open: bool = false,
    kind: Kind = .digital,
    name: Field = .{},
    pin: Field = .init("17"),
    address: Field = .init("0x48"),
    register: Field = .init("0x00"),
    converter: source.Converter = .ads1x15,
    channel: u2 = 0,
    width: u8 = 1,
    signed: bool = false,
    ports: sys.serial.Ports = .{},
    port: usize = 0,
    baud: u32 = 115200,
    /// Why the row could not be added.
    failure: ?[]const u8 = null,
    /// Changes each time the form opens, so its fields start afresh.
    generation: u32 = 0,

    pub const bauds = [_]u32{ 9600, 19200, 38400, 57600, 115200 };

    /// The source the form describes, or why it is not one.
    pub fn source_(f: *const Form) union(enum) { ok: Source, bad: []const u8 } {
        switch (f.kind) {
            .digital => {
                const pin = source.parseNumber(u6, f.pin.text()) orelse return .{ .bad = "the GPIO number should be from 0 to 53" };
                if (pin > 53) return .{ .bad = "the GPIO number should be from 0 to 53" };
                return .{ .ok = .{ .digital = pin } };
            },
            .analog => {
                const addr = source.parseNumber(u7, f.address.text()) orelse return .{ .bad = "the address should be from 0x03 to 0x77" };
                return .{ .ok = .{ .analog = .{ .converter = f.converter, .address = addr, .channel = f.channel } } };
            },
            .i2c => {
                const addr = source.parseNumber(u7, f.address.text()) orelse return .{ .bad = "the address should be from 0x03 to 0x77" };
                const reg = source.parseNumber(u8, f.register.text()) orelse return .{ .bad = "the register should be from 0x00 to 0xff" };
                return .{ .ok = .{ .i2c = .{ .address = addr, .register = reg, .width = f.width, .signed = f.signed } } };
            },
            .serial => {
                if (f.port >= f.ports.count) return .{ .bad = "there is no serial port to read" };
                return .{ .ok = .{ .serial = .init(f.ports.name(f.port), f.baud) } };
            },
        }
    }

    fn setKind(f: *Form, k: Kind) void {
        f.kind = k;
        f.failure = null;
    }
    fn setName(f: *Form, t: []const u8) void {
        f.name.set(t);
    }
    fn setPin(f: *Form, t: []const u8) void {
        f.pin.set(t);
    }
    fn setAddress(f: *Form, t: []const u8) void {
        f.address.set(t);
    }
    fn setRegister(f: *Form, t: []const u8) void {
        f.register.set(t);
    }
    fn setConverter(f: *Form, c: source.Converter) void {
        f.converter = c;
        // Each has its own usual address.
        f.address.set("0x48");
    }
    fn setChannel(f: *Form, c: u2) void {
        f.channel = c;
    }
    fn setWidth(f: *Form, w: u8) void {
        f.width = w;
    }
    fn setSigned(f: *Form, s: bool) void {
        f.signed = s;
    }
    fn setPort(f: *Form, i: usize) void {
        f.port = i;
    }
    fn setBaud(f: *Form, b: u32) void {
        f.baud = b;
    }
    fn show(f: *Form) void {
        f.open = true;
        f.failure = null;
        f.generation +%= 1;
        f.ports = sys.serial.ports();
        if (f.port >= f.ports.count) f.port = 0;
    }
    fn hide(f: *Form) void {
        f.open = false;
    }
};

/// A row's value now, and why it cannot be read (copied from the recorder
/// for the frame).
pub const Live = struct {
    value: ?f32 = null,
    failure: ?[]const u8 = null,
    line: recorder_mod.Event = .{ .at = 0 },
};

/// What part of the recording shows: `span` seconds, ending at `end`.
pub const TimeView = struct {
    span: f64 = 10,
    end: f64 = 10,
};

pub const Logger = struct {
    recorder: *const Recorder,
    live: []const Live,
    form: *Form,
    actions: *Actions,
    time: TimeView,
    /// What happened last (saved, or why not).
    message: []const u8 = "",
    saving: bool = false,
    /// The window's width (narrow windows have fewer words).
    width: f32 = 1280,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub fn build(self: *const Logger, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const r = self.recorder;
        const a = cx.ui.arena();
        var rows: std.ArrayList(ui.Widget) = .empty;
        // The time line, above the rows.
        rows.append(a, cx.make(ui.Row{ .children = &.{
            cx.make(ui.SizedBox{ .width = header_width }),
            cx.make(ui.Expanded{ .child = cx.make(Ruler{ .t0 = self.time.end - self.time.span, .span = self.time.span }) }),
        } })) catch {};
        for (r.tracks[0..r.count], 0..) |*track, i| rows.append(a, self.row(cx, track, i)) catch {};
        if (r.count == 0) rows.append(a, cx.make(ui.Padding{ .padding = .all(24), .child = cx.make(ui.Text{
            .text = "Add a row for each thing to record: a GPIO pin, an analog input on an I2C converter, a register of an I2C device, or a serial port.",
            .style = .{ .size = 18, .color = t.on_surface_variant },
        }) })) catch {};
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Data Logger",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 8 }, .child = self.toolbar(cx) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Snackbar{
                .message = self.message,
                .on_dismiss = .of(self.actions, Actions.doDismissMessage),
                .child = cx.make(ui.ScrollView{ .child = cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16 }, .child = cx.make(ui.Column{
                    .cross_axis_alignment = .stretch,
                    .main_axis_size = .min,
                    .spacing = 6,
                    .children = rows.items,
                }) }) }),
            }) }),
            cx.make(ui.Padding{ .padding = .{ .left = 16, .right = 16, .top = 8, .bottom = 12 }, .child = self.bottom(cx) }),
        } });
    }

    fn toolbar(self: *const Logger, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const r = self.recorder;
        const recording = r.isRecording();
        const acts = self.actions;
        const a = cx.ui.arena();
        // In a narrow window, the buttons are their icons alone (Record
        // and Stop too, in the narrowest).
        const labels = self.width >= 1000;
        const narrowest = self.width < 800;
        var items: std.ArrayList(ui.Widget) = .empty;
        items.append(a, if (recording)
            cx.make(ui.OutlinedButton{ .label = if (narrowest) "" else "Stop", .icon = .stop, .on_press = .of(acts, Actions.doStop) })
        else
            cx.make(ui.OutlinedButton{ .label = if (narrowest) "" else "Record", .icon = .fiber_manual_record, .on_press = if (r.count > 0 and !self.saving) .of(acts, Actions.doRecord) else null })) catch {};
        var time_buf: [32]u8 = undefined;
        const late = r.late.load(.monotonic);
        const status = if (r.full.load(.monotonic))
            cx.fmt("{s}: full", .{formatDuration(&time_buf, r.seconds())})
        else if (late > 0)
            cx.fmt("{s} ({d} samples late)", .{ formatDuration(&time_buf, r.seconds()), late })
        else
            cx.fmt("{s}", .{formatDuration(&time_buf, r.seconds())});
        items.append(a, cx.make(ui.SizedBox{ .width = 110, .child = cx.make(ui.Text{ .text = status, .style = .{ .size = 16, .color = if (recording) t.@"error" else t.on_surface }, .wrap = false, .ellipsis = true }) })) catch {};
        const rate = if (recording) r.recorded_rate else r.rate;
        const rate_options = [_]ui.Select(u32).Option{
            .{ .value = 1, .label = "1 sample a second" },
            .{ .value = 10, .label = "10 samples a second" },
            .{ .value = 100, .label = "100 samples a second" },
            .{ .value = 1000, .label = "1000 samples a second" },
        };
        items.append(a, cx.make(ui.Select(u32){
            .options = &rate_options,
            .value = rate,
            .label = cx.fmt("{d} / s", .{rate}),
            .on_changed = if (!recording) .of(acts, Actions.setRate) else null,
        })) catch {};
        items.append(a, cx.make(ui.Expanded{ .child = cx.make(ui.Empty{}) })) catch {};
        items.appendSlice(a, &.{
            cx.make(ui.OutlinedButton{ .icon = .zoom_out, .on_press = .of(acts, Actions.doZoomOut) }),
            cx.make(ui.OutlinedButton{ .icon = .zoom_in, .on_press = .of(acts, Actions.doZoomIn) }),
            cx.make(ui.OutlinedButton{ .label = if (labels) "Clear" else "", .icon = .delete_sweep, .destructive = true, .on_press = if (!recording and r.sampleCount() > 0) .of(acts, Actions.doClear) else null }),
            cx.make(ui.OutlinedButton{ .label = if (labels) "Save" else "", .icon = .save, .on_press = if (!recording and !self.saving and r.sampleCount() > 0) .of(acts, Actions.doSave) else null }),
            cx.make(ui.OutlinedButton{ .label = if (labels) "GPIO settings" else "", .icon = .settings_input_component, .on_press = .of(acts, Actions.doOpenGpio) }),
        }) catch {};
        return cx.make(ui.Row{ .spacing = 8, .cross_axis_alignment = .center, .children = items.items });
    }

    /// A row: its header (name, what it reads, its value now) and its plot.
    fn row(self: *const Logger, cx: *ui.Context, track: *const Track, i: usize) ui.Widget {
        const t = cx.theme();
        const colour = palette[i % palette.len];
        const live = if (i < self.live.len) self.live[i] else Live{};
        var desc_buf: [96]u8 = undefined;
        var value_buf: [64]u8 = undefined;
        const now: []const u8, const failed = if (live.failure) |why| .{ cx.fmt("Cannot read: {s}", .{why}), true } else .{ cx.fmt("{s}", .{formatValue(&value_buf, &track.source, live)}), false };
        const remove = cx.ui.arena().create(Remove) catch return cx.make(ui.Empty{});
        remove.* = .{ .actions = self.actions, .index = i };
        const header = cx.make(ui.SizedBox{ .width = header_width, .height = row_height, .child = cx.make(ui.Padding{ .padding = .{ .right = 8, .top = 4 }, .child = cx.make(ui.Row{ .cross_axis_alignment = .start, .spacing = 8, .children = &.{
            cx.make(ui.SizedBox{ .width = 4, .height = row_height - 12, .child = cx.make(ui.Decorated{ .color = colour, .radius = .all(2) }) }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 2, .children = &.{
                cx.make(ui.Text{ .text = track.name(), .style = .{ .size = 16, .color = t.on_surface }, .wrap = false, .ellipsis = true }),
                cx.make(ui.Text{ .text = cx.fmt("{s}", .{track.source.describe(&desc_buf)}), .style = .{ .size = 12, .color = t.on_surface_variant }, .wrap = false, .ellipsis = true }),
                cx.make(ui.Text{ .text = now, .style = .{ .size = if (failed) 13 else 18, .color = if (failed) t.@"error" else colour }, .wrap = failed, .ellipsis = !failed }),
            } }) }),
            cx.make(ui.OutlinedButton{ .icon = .delete, .destructive = true, .on_press = if (self.recorder.isRecording()) null else .of(remove, Remove.press) }),
        } }) }) });
        return cx.make(ui.Row{ .cross_axis_alignment = .stretch, .children = &.{
            header,
            cx.make(ui.Expanded{ .child = cx.make(Plot{
                .track = track,
                .samples = self.recorder.sampleCount(),
                .rate = self.recorder.recorded_rate,
                .t0 = self.time.end - self.time.span,
                .span = self.time.span,
                .colour = colour,
                .on_pan = .of(self.actions, Actions.doPan),
            }) }),
        } });
    }

    fn bottom(self: *const Logger, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const f = self.form;
        const can_add = !self.recorder.isRecording() and self.recorder.count < recorder_mod.max_tracks;
        if (!f.open or !can_add) return cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
            cx.make(ui.OutlinedButton{ .label = "Add row", .icon = .add, .on_press = if (can_add) .of(f, Form.show) else null }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Text{
                .text = if (self.saving) "Saving\u{2026}" else if (self.recorder.isRecording()) "Rows can be added and removed when not recording" else "",
                .style = .{ .size = 15, .color = t.on_surface_variant },
                .wrap = false,
                .ellipsis = true,
            }) }),
        } });
        return cx.make(ui.Card{ .variant = .filled, .child = self.form_(cx).withKey(f.generation) });
    }

    /// The form for a new row: what kind of source, where it is, and a
    /// name.
    fn form_(self: *const Logger, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const f = self.form;
        const a = cx.ui.arena();
        const label: ui.TextStyle = .{ .size = 15, .color = t.on_surface_variant };
        var lines: std.ArrayList(ui.Widget) = .empty;
        const kinds = [_]struct { Form.Kind, []const u8 }{ .{ .digital, "Digital input" }, .{ .analog, "Analog input" }, .{ .i2c, "I2C register" }, .{ .serial, "Serial port" } };
        var kind_row: std.ArrayList(ui.Widget) = .empty;
        for (kinds) |k| kind_row.append(a, cx.make(ui.Radio(Form.Kind){ .value = k[0], .group_value = f.kind, .label = k[1], .on_changed = .of(f, Form.setKind) })) catch {};
        lines.append(a, cx.make(ui.Row{ .spacing = 16, .children = kind_row.items })) catch {};
        switch (f.kind) {
            .digital => lines.append(a, cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Text{ .text = "GPIO", .style = label, .wrap = false }),
                cx.make(ui.TextField{ .initial = f.pin.text(), .width = 80, .max_len = 4, .on_changed = .of(f, Form.setPin) }),
                cx.make(ui.Expanded{ .child = cx.make(ui.Text{ .text = "Its number, not the pin's (GPIO 17 is pin 11). Set it up as an input in Settings, with a pull if it needs one.", .style = label }) }),
            } })) catch {},
            .analog => {
                var conv: std.ArrayList(ui.Widget) = .empty;
                conv.append(a, cx.make(ui.Text{ .text = "Converter", .style = label, .wrap = false })) catch {};
                for (std.enums.values(source.Converter)) |c| conv.append(a, cx.make(ui.Radio(source.Converter){ .value = c, .group_value = f.converter, .label = c.label(), .on_changed = .of(f, Form.setConverter) })) catch {};
                lines.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = conv.items })) catch {};
                var chan: std.ArrayList(ui.Widget) = .empty;
                chan.appendSlice(a, &.{
                    cx.make(ui.Text{ .text = "Address", .style = label, .wrap = false }),
                    cx.make(ui.TextField{ .initial = f.address.text(), .width = 80, .max_len = 4, .on_changed = .of(f, Form.setAddress) }),
                    cx.make(ui.Text{ .text = "Input", .style = label, .wrap = false }),
                }) catch {};
                for (0..4) |c| chan.append(a, cx.make(ui.Radio(u2){ .value = @intCast(c), .group_value = f.channel, .label = cx.fmt("A{d}", .{c}), .on_changed = .of(f, Form.setChannel) })) catch {};
                lines.append(a, cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = chan.items })) catch {};
            },
            .i2c => lines.append(a, cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
                cx.make(ui.Text{ .text = "Address", .style = label, .wrap = false }),
                cx.make(ui.TextField{ .initial = f.address.text(), .width = 80, .max_len = 4, .on_changed = .of(f, Form.setAddress) }),
                cx.make(ui.Text{ .text = "Register", .style = label, .wrap = false }),
                cx.make(ui.TextField{ .initial = f.register.text(), .width = 80, .max_len = 4, .on_changed = .of(f, Form.setRegister) }),
                cx.make(ui.Radio(u8){ .value = 1, .group_value = f.width, .label = "1 byte", .on_changed = .of(f, Form.setWidth) }),
                cx.make(ui.Radio(u8){ .value = 2, .group_value = f.width, .label = "2 bytes", .on_changed = .of(f, Form.setWidth) }),
                cx.make(ui.Checkbox{ .value = f.signed, .label = "Signed", .on_changed = .of(f, Form.setSigned) }),
            } })) catch {},
            .serial => {
                var ports: std.ArrayList(ui.Widget) = .empty;
                ports.append(a, cx.make(ui.Text{ .text = "Port", .style = label, .wrap = false })) catch {};
                for (0..f.ports.count) |i| {
                    const name = f.ports.name(i);
                    ports.append(a, cx.make(ui.Radio(usize){
                        .value = i,
                        .group_value = f.port,
                        .label = if (sys.serial.isHeader(name)) cx.fmt("Header, pins 8 and 10 ({s})", .{name}) else cx.fmt("{s}", .{name}),
                        .on_changed = .of(f, Form.setPort),
                    })) catch {};
                }
                lines.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = ports.items })) catch {};
                var bauds: std.ArrayList(ui.Widget) = .empty;
                bauds.append(a, cx.make(ui.Text{ .text = "Baud", .style = label, .wrap = false })) catch {};
                for (Form.bauds) |b| bauds.append(a, cx.make(ui.Radio(u32){ .value = b, .group_value = f.baud, .label = cx.fmt("{d}", .{b}), .on_changed = .of(f, Form.setBaud) })) catch {};
                lines.append(a, cx.make(ui.Row{ .spacing = 16, .cross_axis_alignment = .center, .children = bauds.items })) catch {};
                if (f.ports.count > 0 and sys.serial.isHeader(f.ports.name(f.port))) lines.append(a, cx.make(ui.Text{
                    .text = "The system's messages go out on the header's port too, at the speed chosen here.",
                    .style = label,
                })) catch {};
            },
        }
        var name_buf: [40]u8 = undefined;
        const placeholder = switch (f.source_()) {
            .ok => |s| cx.fmt("{s}", .{s.defaultName(&name_buf)}),
            .bad => "Name",
        };
        lines.append(a, cx.make(ui.Row{ .spacing = 12, .cross_axis_alignment = .center, .children = &.{
            cx.make(ui.Text{ .text = "Name", .style = label, .wrap = false }),
            cx.make(ui.TextField{ .initial = f.name.text(), .placeholder = placeholder, .width = 240, .max_len = 40, .on_changed = .of(f, Form.setName), .on_submit = .of(self.actions, struct {
                fn add(acts: *Actions) void {
                    acts.add = true;
                }
            }.add) }),
            cx.make(ui.Expanded{ .child = if (f.failure) |why| cx.make(ui.Text{ .text = cx.fmt("It cannot be added: {s}", .{why}), .style = .{ .size = 15, .color = t.@"error" } }) else cx.make(ui.Empty{}) }),
            cx.make(ui.OutlinedButton{ .label = "Add", .icon = .check, .on_press = .of(self.actions, struct {
                fn add(acts: *Actions) void {
                    acts.add = true;
                }
            }.add) }),
            cx.make(ui.OutlinedButton{ .label = "Cancel", .icon = .close, .on_press = .of(f, Form.hide) }),
        } })) catch {};
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .main_axis_size = .min, .spacing = 12, .children = lines.items });
    }
};

const Remove = struct {
    actions: *Actions,
    index: usize,

    fn press(r: *Remove) void {
        r.actions.remove = r.index;
    }
};

/// "12.3 s", "4:05.0", "1:02:03".
pub fn formatDuration(buf: []u8, seconds: f64) []const u8 {
    const s = @max(seconds, 0);
    if (s < 60) return std.fmt.bufPrint(buf, "{d:.1} s", .{s}) catch "";
    const whole: u64 = @intFromFloat(s);
    if (whole < 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d}", .{ whole / 60, whole % 60, @as(u64, @intFromFloat((s - @floor(s)) * 10)) }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ whole / 3600, whole / 60 % 60, whole % 60 }) catch "";
}

/// A row's value now, as people read it.
pub fn formatValue(buf: []u8, s: *const Source, live: Live) []const u8 {
    if (s.* == .serial) return if (live.line.len > 0) live.line.text() else "Nothing yet";
    const v = live.value orelse return "\u{2014}";
    return switch (s.*) {
        .digital => if (v > 0.5) "High" else "Low",
        .analog => std.fmt.bufPrint(buf, "{d:.3} V", .{v}) catch "",
        else => std.fmt.bufPrint(buf, "{d}", .{v}) catch "",
    };
}

// --- The time line and the plots ---------------------------------------------------

/// A step between the time line's marks: at least this far apart, in
/// pixels.
const min_mark_px = 90;

fn markStep(span: f64, width: f32) f64 {
    const steps = [_]f64{ 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200 };
    for (steps) |s| if (s / span * width >= min_mark_px) return s;
    return steps[steps.len - 1];
}

const Ruler = struct {
    t0: f64,
    span: f64,

    pub fn layout(_: *const Ruler, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else 400, .h = 22 });
    }

    pub fn paint(self: *const Ruler, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const w = n.size.w;
        const step = markStep(self.span, w);
        var m = @ceil(self.t0 / step) * step;
        var buf: [32]u8 = undefined;
        while (m <= self.t0 + self.span) : (m += step) {
            const x: f32 = @floatCast((m - self.t0) / self.span * w);
            c.fillRect(.{ .x = @round(x), .y = 14, .w = 1, .h = 8 }, t.outline);
            const label = if (step < 1) std.fmt.bufPrint(&buf, "{d:.3} s", .{m}) catch "" else formatDuration(&buf, m);
            _ = p.text(12, x + 3, 12, std.mem.trimEnd(u8, label, " "), t.on_surface_variant);
        }
    }
};

const Plot = struct {
    track: *const Track,
    samples: u32,
    rate: u32,
    t0: f64,
    span: f64,
    colour: gfx.Color,
    /// Dragging or the wheel: pan by seconds.
    on_pan: ?ui.ValueCallback(f32) = null,

    pub const State = struct {
        drag_x: ?f32 = null,
    };

    pub fn layout(_: *const Plot, _: *ui.Node, c: ui.Constraints) ui.Size {
        return c.constrain(.{ .w = if (c.boundedWidth()) c.max_w else 400, .h = row_height });
    }

    pub fn event(self: *const Plot, n: *ui.Node, e: ui.Event) bool {
        const f = self.on_pan orelse return false;
        const st = n.state(State);
        const per_px: f32 = @floatCast(self.span / @max(n.size.w, 1));
        switch (e) {
            .scroll => |s| {
                f.call((if (s.dx != 0) s.dx else s.dy) * per_px);
                return true;
            },
            .press => |pr| {
                if (pr.button != ui.btn_left) return false;
                st.drag_x = pr.pos[0];
                return true;
            },
            .motion => |pos| if (st.drag_x) |x| {
                f.call((x - pos[0]) * per_px);
                st.drag_x = pos[0];
                return true;
            },
            .release => {
                st.drag_x = null;
                return true;
            },
            else => {},
        }
        return false;
    }

    pub fn paint(self: *const Plot, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .all(6), t.surface_container);
        // The time line's marks, faintly.
        const step = markStep(self.span, w);
        var m = @ceil(self.t0 / step) * step;
        while (m <= self.t0 + self.span) : (m += step) {
            const x: f32 = @floatCast((m - self.t0) / self.span * w);
            c.fillRect(.{ .x = @round(x), .y = 0, .w = 1, .h = h }, t.outline_variant.withAlpha(0.5));
        }
        const old = p.clipTo(.{ .x = 0, .y = 0, .w = w, .h = h });
        defer p.restoreClip(old);
        if (self.track.source == .serial) return self.paintLines(n, p);
        if (self.samples == 0) return;
        const rate: f64 = @floatFromInt(self.rate);
        // The samples that show.
        const first: u32 = @intFromFloat(std.math.clamp(@floor(self.t0 * rate), 0, @as(f64, @floatFromInt(self.samples))));
        const last: u32 = @intFromFloat(std.math.clamp(@ceil((self.t0 + self.span) * rate) + 1, 0, @as(f64, @floatFromInt(self.samples))));
        if (first >= last) return;
        const data = self.track.samples[first..last];
        const digital = self.track.source == .digital;
        // The range: a digital pin's 0 and 1, else the values that show.
        var lo: f32 = 0;
        var hi: f32 = 1;
        if (!digital) {
            lo = std.math.inf(f32);
            hi = -std.math.inf(f32);
            for (data) |v| if (!std.math.isNan(v)) {
                lo = @min(lo, v);
                hi = @max(hi, v);
            };
            if (lo > hi) return;
            if (hi - lo < 1e-6) {
                lo -= 0.5;
                hi += 0.5;
            }
            var buf: [32]u8 = undefined;
            _ = p.text(11, 6, 13, std.fmt.bufPrint(&buf, "{d:.3}", .{hi}) catch "", t.on_surface_variant);
            _ = p.text(11, 6, h - 5, std.fmt.bufPrint(&buf, "{d:.3}", .{lo}) catch "", t.on_surface_variant);
        }
        const top: f32 = 10;
        const bottom = h - 10;
        const yOf = struct {
            fn f(v: f32, l: f32, hh: f32, tp: f32, bt: f32) f32 {
                return bt - (v - l) / (hh - l) * (bt - tp);
            }
        }.f;
        var points: [2048]gfx.Point = undefined;
        var len: usize = 0;
        const per_px = rate * self.span / w;
        if (per_px >= 1) {
            // More samples than pixels: each column's lowest and highest.
            var x: f32 = 0;
            while (x < w) : (x += 1) {
                const a: u32 = @intFromFloat(std.math.clamp((self.t0 + @as(f64, x) / w * self.span) * rate, 0, @as(f64, @floatFromInt(self.samples))));
                const b: u32 = @intFromFloat(std.math.clamp((self.t0 + @as(f64, x + 1) / w * self.span) * rate, 0, @as(f64, @floatFromInt(self.samples))));
                if (a >= b) continue;
                var cl = std.math.inf(f32);
                var ch = -std.math.inf(f32);
                for (self.track.samples[a..b]) |v| if (!std.math.isNan(v)) {
                    cl = @min(cl, v);
                    ch = @max(ch, v);
                };
                if (cl > ch) {
                    // Nothing read here: a gap.
                    flush(c, points[0..len], self.colour);
                    len = 0;
                    continue;
                }
                if (len + 2 > points.len) {
                    flush(c, points[0..len], self.colour);
                    points[0] = points[len - 1];
                    len = 1;
                }
                points[len] = .{ x, yOf(cl, lo, hi, top, bottom) };
                points[len + 1] = .{ x, yOf(ch, lo, hi, top, bottom) };
                len += 2;
            }
        } else {
            // Fewer: a point a sample (a digital pin's in steps).
            for (data, first..) |v, i| {
                if (std.math.isNan(v)) {
                    flush(c, points[0..len], self.colour);
                    len = 0;
                    continue;
                }
                const x: f32 = @floatCast((@as(f64, @floatFromInt(i)) / rate - self.t0) / self.span * w);
                const y = yOf(v, lo, hi, top, bottom);
                if (len + 2 > points.len) {
                    flush(c, points[0..len], self.colour);
                    points[0] = points[len - 1];
                    len = 1;
                }
                if (digital and len > 0) {
                    points[len] = .{ x, points[len - 1][1] };
                    len += 1;
                }
                points[len] = .{ x, y };
                len += 1;
            }
        }
        flush(c, points[0..len], self.colour);
    }

    /// A serial row: a mark at each line, with as much of its text as fits
    /// before the next.
    fn paintLines(self: *const Plot, n: *ui.Node, p: *ui.Painter) void {
        const t = &n.ui.theme;
        const c = p.canvas();
        const w = n.size.w;
        const rate: f64 = @floatFromInt(self.rate);
        var text_end: f32 = -1;
        var lane: usize = 0;
        for (self.track.recordedEvents()) |*e| {
            const at = @as(f64, @floatFromInt(e.at)) / rate;
            if (at < self.t0 - self.span) continue;
            if (at > self.t0 + self.span) break;
            const x: f32 = @floatCast((at - self.t0) / self.span * w);
            c.fillRect(.{ .x = @round(x), .y = 4, .w = 2, .h = n.size.h - 8 }, self.colour);
            if (x < text_end) continue;
            lane = (lane + 1) % 4;
            const end = p.text(12, x + 5, 18 + @as(f32, @floatFromInt(lane)) * 20, e.text(), t.on_surface);
            text_end = @min(end, x + 260) + 6;
        }
    }
};

fn flush(c: *gfx.Canvas, points: []const gfx.Point, colour: gfx.Color) void {
    if (points.len >= 2) c.strokePolyline(points, false, 1.5, colour) else if (points.len == 1) c.fillCircle(points[0], 1.5, colour);
}

// --- Tests -----------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

fn findIcon(n: *ui.Node, icon: ui.icons.Icon) ?*ui.Node {
    if (n.widget.as(ui.Icon)) |i| if (i.icon == icon) return n;
    for (n.children.items) |ch| if (findIcon(ch, icon)) |f| return f;
    return null;
}

fn up(n: *ui.Node, comptime T: type) ?*ui.Node {
    var at: ?*ui.Node = n;
    while (at) |a| : (at = a.parent) if (a.widget.is(T)) return a;
    return null;
}

fn click(u: *ui.Ui, n: *ui.Node) void {
    const pos = n.position();
    const at: ui.Point = .{ pos[0] + n.size.w / 2, pos[1] + n.size.h / 2 };
    u.pointerMotion(at);
    u.pointerButton(at, ui.btn_left, true);
    u.pointerButton(at, ui.btn_left, false);
}

test "rows of each kind, recorded and drawn, at every size; and the form" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var r = Recorder.init(testing.allocator);
    r.hardware = false;
    defer r.deinit();
    try r.add(.{ .digital = 17 }, "Button");
    try r.add(.{ .analog = .{} }, "");
    try r.add(.{ .i2c = .{ .address = 0x76, .register = 0xfa, .width = 2 } }, "");
    try r.add(.{ .serial = .init("ttyUSB0", 9600) }, "");
    r.rate = 100;
    r.record();
    for (0..500) |i| {
        r.tracks[1].value = @sin(@as(f32, @floatFromInt(i)) / 20);
        r.tracks[2].value = @floatFromInt(i % 7);
        if (i % 50 == 0) for ("reading 42\n") |ch| r.serialByte(&r.tracks[3], ch, true, r.sampleCount());
        r.tick();
    }
    r.stop();
    var form: Form = .{};
    var actions: Actions = .{};
    const live = [_]Live{ .{ .value = 1 }, .{ .value = 1.25 }, .{ .failure = "nothing answers at that address" }, .{} };
    var logger: Logger = .{ .recorder = &r, .live = &live, .form = &form, .actions = &actions, .time = .{ .span = 10, .end = 5 } };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| for ([_]f64{ 0.5, 10, 600 }) |span| {
        logger.time = .{ .span = span, .end = 5 };
        logger.width = @floatFromInt(size[0]);
        u.frame(size[0], size[1], 0, logger);
        try testing.expect(!overflows(u.root.?));
    };
    try testing.expect(findText(u.root.?, "Button") != null);
    try testing.expect(findText(u.root.?, "High") != null);
    try testing.expect(findText(u.root.?, "1.250 V") != null);
    try testing.expect(findText(u.root.?, "Cannot read: nothing answers at that address") != null);
    try testing.expect(findText(u.root.?, "5.0 s") != null);

    // The form, for each kind.
    click(u, findText(u.root.?, "Add row").?);
    try testing.expect(form.open);
    for (std.enums.values(Form.Kind)) |k| {
        form.kind = k;
        u.frame(1280, 720, 1, logger);
        try testing.expect(!overflows(u.root.?));
    }
    form.kind = .i2c;
    form.address.set("0x76");
    form.register.set("0xzz");
    try testing.expectEqualStrings("the register should be from 0x00 to 0xff", form.source_().bad);
    form.register.set("0xfa");
    try testing.expectEqual(@as(u8, 0xfa), form.source_().ok.i2c.register);
    form.kind = .digital;
    form.pin.set("60");
    try testing.expect(form.source_() == .bad);

    // The rate, from its menu.
    form.open = false;
    u.frame(1280, 720, 2, logger);
    click(u, findText(u.root.?, "100 / s").?);
    u.frame(1280, 720, 3, logger);
    click(u, findText(u.menu_root.?, "10 samples a second").?);
    try testing.expectEqual(@as(?u32, 10), actions.rate);

    // Recording: rows stay as they are.
    r.record();
    u.frame(1280, 720, 2, logger);
    try testing.expect(findText(u.root.?, "Rows can be added and removed when not recording") != null);
    click(u, up(findIcon(u.root.?, .stop).?, ui.OutlinedButton).?);
    try testing.expect(actions.stop);
    r.stop();
}

test "durations, values and the time line's marks" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("12.3 s", formatDuration(&buf, 12.34));
    try testing.expectEqualStrings("4:05.5", formatDuration(&buf, 245.5));
    try testing.expectEqualStrings("1:02:03", formatDuration(&buf, 3723));
    const d: Source = .{ .digital = 4 };
    try testing.expectEqualStrings("Low", formatValue(&buf, &d, .{ .value = 0 }));
    try testing.expectEqualStrings("\u{2014}", formatValue(&buf, &d, .{}));
    try testing.expectEqual(@as(f64, 2), markStep(10, 500));
    try testing.expectEqual(@as(f64, 0.01), markStep(0.1, 1000));
}
