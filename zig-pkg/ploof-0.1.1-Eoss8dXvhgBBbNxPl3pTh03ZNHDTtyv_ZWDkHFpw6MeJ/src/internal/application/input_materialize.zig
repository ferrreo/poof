const std = @import("std");
const application_input = @import("input.zig");
const body = @import("../../body.zig");
const csrf_request = @import("../csrf/request.zig");
const flat_schema = @import("../flat/schema.zig");
const flat_wire = @import("../flat/wire.zig");
const input_body = @import("../../input_body.zig");
const json_decode = @import("../json/decode.zig");
const json_validate = @import("../json/validate.zig");

pub const Rejection = enum(u8) {
    bad_request,
    payload_too_large,
    csrf_forbidden,
};

pub const InvariantError = error{InvariantViolation};

const MaterializeError = InvariantError || error{
    BadRequest,
    PayloadTooLarge,
    CsrfForbidden,
};

pub fn Outcome(comptime T: type) type {
    return union(enum) {
        ready: T,
        rejected: Rejection,
    };
}

/// Returned slices and pointers borrow `workspace` or the retained body chunks.
pub fn materialize(
    comptime Handler: type,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    workspace: []u8,
    json_hash_key: [16]u8,
) InvariantError!Outcome(Handler.Input) {
    return materializeCsrf(
        Handler,
        decoded,
        selected_decoder,
        raw_query,
        workspace,
        json_hash_key,
        null,
        null,
    );
}

pub fn materializeCsrf(
    comptime Handler: type,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    workspace: []u8,
    json_hash_key: [16]u8,
    csrf_state: ?*csrf_request.State,
    comptime csrf_form_name: ?[]const u8,
) InvariantError!Outcome(Handler.Input) {
    const value = materializeInput(
        Handler,
        decoded,
        selected_decoder,
        raw_query,
        workspace,
        json_hash_key,
        csrf_state,
        csrf_form_name,
    ) catch |problem| return switch (problem) {
        error.BadRequest => .{ .rejected = .bad_request },
        error.PayloadTooLarge => .{ .rejected = .payload_too_large },
        error.CsrfForbidden => .{ .rejected = .csrf_forbidden },
        error.InvariantViolation => error.InvariantViolation,
    };
    return .{ .ready = value };
}

fn materializeInput(
    comptime Handler: type,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    workspace: []u8,
    json_hash_key: [16]u8,
    csrf_state: ?*csrf_request.State,
    comptime csrf_form_name: ?[]const u8,
) MaterializeError!Handler.Input {
    const Definition = Handler.definition;
    const layout = application_input.workspaceLayout(Handler);
    if (workspace.len < layout.total_bytes_max) return error.InvariantViolation;

    if (comptime Definition.query_enabled and Definition.body_enabled) {
        return .{
            .query = try materializeQuery(Definition, raw_query, workspace, layout),
            .body = try materializeBody(
                Definition,
                decoded,
                selected_decoder,
                workspace,
                layout,
                json_hash_key,
                csrf_state,
                csrf_form_name,
            ),
        };
    }
    if (comptime Definition.query_enabled) {
        try expectNoBody(decoded, selected_decoder);
        return .{ .query = try materializeQuery(Definition, raw_query, workspace, layout) };
    }
    if (comptime Definition.body_enabled) {
        return .{ .body = try materializeBody(
            Definition,
            decoded,
            selected_decoder,
            workspace,
            layout,
            json_hash_key,
            csrf_state,
            csrf_form_name,
        ) };
    }
    try expectNoBody(decoded, selected_decoder);
    return .{};
}

fn materializeQuery(
    comptime Definition: type,
    raw_query: ?[]const u8,
    workspace: []u8,
    layout: application_input.WorkspaceLayout,
) MaterializeError!@TypeOf(Definition.query_spec).Target {
    const Spec = @TypeOf(Definition.query_spec);
    var fragment = flat_wire.Fragment.init(raw_query orelse "");
    const fragments = if (raw_query == null) (&fragment)[0..0] else (&fragment)[0..1];
    const pairs = try typedRegion(flat_wire.Pair, workspace, layout.query_pairs);
    const decoded_bytes = try byteRegion(workspace, layout.query_decoded);
    const table = flat_wire.parse(
        Spec.resolved_options.segments_max,
        .query,
        fragments,
        pairs,
        decoded_bytes,
    ) catch |problem| return mapQueryParseError(problem);
    return materializeFlat(Spec, table, workspace, layout.query_binding);
}

fn materializeBody(
    comptime Definition: type,
    decoded: body.Decoded,
    selected_decoder: ?u8,
    workspace: []u8,
    layout: application_input.WorkspaceLayout,
    json_hash_key: [16]u8,
    csrf_state: ?*csrf_request.State,
    comptime csrf_form_name: ?[]const u8,
) MaterializeError!input_body.Input(@TypeOf(Definition.body_spec)) {
    const BodySpec = @TypeOf(Definition.body_spec);
    const selected = selected_decoder orelse return error.InvariantViolation;
    if (selected >= layout.body_decoders.len) return error.InvariantViolation;
    if (comptime input_body.isDecoder(BodySpec)) {
        if (selected != 0) return error.InvariantViolation;
        return materializeDecoder(
            BodySpec,
            decoded,
            workspace,
            layout.body_decoders[0],
            json_hash_key,
            csrf_state,
            csrf_form_name,
        );
    }
    const configured = BodySpec.configured_decoders;
    inline for (@typeInfo(@TypeOf(configured)).@"struct".fields, 0..) |field, index| {
        if (selected == index) {
            const Spec = @TypeOf(@field(configured, field.name));
            const value = try materializeDecoder(
                Spec,
                decoded,
                workspace,
                layout.body_decoders[index],
                json_hash_key,
                csrf_state,
                csrf_form_name,
            );
            return @unionInit(BodySpec.Input, field.name, value);
        }
    }
    return error.InvariantViolation;
}

fn materializeDecoder(
    comptime Spec: type,
    decoded: body.Decoded,
    workspace: []u8,
    layout: application_input.DecoderLayout,
    json_hash_key: [16]u8,
    csrf_state: ?*csrf_request.State,
    comptime csrf_form_name: ?[]const u8,
) MaterializeError!Spec.Target {
    const bytes_max = decoderDecodedMax(Spec);
    switch (comptime Spec.decoder_kind) {
        .bytes => {
            if (Spec.Target != body.Bytes) {
                @compileError("bytes decoder target must be body.Bytes");
            }
            const value = switch (decoded) {
                .bytes => |bytes| bytes,
                else => return error.InvariantViolation,
            };
            try checkBodyBytes(value, workspace, layout.body, bytes_max);
            return value;
        },
        .text => {
            if (Spec.Target != body.Text) {
                @compileError("text decoder target must be body.Text");
            }
            const value = switch (decoded) {
                .text => |text| text,
                else => return error.InvariantViolation,
            };
            try checkBodyBytes(value.asBytes(), workspace, layout.body, bytes_max);
            return value;
        },
        .form => return materializeForm(
            Spec,
            decoded,
            workspace,
            layout,
            csrf_state,
            csrf_form_name,
        ),
        .json => return materializeJson(
            Spec,
            decoded,
            workspace,
            layout,
            json_hash_key,
        ),
        .multipart => {
            if (@sizeOf(Spec.Target) != 0 or @typeInfo(Spec.Target) != .@"struct") {
                @compileError("multipart decoder completion target must be a zero-size struct");
            }
            if (std.meta.activeTag(decoded) != .none) return error.InvariantViolation;
            return .{};
        },
    }
}

fn materializeForm(
    comptime Spec: type,
    decoded: body.Decoded,
    workspace: []u8,
    layout: application_input.DecoderLayout,
    csrf_state: ?*csrf_request.State,
    comptime csrf_form_name: ?[]const u8,
) MaterializeError!Spec.Target {
    const bytes = switch (decoded) {
        .bytes => |value| value,
        else => return error.InvariantViolation,
    };
    try checkBodyBytes(bytes, workspace, layout.body, decoderDecodedMax(Spec));
    const input = bytes.single() orelse return error.InvariantViolation;
    var fragment = flat_wire.Fragment.init(input);
    const pairs = try typedRegion(flat_wire.Pair, workspace, layout.pairs);
    const decoded_bytes = try byteRegion(workspace, layout.decoded);
    var table = flat_wire.parse(
        Spec.resolved_options.segments_max,
        .form,
        (&fragment)[0..1],
        pairs,
        decoded_bytes,
    ) catch |problem| return mapFormParseError(problem);
    if (comptime csrf_form_name) |name| {
        const state = csrf_state orelse return error.InvariantViolation;
        var retained: usize = 0;
        for (table.pairs) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                _ = state.observe(.form, pair.value);
            } else {
                pairs[retained] = pair;
                retained += 1;
            }
        }
        table.pairs = pairs[0..retained];
        if (!state.completeBody()) return error.CsrfForbidden;
    }
    return materializeFlat(Spec, table, workspace, layout.binding);
}

fn materializeFlat(
    comptime Spec: type,
    table: flat_wire.Table,
    workspace: []u8,
    binding_region: application_input.Region,
) MaterializeError!Spec.Target {
    if (comptime Spec.is_raw) return table;
    var arena = flat_schema.Arena.init(try byteRegion(workspace, binding_region));
    return switch (flat_schema.bind(Spec.Target, table, &arena, .{
        .unknown_fields = Spec.resolved_options.unknown_fields,
    })) {
        .ready => |value| value,
        .rejected => |issue| switch (issue.class) {
            .insufficient_storage => error.InvariantViolation,
            else => error.BadRequest,
        },
    };
}

fn materializeJson(
    comptime Spec: type,
    decoded: body.Decoded,
    workspace: []u8,
    layout: application_input.DecoderLayout,
    hash_key: [16]u8,
) MaterializeError!Spec.Target {
    const bytes = switch (decoded) {
        .bytes => |value| value,
        else => return error.InvariantViolation,
    };
    try checkBodyBytes(bytes, workspace, layout.body, decoderDecodedMax(Spec));
    const parse_bytes = try alignedByteRegion(
        workspace,
        layout.parse,
        json_validate.scratch_alignment,
    );
    const result = json_decode.decode(Spec.Target, bytes, parse_bytes, .{
        .hash_key = hash_key,
        .depth_max = jsonDepthMax(Spec),
        .unknown_fields = jsonUnknownFields(Spec),
    }) catch |problem| return mapJsonError(problem);
    return result.value.*;
}

fn checkBodyBytes(
    bytes: body.Bytes,
    workspace: []u8,
    region: application_input.Region,
    bytes_max: u64,
) MaterializeError!void {
    if (bytes.len() > bytes_max) return error.PayloadTooLarge;
    const retained = try byteRegion(workspace, region);
    var chunks = bytes.iterator();
    while (chunks.next()) |chunk| {
        if (!sliceWithin(retained, chunk)) return error.InvariantViolation;
    }
}

fn expectNoBody(decoded: body.Decoded, selected_decoder: ?u8) InvariantError!void {
    if (selected_decoder != null or std.meta.activeTag(decoded) != .none) {
        return error.InvariantViolation;
    }
}

fn byteRegion(
    workspace: []u8,
    region: application_input.Region,
) InvariantError![]u8 {
    if (region.offset > workspace.len or region.bytes > workspace.len - region.offset) {
        return error.InvariantViolation;
    }
    const bytes = workspace[region.offset..][0..region.bytes];
    if (bytes.len != 0 and @intFromPtr(bytes.ptr) % region.alignment != 0) {
        return error.InvariantViolation;
    }
    return bytes;
}

fn typedRegion(
    comptime T: type,
    workspace: []u8,
    region: application_input.Region,
) InvariantError![]T {
    const bytes = try byteRegion(workspace, region);
    if (bytes.len % @sizeOf(T) != 0) return error.InvariantViolation;
    if (bytes.len == 0) return @as([*]T, @ptrFromInt(@alignOf(T)))[0..0];
    if (@intFromPtr(bytes.ptr) % @alignOf(T) != 0) return error.InvariantViolation;
    const pointer: [*]T = @ptrCast(@alignCast(bytes.ptr));
    return pointer[0 .. bytes.len / @sizeOf(T)];
}

fn alignedByteRegion(
    workspace: []u8,
    region: application_input.Region,
    comptime alignment: usize,
) InvariantError![]align(alignment) u8 {
    const bytes = try byteRegion(workspace, region);
    if (bytes.len == 0 or @intFromPtr(bytes.ptr) % alignment != 0) {
        return error.InvariantViolation;
    }
    return @alignCast(bytes);
}

fn sliceWithin(container: []const u8, value: []const u8) bool {
    if (value.len == 0) return true;
    const start = @intFromPtr(container.ptr);
    const address = @intFromPtr(value.ptr);
    return address >= start and address - start <= container.len and
        value.len <= container.len - (address - start);
}

fn decoderDecodedMax(comptime Spec: type) u64 {
    if (@hasDecl(Spec, "decoded_bytes_max")) return Spec.decoded_bytes_max;
    return Spec.resolved_options.decoded_bytes_max;
}

fn jsonDepthMax(comptime Spec: type) u16 {
    if (@hasDecl(Spec, "depth_max")) return Spec.depth_max;
    if (@hasDecl(Spec, "resolved_options") and
        @hasField(@TypeOf(Spec.resolved_options), "depth_max"))
    {
        return Spec.resolved_options.depth_max;
    }
    return 64;
}

fn jsonUnknownFields(comptime Spec: type) json_decode.UnknownFields {
    if (@hasDecl(Spec, "unknown_fields")) {
        return mapUnknownFields(Spec.unknown_fields);
    }
    if (@hasDecl(Spec, "resolved_options") and
        @hasField(@TypeOf(Spec.resolved_options), "unknown_fields"))
    {
        return mapUnknownFields(Spec.resolved_options.unknown_fields);
    }
    return .ignore;
}

fn mapUnknownFields(value: anytype) json_decode.UnknownFields {
    return switch (value) {
        .ignore => .ignore,
        .reject => .reject,
    };
}

fn mapQueryParseError(problem: flat_wire.ParseError) MaterializeError {
    return switch (problem) {
        error.MalformedEncoding,
        error.InvalidCharacter,
        error.TooManySegments,
        error.InvalidUtf8,
        => error.BadRequest,
        error.InsufficientPairStorage,
        error.InsufficientByteStorage,
        => error.InvariantViolation,
    };
}

fn mapFormParseError(problem: flat_wire.ParseError) MaterializeError {
    return switch (problem) {
        error.TooManySegments => error.PayloadTooLarge,
        error.MalformedEncoding,
        error.InvalidCharacter,
        error.InvalidUtf8,
        => error.BadRequest,
        error.InsufficientPairStorage,
        error.InsufficientByteStorage,
        => error.InvariantViolation,
    };
}

fn mapJsonError(problem: json_decode.Error) MaterializeError {
    return switch (problem) {
        error.WorkspaceTooSmall => error.PayloadTooLarge,
        error.DepthLimitExceeded,
        error.DuplicateName,
        error.InvalidNumber,
        error.InvalidValue,
        error.LengthMismatch,
        error.MalformedCustomJson,
        error.MissingField,
        error.Overflow,
        error.Syntax,
        error.TypeMismatch,
        error.UnexpectedEnd,
        error.UnknownEnumTag,
        error.UnknownField,
        => error.BadRequest,
        error.CountOverflow,
        error.InvalidDepthLimit,
        error.PlanMismatch,
        error.ScannerCapacity,
        => error.InvariantViolation,
    };
}

test {
    std.testing.refAllDecls(@This());
}
