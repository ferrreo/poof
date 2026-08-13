const flat_schema = @import("internal/flat/schema.zig");
const flat_wire = @import("internal/flat/wire.zig");
const http1_limits = @import("internal/http1/limits.zig");

pub const Raw = flat_wire.Table;
pub const Pair = flat_wire.Pair;
pub const UnknownPolicy = flat_schema.UnknownPolicy;
pub const standard_segments_max = flat_wire.segments_standard_max;
pub const segments_hard_max = flat_wire.segments_hard_max;

pub const Options = struct {
    segments_max: u16 = standard_segments_max,
    unknown_fields: UnknownPolicy = .ignore,
};

pub fn typed(comptime T: type, comptime requested: Options) Typed(T, requested) {
    return .{};
}

pub fn raw(comptime requested: Options) RawSpec(requested) {
    return .{};
}

pub fn isSpec(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_flat_input_spec") and
        T.ploof_flat_input_spec and T.source == .query;
}

fn Typed(comptime T: type, comptime requested: Options) type {
    const options = comptime validate(requested);
    return struct {
        pub const ploof_flat_input_spec = true;
        pub const source: flat_wire.Source = .query;
        pub const Target = T;
        pub const is_raw = false;
        pub const resolved_options = options;
        pub const pair_bytes_max = @as(usize, options.segments_max) * @sizeOf(Pair);
        pub const decoded_bytes_max =
            http1_limits.standard_request_head_limits.request_line_bytes_max;
        pub const binding_bytes_max = bindingBytesMax(T, options.segments_max);
    };
}

fn RawSpec(comptime requested: Options) type {
    const options = comptime validate(requested);
    return struct {
        pub const ploof_flat_input_spec = true;
        pub const source: flat_wire.Source = .query;
        pub const Target = Raw;
        pub const is_raw = true;
        pub const resolved_options = options;
        pub const pair_bytes_max = @as(usize, options.segments_max) * @sizeOf(Pair);
        pub const decoded_bytes_max =
            http1_limits.standard_request_head_limits.request_line_bytes_max;
        pub const binding_bytes_max: usize = 0;
    };
}

fn validate(options: Options) Options {
    if (flat_wire.segmentLimitIssue(options.segments_max)) |issue| switch (issue) {
        .zero => @compileError("PLOOF-E3230 query segment limit must be nonzero"),
        .above_hard_max => @compileError("PLOOF-E3231 query segment limit exceeds 4096"),
    };
    return options;
}

fn bindingBytesMax(comptime T: type, comptime segments_max: usize) usize {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("PLOOF-E3232 typed query destination must be a struct"),
    };
    var child_size_max: usize = 0;
    var alignment_padding: usize = 0;
    inline for (info.fields) |field| switch (@typeInfo(field.type)) {
        .pointer => |pointer| if (pointer.size == .slice and field.type != []const u8) {
            child_size_max = @max(child_size_max, @sizeOf(pointer.child));
            alignment_padding += @alignOf(pointer.child) - 1;
        },
        else => {},
    };
    return segments_max * child_size_max + alignment_padding;
}

test "query specs retain bounded compile-time policy" {
    const T = struct { id: u16, tags: []const u16 = &.{} };
    const spec = typed(T, .{ .segments_max = 7, .unknown_fields = .reject });
    const Spec = @TypeOf(spec);
    try @import("std").testing.expect(isSpec(Spec));
    try @import("std").testing.expectEqual(@as(u16, 7), Spec.resolved_options.segments_max);
    try @import("std").testing.expect(Spec.binding_bytes_max >= 7 * @sizeOf(u16));
}
