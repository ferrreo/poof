const std = @import("std");

const generated_bytes_max: u64 = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    );
    defer arguments.deinit();
    _ = arguments.next();
    const first_path = arguments.next() orelse return error.MissingArgument;
    const second_path = arguments.next() orelse return error.MissingArgument;
    if (arguments.next() != null) return error.UnexpectedArgument;

    const first = try readFile(init, first_path);
    defer init.gpa.free(first);
    const second = try readFile(init, second_path);
    defer init.gpa.free(second);
    if (!std.mem.eql(u8, first, second)) return error.GeneratedModulesDiffer;
}

fn readFile(init: std.process.Init, path: []const u8) ![]u8 {
    const file = try if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(init.io, path, .{})
    else
        std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    if (stat.size > generated_bytes_max) return error.GeneratedModuleTooLarge;
    const length = std.math.cast(usize, stat.size) orelse {
        return error.GeneratedModuleTooLarge;
    };
    const bytes = try init.gpa.alloc(u8, length);
    errdefer init.gpa.free(bytes);
    const read = try file.readPositionalAll(init.io, bytes, 0);
    if (read != bytes.len) return error.ShortRead;
    return bytes;
}
