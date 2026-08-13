const ploof = @import("ploof_compile").ploof;
const std = @import("std");

const source = ploof.HtmlSource;
const template = ploof.HtmlTemplate;
const View = struct {};

pub fn main() void {
    _ = template.Template(config(14));
}

fn Config(comptime depth: usize) type {
    if (depth == 0) return struct { View: type, source: source.SourceSpec };
    return struct {
        View: type,
        source: source.SourceSpec,
        partials: struct { child: Config(depth - 1) },
    };
}

fn config(comptime depth: usize) Config(depth) {
    const name = std.fmt.comptimePrint("edge-{d}", .{depth});
    if (depth == 0) return .{ .View = View, .source = fragment(name, "") };
    return .{
        .View = View,
        .source = fragment(name, "{{> child view}}{{> child view}}"),
        .partials = .{ .child = config(depth - 1) },
    };
}

fn fragment(comptime name: []const u8, comptime bytes: []const u8) source.SourceSpec {
    return .{ .kind = .fragment, .graph_name = name, .file_path = name, .bytes = bytes };
}
