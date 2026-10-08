//! What a row of the log reads: a GPIO pin (digital), an analog input on
//! an I2C converter (an ADS1115 or ADS1015, or a PCF8591), a register of
//! any I2C device, or the lines that come in on a serial port.

const std = @import("std");
const sys = @import("sys");

pub const Converter = enum {
    /// ADS1115 (16 bits) or ADS1015 (12 bits): four inputs, read at up to
    /// 4.096 V, one at a time (a conversion takes about 1.2 ms).
    ads1x15,
    /// PCF8591: four 8-bit inputs, from 0 to its supply (3.3 V here).
    pcf8591,

    pub fn label(c: Converter) []const u8 {
        return switch (c) {
            .ads1x15 => "ADS1115 / ADS1015",
            .pcf8591 => "PCF8591",
        };
    }
};

pub const Analog = struct {
    converter: Converter = .ads1x15,
    address: u7 = 0x48,
    channel: u2 = 0,
};

pub const Register = struct {
    address: u7 = 0x48,
    register: u8 = 0,
    /// 1 or 2 bytes (two: the first the high byte).
    width: u8 = 1,
    signed: bool = false,
};

pub const Serial = struct {
    port_buf: [12]u8 = undefined,
    port_len: u8 = 0,
    baud: u32 = 115200,

    pub fn port(s: *const Serial) []const u8 {
        return s.port_buf[0..s.port_len];
    }

    pub fn init(name: []const u8, baud: u32) Serial {
        var s: Serial = .{ .baud = baud, .port_len = @intCast(@min(name.len, 12)) };
        @memcpy(s.port_buf[0..s.port_len], name[0..s.port_len]);
        return s;
    }
};

pub const Source = union(enum) {
    digital: u6,
    analog: Analog,
    i2c: Register,
    serial: Serial,

    /// A name for the row, until the user gives another.
    pub fn defaultName(s: *const Source, buf: []u8) []const u8 {
        return switch (s.*) {
            .digital => |pin| std.fmt.bufPrint(buf, "GPIO {d}", .{pin}) catch "",
            .analog => |a| std.fmt.bufPrint(buf, "Analog {d}", .{a.channel}) catch "",
            .i2c => |r| std.fmt.bufPrint(buf, "I2C 0x{x:0>2} register 0x{x:0>2}", .{ r.address, r.register }) catch "",
            .serial => |*se| std.fmt.bufPrint(buf, "Serial {s}", .{se.port()}) catch "",
        };
    }

    /// What it reads, in a line.
    pub fn describe(s: *const Source, buf: []u8) []const u8 {
        return switch (s.*) {
            .digital => |pin| std.fmt.bufPrint(buf, "Digital: GPIO {d}", .{pin}) catch "",
            .analog => |a| std.fmt.bufPrint(buf, "Analog: {s} at 0x{x:0>2}, input {d}", .{ a.converter.label(), a.address, a.channel }) catch "",
            .i2c => |r| std.fmt.bufPrint(buf, "I2C: 0x{x:0>2}, register 0x{x:0>2}, {d} byte{s}{s}", .{ r.address, r.register, r.width, if (r.width == 1) "" else "s", if (r.signed) ", signed" else "" }) catch "",
            .serial => |*se| std.fmt.bufPrint(buf, "Serial: {s} at {d} baud", .{ se.port(), se.baud }) catch "",
        };
    }

    /// Its values' unit, if they have one.
    pub fn unit(s: *const Source) []const u8 {
        return switch (s.*) {
            .analog => "V",
            else => "",
        };
    }

    /// Whether it is read on the I2C bus.
    pub fn onI2c(s: *const Source) bool {
        return s.* == .analog or s.* == .i2c;
    }
};

pub const ReadError = sys.i2c.Error;

/// Reads an analog input: its voltage.
pub fn readAnalog(bus: *const sys.i2c.Bus, a: Analog) ReadError!f32 {
    switch (a.converter) {
        .ads1x15 => {
            // Single-shot: start a conversion of input `channel` against
            // ground, at ±4.096 V, 860 samples a second (ADS1115).
            const config: u16 = 0x8000 | @as(u16, 4 + @as(u16, a.channel)) << 12 | 1 << 9 | 1 << 8 | 7 << 5 | 3;
            try bus.write(a.address, &.{ 0x01, @intCast(config >> 8), @truncate(config) });
            // Done when the top bit of the configuration is set again.
            var tries: u32 = 0;
            while (tries < 20) : (tries += 1) {
                sys.sleepUs(250);
                var c: [2]u8 = undefined;
                try bus.readRegister(a.address, 0x01, &c);
                if (c[0] & 0x80 != 0) break;
            }
            var v: [2]u8 = undefined;
            try bus.readRegister(a.address, 0x00, &v);
            return adsVolts(std.mem.readInt(i16, &v, .big));
        },
        .pcf8591 => {
            // The control byte picks the input; the first byte read is the
            // conversion before, the second this one.
            try bus.write(a.address, &.{a.channel});
            var v: [2]u8 = undefined;
            try bus.read(a.address, &v);
            return pcfVolts(v[1]);
        },
    }
}

fn adsVolts(raw: i16) f32 {
    return @as(f32, @floatFromInt(raw)) * 4.096 / 32768.0;
}

fn pcfVolts(raw: u8) f32 {
    return @as(f32, @floatFromInt(raw)) * 3.3 / 255.0;
}

/// Reads a register: its value.
pub fn readRegister(bus: *const sys.i2c.Bus, r: Register) ReadError!f32 {
    var v: [2]u8 = undefined;
    const bytes = v[0..@min(@max(r.width, 1), 2)];
    try bus.readRegister(r.address, r.register, bytes);
    return registerValue(bytes, r.signed);
}

fn registerValue(bytes: []const u8, signed: bool) f32 {
    if (bytes.len == 1) return if (signed) @floatFromInt(@as(i8, @bitCast(bytes[0]))) else @floatFromInt(bytes[0]);
    const u = std.mem.readInt(u16, bytes[0..2], .big);
    return if (signed) @floatFromInt(@as(i16, @bitCast(u))) else @floatFromInt(u);
}

/// Why a source could not be read, for people.
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.NoDevice => "nothing answers at that address",
        error.AccessDenied => "not allowed to use it",
        error.FileNotFound, error.NotFound => "it is not there",
        else => "it could not be read",
    };
}

/// Parses a number as typed: decimal, or hex with 0x.
pub fn parseNumber(comptime T: type, text: []const u8) ?T {
    const t = std.mem.trim(u8, text, " ");
    if (std.ascii.startsWithIgnoreCase(t, "0x")) return std.fmt.parseInt(T, t[2..], 16) catch null;
    return std.fmt.parseInt(T, t, 10) catch null;
}

const testing = std.testing;

test "converters' values" {
    try testing.expectApproxEqAbs(@as(f32, 4.096), adsVolts(32767) + 0.000125, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), adsVolts(8000), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.3), pcfVolts(255), 0.001);
    try testing.expectEqual(@as(f32, 300), registerValue(&.{ 0x01, 0x2c }, false));
    try testing.expectEqual(@as(f32, -2), registerValue(&.{ 0xff, 0xfe }, true));
    try testing.expectEqual(@as(f32, -1), registerValue(&.{0xff}, true));
    try testing.expectEqual(@as(f32, 255), registerValue(&.{0xff}, false));
}

test "names, descriptions and numbers" {
    var buf: [80]u8 = undefined;
    const s: Source = .{ .i2c = .{ .address = 0x76, .register = 0xfa, .width = 2 } };
    try testing.expectEqualStrings("I2C: 0x76, register 0xfa, 2 bytes", s.describe(&buf));
    const d: Source = .{ .digital = 17 };
    try testing.expectEqualStrings("GPIO 17", d.defaultName(&buf));
    const se: Source = .{ .serial = .init("ttyUSB0", 9600) };
    try testing.expectEqualStrings("Serial: ttyUSB0 at 9600 baud", se.describe(&buf));
    try testing.expectEqual(@as(?u7, 0x48), parseNumber(u7, "0x48"));
    try testing.expectEqual(@as(?u7, 72), parseNumber(u7, " 72 "));
    try testing.expect(parseNumber(u7, "0x80") == null);
    try testing.expect(parseNumber(u8, "x") == null);
}
