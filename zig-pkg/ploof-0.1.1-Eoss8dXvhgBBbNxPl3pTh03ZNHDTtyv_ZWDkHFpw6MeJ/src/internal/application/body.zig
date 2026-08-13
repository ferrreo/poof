const std = @import("std");
const body = @import("../../body.zig");
const input_materialize = @import("input_materialize.zig");
const input_plan = @import("input_plan.zig");

pub const Error = error{
    CsrfForbidden,
    InputInvariant,
    InvalidBodyInput,
    InvalidRequestInput,
    RequestInputTooLarge,
};

pub const Kind = input_plan.Kind;
pub const Decoder = input_plan.Decoder;
pub const Plan = input_plan.Plan;
pub const none_plan = input_plan.none;

pub fn isEndpointType(comptime Handler: type) bool {
    if (@typeInfo(Handler) != .@"struct") return false;
    if (@hasDecl(Handler, "ploof_input_endpoint")) return Handler.ploof_input_endpoint;
    return @hasDecl(Handler, "ploof_body_endpoint") and Handler.ploof_body_endpoint;
}

pub fn isEndpoint(comptime handler: anytype) bool {
    return isEndpointType(@TypeOf(handler));
}

pub fn acceptsRequestBody(comptime handler: anytype) bool {
    if (!isEndpoint(handler)) return false;
    const Handler = @TypeOf(handler);
    if (@hasDecl(Handler, "ploof_input_endpoint")) return Handler.definition.body_enabled;
    return true;
}

pub fn Input(comptime handler: anytype) type {
    return if (isEndpoint(handler)) @TypeOf(handler).Input else body.None;
}

pub fn plan(comptime handler: anytype) Plan {
    if (comptime !isEndpoint(handler)) return none_plan;
    const Handler = @TypeOf(handler);
    if (comptime @hasDecl(Handler, "ploof_input_endpoint")) {
        return @import("input.zig").plan(Handler);
    }
    const Layout = LegacyLayout(Handler);
    return Layout.value;
}

fn LegacyLayout(comptime Handler: type) type {
    const decoder_kind: body.DecoderKind = switch (Handler.kind) {
        .none => unreachable,
        .bytes => .bytes,
        .text => .text,
    };
    const plan_kind: Kind = switch (Handler.kind) {
        .none => unreachable,
        .bytes => .bytes,
        .text => .text,
    };
    return struct {
        const decoders = [_]Decoder{.{
            .kind = decoder_kind,
            .encoded_wire_bytes_max = Handler.options.encoded_wire_bytes_max,
            .decoded_bytes_max = Handler.options.decoded_bytes_max,
        }};
        const media_decoder_indices = [_]u8{0} ** Handler.options.accepted_media.?.len;
        const value = Plan{
            .kind = plan_kind,
            .encoded_wire_bytes_max = Handler.options.encoded_wire_bytes_max,
            .decoded_bytes_max = Handler.options.decoded_bytes_max,
            .accepted_media = Handler.options.accepted_media.?,
            .media_decoder_indices = &media_decoder_indices,
            .decoders = &decoders,
            .selected_decoder = 0,
            .workspace_bytes_max = Handler.options.decoded_bytes_max,
            .workspace_alignment = 1,
            .workspace_class = 1,
        };
    };
}

pub fn materialize(
    comptime handler: anytype,
    decoded: body.Decoded,
) Error!Input(handler) {
    return materializeSelected(
        handler,
        decoded,
        null,
        null,
        &.{},
        [_]u8{0} ** 16,
    );
}

pub fn materializeSelected(
    comptime handler: anytype,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    workspace: []u8,
    json_hash_key: [16]u8,
) Error!Input(handler) {
    return materializeSelectedCsrf(
        handler,
        decoded,
        selected_decoder,
        raw_query,
        workspace,
        json_hash_key,
        null,
        null,
    );
}

pub fn materializeSelectedCsrf(
    comptime handler: anytype,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    workspace: []u8,
    json_hash_key: [16]u8,
    csrf_state: ?*@import("../csrf/request.zig").State,
    comptime csrf_form_name: ?[]const u8,
) Error!Input(handler) {
    if (comptime !isEndpoint(handler)) return switch (decoded) {
        .none => .{},
        .bytes, .text => error.InvalidBodyInput,
    };
    if (comptime @hasDecl(@TypeOf(handler), "ploof_input_endpoint")) {
        const result = input_materialize.materializeCsrf(
            @TypeOf(handler),
            decoded,
            selected_decoder,
            raw_query,
            workspace,
            json_hash_key,
            csrf_state,
            csrf_form_name,
        ) catch return error.InputInvariant;
        return switch (result) {
            .ready => |value| value,
            .rejected => |rejection| switch (rejection) {
                .bad_request => error.InvalidRequestInput,
                .payload_too_large => error.RequestInputTooLarge,
                .csrf_forbidden => error.CsrfForbidden,
            },
        };
    }
    return switch (@TypeOf(handler).kind) {
        .none => unreachable,
        .bytes => switch (decoded) {
            .bytes => |value| value,
            .none, .text => error.InvalidBodyInput,
        },
        .text => switch (decoded) {
            .text => |value| value,
            .none, .bytes => error.InvalidBodyInput,
        },
    };
}

test "body plans and materialization preserve endpoint type" {
    const bytes_endpoint = body.bytes(.{ .decoded_bytes_max = 7 }, struct {
        fn handle(_: *u8, value: body.Bytes) usize {
            return value.len();
        }
    }.handle);
    const body_plan = plan(bytes_endpoint);
    try std.testing.expectEqual(Kind.bytes, body_plan.kind);
    try std.testing.expectEqual(@as(u64, 7), body_plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(u16, 1), body_plan.workspace_class);

    const chunks = [_]body.Chunk{body.Chunk.init("abc")};
    const value = try body.Bytes.init(&chunks);
    const input = try materialize(bytes_endpoint, .{ .bytes = value });
    try std.testing.expect(input.eql("abc"));
}

test "bodyless plans reject decoded input" {
    const handler = struct {
        fn handle(_: *u8) usize {
            return 0;
        }
    }.handle;
    const body_plan = plan(handler);
    try std.testing.expectEqual(Kind.none, body_plan.kind);
    _ = try materialize(handler, .none);
    const chunks = [_]body.Chunk{body.Chunk.init("x")};
    const value = try body.Bytes.init(&chunks);
    try std.testing.expectError(
        error.InvalidBodyInput,
        materialize(handler, .{ .bytes = value }),
    );
}
