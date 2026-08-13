const std = @import("std");
const body = @import("../../body.zig");
const input_body = @import("../../input_body.zig");
const application_multipart_runtime = @import("multipart_runtime.zig");
const application_multipart_upload_runtime = @import("multipart_upload_runtime.zig");
const flat_wire = @import("../flat/wire.zig");
const input_plan = @import("input_plan.zig");

const json_parse_bytes_standard_max: usize = 2 * 1024 * 1024;
const media_per_decoder_hard_max: usize = 4;

const json_media = [_]body.MediaPattern{
    .{ .exact = "application/json" },
    .{ .subtype_suffix = .{ .type = "application", .suffix = "json" } },
};

pub const Region = struct {
    offset: usize,
    bytes: usize,
    alignment: usize,

    pub fn end(region: Region) usize {
        return region.offset + region.bytes;
    }
};

pub const DecoderLayout = struct {
    body: Region,
    pairs: Region,
    decoded: Region,
    binding: Region,
    parse: Region,
    bytes_max: usize,
};

pub const WorkspaceLayout = struct {
    query_pairs: Region,
    query_decoded: Region,
    query_binding: Region,
    query_offset: usize,
    query_bytes_max: usize,
    body_offset: usize,
    body_bytes_max: usize,
    response_json: Region,
    total_bytes_max: usize,
    alignment: usize,
    body_decoders: []const DecoderLayout,
};

pub const Issue = enum(u8) {
    decoder_count,
    media_count,
    media_overlap,
    encoded_limit_zero,
    decoded_limit_zero,
    invalid_json_media,
    invalid_form_media,
    invalid_multipart_spec,
    invalid_multipart_media,
    parse_limit_zero,
    invalid_alignment,
};

pub fn plan(comptime Handler: type) input_plan.Plan {
    return Layout(Handler).value;
}

pub fn workspaceLayout(comptime Handler: type) WorkspaceLayout {
    return Layout(Handler).workspace;
}

pub fn issue(comptime Handler: type) ?Issue {
    return comptime layoutIssue(Handler.definition);
}

pub fn mediaOverlap(left: body.MediaPattern, right: body.MediaPattern) bool {
    return switch (left) {
        .exact => |value| exactOverlaps(value, right),
        .type_wildcard => |value| typeOverlaps(value, right),
        .subtype_suffix => |value| suffixOverlaps(value, right),
        .global_wildcard => true,
    };
}

fn Layout(comptime Handler: type) type {
    const Definition = Handler.definition;
    const problem = comptime layoutIssue(Definition);
    if (problem) |value| @compileError(issueDiagnostic(value));
    return struct {
        const decoders = makeDecoders(Definition);
        const accepted_media = makeMedia(Definition);
        const media_decoder_indices = makeMediaDecoderIndices(Definition);
        const body_layouts = makeBodyLayouts(Handler);
        const body_bytes = maximumBodyBytes(&body_layouts);
        const query = makeQueryLayout(Definition, body_bytes);
        const workspace = makeWorkspace(Definition, query, body_bytes, &body_layouts);
        const value = makePlan(
            Definition,
            &decoders,
            &accepted_media,
            &media_decoder_indices,
            workspace,
        );
    };
}

const QueryLayout = struct {
    pairs: Region,
    decoded: Region,
    binding: Region,
    bytes_max: usize,
};

fn makeQueryLayout(comptime Definition: type, base: usize) QueryLayout {
    if (!Definition.query_enabled) {
        const empty = Region{ .offset = base, .bytes = 0, .alignment = 1 };
        return .{ .pairs = empty, .decoded = empty, .binding = empty, .bytes_max = 0 };
    }
    const Spec = @TypeOf(Definition.query_spec);
    var cursor = base;
    const pairs = placeRegion(&cursor, Spec.pair_bytes_max, @alignOf(flat_wire.Pair));
    const decoded = placeRegion(&cursor, Spec.decoded_bytes_max, 1);
    const binding = placeRegion(&cursor, Spec.binding_bytes_max, storageAlignment(Spec.Target));
    return .{
        .pairs = pairs,
        .decoded = decoded,
        .binding = binding,
        .bytes_max = cursor - base,
    };
}

fn makeBodyLayouts(comptime Handler: type) [decoderCount(Handler.definition)]DecoderLayout {
    const Definition = Handler.definition;
    var result: [decoderCount(Definition)]DecoderLayout = undefined;
    if (!Definition.body_enabled) return result;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(BodySpec)) {
        result[0] = decoderLayout(Handler, BodySpec);
    } else {
        const configured = BodySpec.configured_decoders;
        inline for (@typeInfo(@TypeOf(configured)).@"struct".fields, 0..) |field, index| {
            result[index] = decoderLayout(
                Handler,
                @TypeOf(@field(configured, field.name)),
            );
        }
    }
    return result;
}

fn decoderLayout(comptime Handler: type, comptime Spec: type) DecoderLayout {
    var cursor: usize = 0;
    const body_bytes = if (Spec.decoder_kind == .multipart)
        0
    else
        toUsize(decoderDecodedMax(Spec));
    const body_region = placeRegion(&cursor, body_bytes, 1);
    const pairs = placeRegion(&cursor, decoderPairBytes(Spec), @alignOf(flat_wire.Pair));
    const decoded = if (Spec.decoder_kind == .form)
        body_region
    else
        Region{ .offset = cursor, .bytes = 0, .alignment = 1 };
    const binding = placeRegion(
        &cursor,
        decoderBindingBytes(Spec),
        storageAlignment(Spec.Target),
    );
    const parse = placeRegion(
        &cursor,
        decoderParseBytes(Handler, Spec),
        decoderParseAlignment(Handler, Spec),
    );
    return .{
        .body = body_region,
        .pairs = pairs,
        .decoded = decoded,
        .binding = binding,
        .parse = parse,
        .bytes_max = cursor,
    };
}

fn makeWorkspace(
    comptime Definition: type,
    query: QueryLayout,
    body_bytes: usize,
    body_layouts: []const DecoderLayout,
) WorkspaceLayout {
    var cursor = addBounded(query.bytes_max, body_bytes);
    const response_json = placeRegion(
        &cursor,
        Definition.response_json_bytes_max,
        1,
    );
    var alignment: usize = @max(
        query.pairs.alignment,
        @max(query.decoded.alignment, query.binding.alignment),
    );
    for (body_layouts) |layout| {
        alignment = @max(alignment, decoderLayoutAlignment(layout));
    }
    alignment = @max(alignment, response_json.alignment);
    return .{
        .query_pairs = query.pairs,
        .query_decoded = query.decoded,
        .query_binding = query.binding,
        .query_offset = body_bytes,
        .query_bytes_max = query.bytes_max,
        .body_offset = 0,
        .body_bytes_max = body_bytes,
        .response_json = response_json,
        .total_bytes_max = cursor,
        .alignment = alignment,
        .body_decoders = body_layouts,
    };
}

fn decoderLayoutAlignment(layout: DecoderLayout) usize {
    return @max(
        @max(layout.body.alignment, layout.pairs.alignment),
        @max(
            layout.decoded.alignment,
            @max(layout.binding.alignment, layout.parse.alignment),
        ),
    );
}

fn maximumBodyBytes(body_layouts: []const DecoderLayout) usize {
    var result: usize = 0;
    for (body_layouts) |layout| result = @max(result, layout.bytes_max);
    return result;
}

fn makePlan(
    comptime Definition: type,
    decoders: []const input_plan.Decoder,
    media: []const body.MediaPattern,
    media_indices: []const u8,
    workspace: WorkspaceLayout,
) input_plan.Plan {
    var encoded_max: u64 = 0;
    var decoded_max: u64 = 0;
    for (decoders) |decoder| {
        encoded_max = @max(encoded_max, decoder.encoded_wire_bytes_max);
        decoded_max = @max(decoded_max, decoder.decoded_bytes_max);
    }
    return .{
        .kind = if (Definition.body_enabled) .structured else .input,
        .encoded_wire_bytes_max = encoded_max,
        .decoded_bytes_max = decoded_max,
        .accepted_media = media,
        .media_decoder_indices = media_indices,
        .decoders = decoders,
        .selected_decoder = null,
        .workspace_bytes_max = workspace.total_bytes_max,
        .workspace_alignment = @intCast(workspace.alignment),
        .workspace_class = @intFromBool(workspace.total_bytes_max != 0),
    };
}

fn makeDecoders(
    comptime Definition: type,
) [decoderCount(Definition)]input_plan.Decoder {
    var result: [decoderCount(Definition)]input_plan.Decoder = undefined;
    if (!Definition.body_enabled) return result;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(BodySpec)) {
        result[0] = decoderPlan(BodySpec);
    } else {
        const configured = BodySpec.configured_decoders;
        inline for (@typeInfo(@TypeOf(configured)).@"struct".fields, 0..) |field, index| {
            result[index] = decoderPlan(@TypeOf(@field(configured, field.name)));
        }
    }
    return result;
}

fn decoderPlan(comptime Spec: type) input_plan.Decoder {
    return .{
        .kind = Spec.decoder_kind,
        .encoded_wire_bytes_max = decoderEncodedMax(Spec),
        .decoded_bytes_max = decoderDecodedMax(Spec),
        .multipart_boundary_bytes_max = if (Spec.decoder_kind == .multipart)
            Spec.resolved_options.limits.boundary_bytes_max
        else
            0,
        .csrf_body_source = Spec.decoder_kind == .multipart and
            @hasDecl(Spec, "ploof_csrf_field_name") and
            Spec.ploof_csrf_field_name != null,
    };
}

fn makeMedia(comptime Definition: type) [mediaCount(Definition)]body.MediaPattern {
    var result: [mediaCount(Definition)]body.MediaPattern = undefined;
    var index: usize = 0;
    appendDecoderMedia(Definition, &result, &index, false);
    return result;
}

fn makeMediaDecoderIndices(comptime Definition: type) [mediaCount(Definition)]u8 {
    var result: [mediaCount(Definition)]u8 = undefined;
    var index: usize = 0;
    appendDecoderMedia(Definition, &result, &index, true);
    return result;
}

fn appendDecoderMedia(
    comptime Definition: type,
    result: anytype,
    index: *usize,
    comptime indices: bool,
) void {
    if (!Definition.body_enabled) return;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(BodySpec)) {
        appendMedia(BodySpec, 0, result, index, indices);
    } else {
        const configured = BodySpec.configured_decoders;
        inline for (@typeInfo(@TypeOf(configured)).@"struct".fields, 0..) |field, decoder| {
            appendMedia(
                @TypeOf(@field(configured, field.name)),
                decoder,
                result,
                index,
                indices,
            );
        }
    }
}

fn appendMedia(
    comptime Spec: type,
    comptime decoder: usize,
    result: anytype,
    index: *usize,
    comptime indices: bool,
) void {
    for (decoderMedia(Spec)) |pattern| {
        result[index.*] = if (indices) @as(u8, @intCast(decoder)) else pattern;
        index.* += 1;
    }
}

fn layoutIssue(comptime Definition: type) ?Issue {
    @setEvalBranchQuota(100_000);
    if (!Definition.body_enabled) return null;
    const count = decoderCount(Definition);
    if (count == 0 or count > input_body.decoders_hard_max) return .decoder_count;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(BodySpec)) {
        if (decoderIssue(BodySpec)) |problem| return problem;
    } else {
        const configured = BodySpec.configured_decoders;
        inline for (@typeInfo(@TypeOf(configured)).@"struct".fields) |field| {
            if (decoderIssue(@TypeOf(@field(configured, field.name)))) |problem| {
                return problem;
            }
        }
    }
    const media = makeMedia(Definition);
    for (media, 0..) |candidate, index| {
        for (media[0..index]) |previous| {
            if (mediaOverlap(candidate, previous)) return .media_overlap;
        }
    }
    return null;
}

fn decoderIssue(comptime Spec: type) ?Issue {
    const media = decoderMedia(Spec);
    if (media.len == 0 or media.len > media_per_decoder_hard_max) return .media_count;
    if (decoderEncodedMax(Spec) == 0) return .encoded_limit_zero;
    if (decoderDecodedMax(Spec) == 0) return .decoded_limit_zero;
    switch (Spec.decoder_kind) {
        .json => {
            if (!validJsonMedia(media)) return .invalid_json_media;
            if (jsonParseBytes(Spec) == 0) return .parse_limit_zero;
            if (!std.math.isPowerOfTwo(jsonParseAlignment(Spec)) or
                jsonParseAlignment(Spec) > std.math.maxInt(u32))
            {
                return .invalid_alignment;
            }
        },
        .form => if (!validFormMedia(media)) return .invalid_form_media,
        .multipart => {
            if (!validMultipartSpec(Spec)) return .invalid_multipart_spec;
            if (!validMultipartMedia(media)) return .invalid_multipart_media;
        },
        .bytes, .text => {},
    }
    return null;
}

fn decoderCount(comptime Definition: type) usize {
    if (!Definition.body_enabled) return 0;
    const Spec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(Spec)) return 1;
    return Spec.decoder_count;
}

fn mediaCount(comptime Definition: type) usize {
    if (!Definition.body_enabled) return 0;
    const Spec = @TypeOf(Definition.body_spec);
    if (input_body.isDecoder(Spec)) return decoderMedia(Spec).len;
    var result: usize = 0;
    const configured = Spec.configured_decoders;
    inline for (@typeInfo(@TypeOf(configured)).@"struct".fields) |field| {
        result += decoderMedia(@TypeOf(@field(configured, field.name))).len;
    }
    return result;
}

fn decoderMedia(comptime Spec: type) []const body.MediaPattern {
    if (@hasDecl(Spec, "accepted_media")) return Spec.accepted_media[0..];
    if (Spec.decoder_kind == .json) return &json_media;
    @compileError("PLOOF-E3250 body decoder must declare accepted_media");
}

fn decoderEncodedMax(comptime Spec: type) u64 {
    if (@hasDecl(Spec, "encoded_wire_bytes_max")) return Spec.encoded_wire_bytes_max;
    if (@hasDecl(Spec, "resolved_options")) {
        return Spec.resolved_options.encoded_wire_bytes_max;
    }
    @compileError("PLOOF-E3251 body decoder must declare encoded wire limit");
}

fn decoderDecodedMax(comptime Spec: type) u64 {
    if (@hasDecl(Spec, "decoded_bytes_max")) return Spec.decoded_bytes_max;
    if (@hasDecl(Spec, "resolved_options")) return Spec.resolved_options.decoded_bytes_max;
    @compileError("PLOOF-E3252 body decoder must declare decoded byte limit");
}

fn decoderPairBytes(comptime Spec: type) usize {
    return if (@hasDecl(Spec, "pair_bytes_max")) Spec.pair_bytes_max else 0;
}

fn decoderBindingBytes(comptime Spec: type) usize {
    return if (@hasDecl(Spec, "binding_bytes_max")) Spec.binding_bytes_max else 0;
}

fn decoderParseBytes(comptime Handler: type, comptime Spec: type) usize {
    return switch (Spec.decoder_kind) {
        .json => jsonParseBytes(Spec),
        .multipart => @sizeOf(multipartRuntime(Handler, Spec)),
        .bytes, .text, .form => 0,
    };
}

fn decoderParseAlignment(comptime Handler: type, comptime Spec: type) usize {
    return switch (Spec.decoder_kind) {
        .json => jsonParseAlignment(Spec),
        .multipart => @alignOf(multipartRuntime(Handler, Spec)),
        .bytes, .text, .form => 1,
    };
}

fn multipartRuntime(comptime Handler: type, comptime Spec: type) type {
    if (comptime Spec.File == void) return application_multipart_runtime.Runtime(Handler);
    return application_multipart_upload_runtime.Runtime(Handler);
}

fn jsonParseBytes(comptime Spec: type) usize {
    if (@hasDecl(Spec, "parse_memory_bytes_max")) return Spec.parse_memory_bytes_max;
    return json_parse_bytes_standard_max;
}

fn jsonParseAlignment(comptime Spec: type) usize {
    if (@hasDecl(Spec, "parse_memory_alignment")) return Spec.parse_memory_alignment;
    return @max(@alignOf(usize), storageAlignment(Spec.Target));
}

fn validJsonMedia(media: []const body.MediaPattern) bool {
    if (media.len != json_media.len) return false;
    var exact = false;
    var suffix = false;
    for (media) |pattern| {
        exact = exact or patternsEqual(pattern, json_media[0]);
        suffix = suffix or patternsEqual(pattern, json_media[1]);
    }
    return exact and suffix;
}

fn validFormMedia(media: []const body.MediaPattern) bool {
    return media.len == 1 and switch (media[0]) {
        .exact => |value| eqlIgnoreCase(value, "application/x-www-form-urlencoded"),
        else => false,
    };
}

fn validMultipartSpec(comptime Spec: type) bool {
    return @typeInfo(Spec) == .@"struct" and
        @hasDecl(Spec, "ploof_multipart_push_decoder") and
        Spec.ploof_multipart_push_decoder;
}

fn validMultipartMedia(media: []const body.MediaPattern) bool {
    return media.len == 1 and switch (media[0]) {
        .exact => |value| eqlIgnoreCase(value, "multipart/form-data"),
        else => false,
    };
}

fn patternsEqual(left: body.MediaPattern, right: body.MediaPattern) bool {
    return switch (left) {
        .exact => |value| switch (right) {
            .exact => |other| eqlIgnoreCase(value, other),
            else => false,
        },
        .subtype_suffix => |value| switch (right) {
            .subtype_suffix => |other| eqlIgnoreCase(value.type, other.type) and
                eqlIgnoreCase(value.suffix, other.suffix),
            else => false,
        },
        .type_wildcard, .global_wildcard => false,
    };
}

fn exactOverlaps(exact: []const u8, pattern: body.MediaPattern) bool {
    const split = splitExact(exact) orelse return false;
    return switch (pattern) {
        .exact => |other| eqlIgnoreCase(exact, other),
        .type_wildcard => |value| eqlIgnoreCase(split.type, value),
        .subtype_suffix => |value| eqlIgnoreCase(split.type, value.type) and
            subtypeHasSuffix(split.subtype, value.suffix),
        .global_wildcard => true,
    };
}

fn typeOverlaps(value: []const u8, pattern: body.MediaPattern) bool {
    return switch (pattern) {
        .exact => |exact| exactOverlaps(exact, .{ .type_wildcard = value }),
        .type_wildcard => |other| eqlIgnoreCase(value, other),
        .subtype_suffix => |other| eqlIgnoreCase(value, other.type),
        .global_wildcard => true,
    };
}

fn suffixOverlaps(value: anytype, pattern: body.MediaPattern) bool {
    return switch (pattern) {
        .exact => |exact| exactOverlaps(exact, .{ .subtype_suffix = value }),
        .type_wildcard => |other| eqlIgnoreCase(value.type, other),
        .subtype_suffix => |other| eqlIgnoreCase(value.type, other.type) and
            suffixesOverlap(value.suffix, other.suffix),
        .global_wildcard => true,
    };
}

const Exact = struct { type: []const u8, subtype: []const u8 };

fn splitExact(value: []const u8) ?Exact {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    return .{ .type = value[0..slash], .subtype = value[slash + 1 ..] };
}

fn subtypeHasSuffix(subtype: []const u8, suffix: []const u8) bool {
    if (subtype.len <= suffix.len + 1) return false;
    const start = subtype.len - suffix.len;
    return subtype[start - 1] == '+' and eqlIgnoreCase(subtype[start..], suffix);
}

fn suffixesOverlap(left: []const u8, right: []const u8) bool {
    return eqlIgnoreCase(left, right) or endsWithPlusSuffix(left, right) or
        endsWithPlusSuffix(right, left);
}

fn endsWithPlusSuffix(value: []const u8, suffix: []const u8) bool {
    if (value.len <= suffix.len) return false;
    const start = value.len - suffix.len;
    return value[start - 1] == '+' and eqlIgnoreCase(value[start..], suffix);
}

fn eqlIgnoreCase(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn storageAlignment(comptime T: type) usize {
    return storageAlignmentInner(T, .{});
}

fn storageAlignmentInner(comptime T: type, comptime seen: anytype) usize {
    inline for (seen) |Seen| if (T == Seen) return 1;
    const next = seen ++ .{T};
    var result = @alignOf(T);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            result = @max(result, storageAlignmentInner(field.type, next));
        },
        .@"union" => |info| inline for (info.fields) |field| {
            result = @max(result, storageAlignmentInner(field.type, next));
        },
        .array => |info| {
            result = @max(result, storageAlignmentInner(info.child, next));
        },
        .optional => |info| {
            result = @max(result, storageAlignmentInner(info.child, next));
        },
        .pointer => |info| {
            result = @max(result, storageAlignmentInner(info.child, next));
        },
        else => {},
    }
    return result;
}

fn placeRegion(cursor: *usize, bytes: usize, alignment: usize) Region {
    if (bytes == 0) return .{ .offset = cursor.*, .bytes = 0, .alignment = alignment };
    const remainder = cursor.* % alignment;
    const padding = if (remainder == 0) 0 else alignment - remainder;
    const offset = addBounded(cursor.*, padding);
    cursor.* = addBounded(offset, bytes);
    return .{ .offset = offset, .bytes = bytes, .alignment = alignment };
}

fn addBounded(left: usize, right: usize) usize {
    return std.math.add(usize, left, right) catch {
        @compileError("PLOOF-E3253 input workspace size overflow");
    };
}

fn toUsize(value: u64) usize {
    if (value > std.math.maxInt(usize)) {
        @compileError("PLOOF-E3254 input workspace exceeds address space");
    }
    return @intCast(value);
}

fn issueDiagnostic(problem: Issue) []const u8 {
    return switch (problem) {
        .decoder_count => "PLOOF-E3255 body decoder count must be one to four",
        .media_count => "PLOOF-E3256 body decoder media count must be one to four",
        .media_overlap => "PLOOF-E3257 overlapping body decoder media patterns",
        .encoded_limit_zero => "PLOOF-E3258 body encoded byte limit must be nonzero",
        .decoded_limit_zero => "PLOOF-E3259 body decoded byte limit must be nonzero",
        .invalid_json_media => "PLOOF-E3260 JSON decoder media must cover JSON and +json",
        .invalid_form_media => "PLOOF-E3261 form decoder media must be exact urlencoded",
        .invalid_multipart_spec => "PLOOF-E3270 invalid multipart decoder declaration",
        .invalid_multipart_media => "PLOOF-E3271 multipart decoder media must be exact form-data",
        .parse_limit_zero => "PLOOF-E3262 JSON parse memory limit must be nonzero",
        .invalid_alignment => "PLOOF-E3263 JSON parse memory alignment must be a power of two",
    };
}

test "media overlap handles exact wildcard and suffix intersections" {
    const testing = std.testing;
    try testing.expect(mediaOverlap(
        .{ .exact = "application/problem+json" },
        .{ .subtype_suffix = .{ .type = "application", .suffix = "json" } },
    ));
    try testing.expect(mediaOverlap(
        .{ .type_wildcard = "text" },
        .{ .exact = "text/plain" },
    ));
    try testing.expect(!mediaOverlap(
        .{ .exact = "application/json" },
        .{ .exact = "application/xml" },
    ));
}
