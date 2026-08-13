const std = @import("std");
const compiler = @import("asset_compiler.zig");

pub fn main(init: std.process.Init) void {
    compiler.run(init) catch |err| {
        const message = compiler.diagnostic(err);
        std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        std.process.exit(compiler.exitStatus(err));
    };
}
