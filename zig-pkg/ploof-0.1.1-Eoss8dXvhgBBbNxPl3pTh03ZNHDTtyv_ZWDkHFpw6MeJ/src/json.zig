const encoder = @import("internal/json/encode.zig");
const decoder = @import("internal/json/decode.zig");
const decode_layout = @import("internal/json/decode_layout.zig");
const decode_typed = @import("internal/json/decode_typed.zig");
const parse_hook = @import("internal/json/parse_hook.zig");
const schema = @import("internal/json/schema.zig");
const token_source = @import("internal/json/token_source.zig");
const types = @import("internal/json/types.zig");
const validate = @import("internal/json/validate.zig");
const body = @import("body.zig");

pub const depth_hard_max = types.depth_hard_max;
pub const hook_depth_hard_max = types.hook_depth_hard_max;
pub const standard_encoded_bytes_max = types.standard_encoded_bytes_max;
pub const Whitespace = types.Whitespace;
pub const Options = types.Options;
pub const standard_options = types.standard_options;
pub const Error = types.Error;
/// Encoder-owned failures available to every `jsonStringify` hook.
pub const FrameworkEncodeError = types.FrameworkEncodeError;
/// Complete failures declared by every reachable `jsonStringify` hook.
pub const DeclaredEncodeError = types.DeclaredEncodeError;
/// Application-owned failures explicitly named by reachable hooks.
pub const CustomEncodeError = types.CustomEncodeError;
pub const EncodeError = types.EncodeError;
pub const Number = types.Number;
pub const NumberError = types.NumberError;
pub const NumberConversionError = types.NumberConversionError;
pub const Value = types.Value;
pub const Member = types.Member;
pub const FieldOptions = schema.FieldOptions;
pub const SchemaIssue = schema.Issue;
pub const field = schema.field;
pub const UnknownFields = decoder.UnknownFields;
pub const DecodeError = decoder.Error;
pub const ParseError = types.ParseError;
pub const ValueKind = types.ValueKind;

pub const standard_parse_memory_bytes_max: usize = 2 * 1024 * 1024;

pub const DecodeOptions = struct {
    encoded_wire_bytes_max: u64 = body.standard_bytes_max,
    decoded_bytes_max: u64 = body.standard_bytes_max,
    parse_memory_bytes_max: usize = standard_parse_memory_bytes_max,
    depth_max: u16 = token_source.depth_standard_max,
    unknown_fields: UnknownFields = .ignore,
};

pub fn typed(comptime T: type, comptime options: DecodeOptions) Decoder(T, options) {
    return .{};
}

pub fn dynamic(comptime options: DecodeOptions) Decoder(Value, options) {
    return .{};
}

fn Decoder(comptime T: type, comptime requested: DecodeOptions) type {
    const options = comptime validateDecodeOptions(requested);
    comptime parse_hook.validateType(T);
    comptime decode_typed.validateType(T);
    if (options.parse_memory_bytes_max < decode_layout.minimumParseMemory(T)) {
        @compileError("PLOOF-E3269 JSON parse memory limit cannot hold root and required plans");
    }
    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind: body.DecoderKind = .json;
        pub const Target = T;
        pub const resolved_options = options;
        pub const encoded_wire_bytes_max = options.encoded_wire_bytes_max;
        pub const decoded_bytes_max = options.decoded_bytes_max;
        pub const parse_memory_bytes_max = options.parse_memory_bytes_max;
        pub const parse_memory_alignment = @max(
            validate.scratch_alignment,
            decode_layout.parseMemoryAlignment(T),
        );
        pub const depth_max = options.depth_max;
        pub const unknown_fields = options.unknown_fields;
    };
}

fn validateDecodeOptions(options: DecodeOptions) DecodeOptions {
    if (options.encoded_wire_bytes_max == 0) {
        @compileError("PLOOF-E3264 JSON encoded byte limit must be nonzero");
    }
    if (options.decoded_bytes_max == 0) {
        @compileError("PLOOF-E3265 JSON decoded byte limit must be nonzero");
    }
    if (options.parse_memory_bytes_max == 0) {
        @compileError("PLOOF-E3266 JSON parse memory limit must be nonzero");
    }
    if (options.depth_max == 0 or options.depth_max > token_source.depth_hard_max) {
        @compileError("PLOOF-E3267 JSON depth limit must be in 1...256");
    }
    return options;
}

pub fn schemaIssue(comptime T: type) ?SchemaIssue {
    return schema.issue(T);
}

pub fn encode(value: anytype, output: []u8) EncodeError(@TypeOf(value))![]const u8 {
    return encoder.encode(.{}, value, output);
}

pub fn encodeWith(
    comptime options: Options,
    value: anytype,
    output: []u8,
) EncodeError(@TypeOf(value))![]const u8 {
    return encoder.encode(options, value, output);
}

test {
    _ = @import("internal/json/types.zig");
    _ = @import("internal/json/schema.zig");
}

test "typed and dynamic decoder declarations retain bounded policy" {
    const Typed = @TypeOf(typed(struct { id: u32 }, .{ .depth_max = 7 }));
    const Dynamic = @TypeOf(dynamic(.{}));
    try @import("std").testing.expect(Typed.ploof_body_decoder_spec);
    try @import("std").testing.expectEqual(@as(u16, 7), Typed.depth_max);
    try @import("std").testing.expect(Dynamic.Target == Value);
}
