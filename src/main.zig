const std = @import("std");
const Io = std.Io;

const poof = @import("poof");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // First positional argument (after the program name) is an optional name to greet.
    const name = if (args.len > 1) args[1] else "";

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("Hello, {s}\n", .{poof.greeting(name)});
    try stdout.flush();
}

test "main module imports poof" {
    try std.testing.expectEqual(@as(i32, 5), poof.add(2, 3));
}
