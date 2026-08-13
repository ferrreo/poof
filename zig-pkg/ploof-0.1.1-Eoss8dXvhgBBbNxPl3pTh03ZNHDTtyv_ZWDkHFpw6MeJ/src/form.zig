const std = @import("std");

const body = @import("body.zig");
const flat_schema = @import("internal/flat/schema.zig");
const flat_wire = @import("internal/flat/wire.zig");
const query = @import("query.zig");

pub const Raw = flat_wire.Table;
pub const Pair = flat_wire.Pair;
pub const UnknownPolicy = flat_schema.UnknownPolicy;
pub const standard_segments_max = flat_wire.segments_standard_max;
pub const segments_hard_max = flat_wire.segments_hard_max;

pub const Options = struct {
    encoded_wire_bytes_max: u64 = body.standard_bytes_max,
    decoded_bytes_max: u64 = body.standard_bytes_max,
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
        T.ploof_flat_input_spec and T.source == .form;
}

fn Typed(comptime T: type, comptime requested: Options) type {
    const options = comptime validate(requested);
    const QuerySpec = @TypeOf(query.typed(T, .{
        .segments_max = options.segments_max,
        .unknown_fields = options.unknown_fields,
    }));
    return struct {
        pub const ploof_flat_input_spec = true;
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind: body.DecoderKind = .form;
        pub const source: flat_wire.Source = .form;
        pub const Target = T;
        pub const is_raw = false;
        pub const resolved_options = options;
        pub const pair_bytes_max = @as(usize, options.segments_max) * @sizeOf(Pair);
        pub const decoded_bytes_max = options.decoded_bytes_max;
        pub const binding_bytes_max = QuerySpec.binding_bytes_max;
        pub const accepted_media = [_]body.MediaPattern{
            .{ .exact = "application/x-www-form-urlencoded" },
        };
    };
}

fn RawSpec(comptime requested: Options) type {
    const options = comptime validate(requested);
    return struct {
        pub const ploof_flat_input_spec = true;
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind: body.DecoderKind = .form;
        pub const source: flat_wire.Source = .form;
        pub const Target = Raw;
        pub const is_raw = true;
        pub const resolved_options = options;
        pub const pair_bytes_max = @as(usize, options.segments_max) * @sizeOf(Pair);
        pub const decoded_bytes_max = options.decoded_bytes_max;
        pub const binding_bytes_max: usize = 0;
        pub const accepted_media = [_]body.MediaPattern{
            .{ .exact = "application/x-www-form-urlencoded" },
        };
    };
}

fn validate(options: Options) Options {
    if (options.encoded_wire_bytes_max == 0) {
        @compileError("PLOOF-E3233 form encoded byte limit must be nonzero");
    }
    if (options.decoded_bytes_max == 0) {
        @compileError("PLOOF-E3234 form decoded byte limit must be nonzero");
    }
    if (options.decoded_bytes_max > std.math.maxInt(u32)) {
        @compileError("PLOOF-E3235 form decoded byte limit exceeds u32");
    }
    if (flat_wire.segmentLimitIssue(options.segments_max)) |issue| switch (issue) {
        .zero => @compileError("PLOOF-E3236 form segment limit must be nonzero"),
        .above_hard_max => @compileError("PLOOF-E3237 form segment limit exceeds 4096"),
    };
    return options;
}

test "form specs retain independent body and field limits" {
    const T = struct { enabled: bool };
    const spec = typed(T, .{
        .encoded_wire_bytes_max = 11,
        .decoded_bytes_max = 9,
        .segments_max = 3,
    });
    const Spec = @TypeOf(spec);
    try std.testing.expect(isSpec(Spec));
    try std.testing.expectEqual(
        @as(u64, 11),
        Spec.resolved_options.encoded_wire_bytes_max,
    );
    try std.testing.expectEqual(@as(u64, 9), Spec.decoded_bytes_max);
}
