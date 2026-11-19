//! Geppetto, an app for recording what the GPIO pins read, for Dazzle:
//! built with Dazzle's modules and tools (see Dazzle's build.zig,
//! `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

pub fn build(b: *std.Build) void {
    // Its program keeps the name it had as the Data Logger, so what is
    // installed updates.
    _ = dazzle.addApp(b, .{
        .name = "dazzle-data-logger",
        .icon = .show_chart,
        .title = "Geppetto",
        .description = "Record inputs from the GPIO pins",
        .about = "Record what the GPIO pins read over time, from buttons, switches and sensors, and see it drawn as a chart as it comes in.",
    });
}
