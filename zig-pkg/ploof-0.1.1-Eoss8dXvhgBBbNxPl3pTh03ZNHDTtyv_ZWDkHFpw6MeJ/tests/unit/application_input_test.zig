const std = @import("std");
const application_input = @import("../../src/internal/application/input.zig");
const application_multipart_plan = @import("../../src/internal/application/multipart_plan.zig");
const application_multipart_runtime = @import(
    "../../src/internal/application/multipart_runtime.zig",
);
const application_multipart_upload_runtime = @import(
    "../../src/internal/application/multipart_upload_runtime.zig",
);
const body = @import("../../src/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const form = @import("../../src/form.zig");
const input_plan = @import("../../src/internal/application/input_plan.zig");
const json = @import("../../src/json.zig");
const multipart = @import("../../src/multipart.zig");
const query = @import("../../src/query.zig");

const MultipartTestContext = struct {
    pub const ResponseType = void;
};

test "media overlap handles exact wildcard and suffix intersections" {
    try std.testing.expect(application_input.mediaOverlap(
        .{ .exact = "application/problem+json" },
        .{ .subtype_suffix = .{ .type = "application", .suffix = "json" } },
    ));
    try std.testing.expect(application_input.mediaOverlap(
        .{ .type_wildcard = "text" },
        .{ .exact = "text/plain" },
    ));
    try std.testing.expect(!application_input.mediaOverlap(
        .{ .exact = "application/json" },
        .{ .exact = "application/xml" },
    ));
}

test "query-only endpoint receives a bounded nonzero workspace class" {
    const Target = struct { page: u16 = 1, tags: []const u16 = &.{} };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(Target, .{ .segments_max = 7 }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const plan = application_input.plan(@TypeOf(handler));
    const layout = application_input.workspaceLayout(@TypeOf(handler));

    try std.testing.expectEqual(input_plan.Kind.input, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), plan.decoders.len);
    try std.testing.expectEqual(@as(usize, 0), plan.accepted_media.len);
    try std.testing.expect(layout.query_pairs.bytes > 0);
    try std.testing.expectEqual(@as(usize, 0), layout.query_offset);
    try std.testing.expect(layout.query_decoded.bytes > 0);
    try std.testing.expect(layout.query_binding.bytes >= 7 * @sizeOf(u16));
    try std.testing.expectEqual(json.standard_encoded_bytes_max, layout.response_json.bytes);
    try std.testing.expectEqual(@as(usize, 1), layout.response_json.alignment);
    try std.testing.expectEqual(
        layout.query_offset + layout.query_bytes_max,
        layout.response_json.offset,
    );
    try std.testing.expectEqual(@as(u64, layout.total_bytes_max), plan.workspace_bytes_max);
    try std.testing.expectEqual(@as(u32, @intCast(layout.alignment)), plan.workspace_alignment);
    try std.testing.expectEqual(@as(u16, 1), plan.workspace_class);
}

test "direct form plan retains independent body limits and workspace regions" {
    const Target = struct { enabled: bool, values: []const u32 = &.{} };
    const Definition = endpoint.Endpoint(.{
        .body = form.typed(Target, .{
            .encoded_wire_bytes_max = 19,
            .decoded_bytes_max = 13,
            .segments_max = 5,
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const plan = application_input.plan(@TypeOf(handler));
    const layout = application_input.workspaceLayout(@TypeOf(handler));

    try std.testing.expectEqual(input_plan.Kind.structured, plan.kind);
    try std.testing.expectEqual(@as(usize, 1), plan.decoders.len);
    try std.testing.expectEqual(body.DecoderKind.form, plan.decoders[0].kind);
    try std.testing.expectEqual(@as(u64, 19), plan.encoded_wire_bytes_max);
    try std.testing.expectEqual(@as(u64, 13), plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(usize, 1), plan.accepted_media.len);
    try std.testing.expectEqual(@as(u8, 0), plan.media_decoder_indices[0]);
    try std.testing.expectEqual(@as(usize, 1), layout.body_decoders.len);
    try std.testing.expectEqual(@as(usize, 0), layout.body_decoders[0].body.offset);
    try std.testing.expectEqual(@as(usize, 13), layout.body_decoders[0].body.bytes);
    try std.testing.expect(layout.body_decoders[0].pairs.bytes > 0);
    try std.testing.expectEqual(@as(usize, 13), layout.body_decoders[0].decoded.bytes);
    try std.testing.expectEqual(
        layout.body_decoders[0].body.offset,
        layout.body_decoders[0].decoded.offset,
    );
    try std.testing.expect(layout.body_decoders[0].binding.bytes >= 5 * @sizeOf(u32));
    try std.testing.expectEqual(@as(u16, 1), plan.workspace_class);

    const selected = plan.selectMedia(0).?;
    try std.testing.expectEqual(body.DecoderKind.form, selected.decoderKind().?);
    try std.testing.expectEqual(@as(u64, 13), selected.decoded_bytes_max);
}

test "named alternatives flatten media and overlay decoder workspaces" {
    const JsonTarget = struct { id: u64 };
    const FormTarget = struct { id: u64 };
    const Json = JsonDecoder(JsonTarget, 31, 23, 47);
    const Definition = endpoint.Endpoint(.{
        .query = query.raw(.{ .segments_max = 3 }),
        .body = body.oneOf(.{
            .json = Json{},
            .form = form.typed(FormTarget, .{
                .encoded_wire_bytes_max = 17,
                .decoded_bytes_max = 11,
                .segments_max = 2,
            }),
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const plan = application_input.plan(@TypeOf(handler));
    const layout = application_input.workspaceLayout(@TypeOf(handler));

    try std.testing.expect(application_input.issue(@TypeOf(handler)) == null);
    try std.testing.expectEqual(@as(usize, 2), plan.decoders.len);
    try std.testing.expectEqual(@as(usize, 3), plan.accepted_media.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1 }, plan.media_decoder_indices);
    try std.testing.expectEqual(body.DecoderKind.json, plan.decoders[0].kind);
    try std.testing.expectEqual(body.DecoderKind.form, plan.decoders[1].kind);
    try std.testing.expectEqual(@as(u64, 31), plan.encoded_wire_bytes_max);
    try std.testing.expectEqual(@as(u64, 23), plan.decoded_bytes_max);
    try std.testing.expectEqual(@as(usize, 2), layout.body_decoders.len);
    try std.testing.expectEqual(@as(usize, 0), layout.body_decoders[0].body.offset);
    try std.testing.expectEqual(@as(usize, 23), layout.body_decoders[0].body.bytes);
    try std.testing.expectEqual(@as(usize, 47), layout.body_decoders[0].parse.bytes);
    try std.testing.expectEqual(@as(usize, 0), layout.body_offset);
    try std.testing.expectEqual(layout.body_bytes_max, layout.query_offset);
    try std.testing.expectEqual(
        layout.query_bytes_max + layout.body_bytes_max,
        layout.response_json.offset,
    );
    try std.testing.expectEqual(layout.response_json.end(), layout.total_bytes_max);
}

test "overlapping alternatives are diagnosed before plan construction" {
    const Target = struct { id: u8 };
    const same = [_]body.MediaPattern{.{ .exact = "application/example" }};
    const First = FakeDecoder(.bytes, Target, 9, 7, &same);
    const Second = FakeDecoder(.text, Target, 11, 5, &same);
    const Definition = endpoint.Endpoint(.{
        .body = body.oneOf(.{ .first = First{}, .second = Second{} }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.media_overlap,
        application_input.issue(@TypeOf(handler)).?,
    );
}

test "four alternatives and four media each retain bounded u8 dispatch" {
    const Target = struct { value: u8 };
    const a_media = [_]body.MediaPattern{
        .{ .exact = "a/one" },
        .{ .exact = "a/two" },
        .{ .exact = "a/three" },
        .{ .exact = "a/four" },
    };
    const BMedia = [_]body.MediaPattern{
        .{ .exact = "b/one" },
        .{ .exact = "b/two" },
        .{ .exact = "b/three" },
        .{ .exact = "b/four" },
    };
    const CMedia = [_]body.MediaPattern{
        .{ .exact = "c/one" },
        .{ .exact = "c/two" },
        .{ .exact = "c/three" },
        .{ .exact = "c/four" },
    };
    const DMedia = [_]body.MediaPattern{
        .{ .exact = "d/one" },
        .{ .exact = "d/two" },
        .{ .exact = "d/three" },
        .{ .exact = "d/four" },
    };
    const A = FakeDecoder(.bytes, Target, 4, 4, &a_media);
    const B = FakeDecoder(.bytes, Target, 4, 4, &BMedia);
    const C = FakeDecoder(.bytes, Target, 4, 4, &CMedia);
    const D = FakeDecoder(.bytes, Target, 4, 4, &DMedia);
    const Definition = endpoint.Endpoint(.{
        .body = body.oneOf(.{ .a = A{}, .b = B{}, .c = C{}, .d = D{} }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const plan = application_input.plan(@TypeOf(handler));
    try std.testing.expectEqual(@as(usize, 4), plan.decoders.len);
    try std.testing.expectEqual(@as(usize, 16), plan.accepted_media.len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 },
        plan.media_decoder_indices,
    );
}

test "query and form hard segment limits produce finite independent regions" {
    const QueryTarget = struct { values: []const u16 = &.{} };
    const FormTarget = struct { values: []const u32 = &.{} };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(QueryTarget, .{ .segments_max = query.segments_hard_max }),
        .body = form.typed(FormTarget, .{
            .decoded_bytes_max = 257,
            .segments_max = form.segments_hard_max,
        }),
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const layout = application_input.workspaceLayout(@TypeOf(handler));
    const plan = application_input.plan(@TypeOf(handler));

    try std.testing.expectEqual(
        query.segments_hard_max * @sizeOf(query.Pair),
        layout.query_pairs.bytes,
    );
    try std.testing.expectEqual(
        form.segments_hard_max * @sizeOf(form.Pair),
        layout.body_decoders[0].pairs.bytes,
    );
    try std.testing.expectEqual(@as(usize, 257), layout.body_decoders[0].decoded.bytes);
    try std.testing.expectEqual(@as(u64, 257), plan.decoded_bytes_max);
    try std.testing.expect(layout.total_bytes_max > layout.query_bytes_max);
}

test "decoder media policy issues are explicit without constructing a plan" {
    const Target = struct { value: u8 };
    const wrong_json_media = [_]body.MediaPattern{.{ .exact = "application/json" }};
    const WrongJson = FakeDecoder(.json, Target, 8, 8, &wrong_json_media);
    const json_definition = endpoint.Endpoint(.{ .body = WrongJson{} });
    const json_handler = json_definition.handle(struct {
        fn call(_: *u8, _: json_definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.invalid_json_media,
        application_input.issue(@TypeOf(json_handler)).?,
    );

    const wrong_form_media = [_]body.MediaPattern{.{ .type_wildcard = "application" }};
    const WrongForm = FakeDecoder(.form, Target, 8, 8, &wrong_form_media);
    const form_definition = endpoint.Endpoint(.{ .body = WrongForm{} });
    const form_handler = form_definition.handle(struct {
        fn call(_: *u8, _: form_definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.invalid_form_media,
        application_input.issue(@TypeOf(form_handler)).?,
    );
}

test "JSON media order is irrelevant and recursive target alignment is bounded" {
    const Node = struct { children: []const @This() };
    const Wide = struct { value: u8 align(64) };
    const Target = struct { wide: Wide, root: Node };
    const reversed = [_]body.MediaPattern{
        .{ .subtype_suffix = .{ .type = "application", .suffix = "json" } },
        .{ .exact = "Application/Json" },
    };
    const Json = FakeDecoder(.json, Target, 32, 24, &reversed);
    const Definition = endpoint.Endpoint(.{ .body = Json{} });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const layout = application_input.workspaceLayout(@TypeOf(handler));

    try std.testing.expect(application_input.issue(@TypeOf(handler)) == null);
    try std.testing.expectEqual(@as(usize, 0), layout.body_decoders[0].body.offset);
    try std.testing.expectEqual(
        @as(usize, 0),
        layout.body_decoders[0].parse.offset % @alignOf(Wide),
    );
}

test "duplicate media inside one direct decoder is rejected" {
    const Target = struct { value: u8 };
    const duplicate = [_]body.MediaPattern{
        .{ .exact = "application/example" },
        .{ .exact = "Application/Example" },
    };
    const Decoder = FakeDecoder(.bytes, Target, 8, 8, &duplicate);
    const Definition = endpoint.Endpoint(.{ .body = Decoder{} });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.media_overlap,
        application_input.issue(@TypeOf(handler)).?,
    );
}

test "JSON parse workspace rejects zero size and invalid alignment" {
    const Target = struct { value: u8 };
    const Zero = JsonWorkspaceDecoder(Target, 0, 1);
    const zero_definition = endpoint.Endpoint(.{ .body = Zero{} });
    const zero_handler = zero_definition.handle(struct {
        fn call(_: *u8, _: zero_definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.parse_limit_zero,
        application_input.issue(@TypeOf(zero_handler)).?,
    );

    const Misaligned = JsonWorkspaceDecoder(Target, 8, 3);
    const aligned_definition = endpoint.Endpoint(.{ .body = Misaligned{} });
    const aligned_handler = aligned_definition.handle(struct {
        fn call(_: *u8, _: aligned_definition.InputType) void {}
    }.call);
    try std.testing.expectEqual(
        application_input.Issue.invalid_alignment,
        application_input.issue(@TypeOf(aligned_handler)).?,
    );
}

test "response JSON override follows and does not overlap retained input" {
    const QueryTarget = struct { page: u32 = 0 };
    const FormTarget = struct { name: []const u8 };
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(QueryTarget, .{ .segments_max = 2 }),
        .body = form.typed(FormTarget, .{
            .decoded_bytes_max = 31,
            .segments_max = 3,
        }),
        .response_json_bytes_max = 73,
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, _: Definition.InputType) void {}
    }.call);
    const layout = application_input.workspaceLayout(@TypeOf(handler));
    const plan = application_input.plan(@TypeOf(handler));
    const decoder = layout.body_decoders[0];

    try std.testing.expectEqual(@as(usize, 73), layout.response_json.bytes);
    try std.testing.expect(layout.response_json.offset >= decoder.body.end());
    try std.testing.expect(layout.response_json.offset >= decoder.pairs.end());
    try std.testing.expect(layout.response_json.offset >= decoder.binding.end());
    try std.testing.expect(layout.response_json.offset >= layout.query_pairs.end());
    try std.testing.expect(layout.response_json.offset >= layout.query_decoded.end());
    try std.testing.expect(layout.response_json.offset >= layout.query_binding.end());
    try std.testing.expectEqual(layout.response_json.end(), layout.total_bytes_max);
    try std.testing.expectEqual(
        layout.body_bytes_max + layout.query_bytes_max + 73,
        layout.total_bytes_max,
    );
    try std.testing.expectEqual(@as(u64, layout.total_bytes_max), plan.workspace_bytes_max);
    try std.testing.expectEqual(
        @as(u32, @intCast(layout.alignment)),
        plan.workspace_alignment,
    );
}

test "multipart schema compiles exactly into the parser plan" {
    const schema = .{
        .age = multipart.field(u16, multipart.oneTo(2)),
        .token = multipart.bytes_field(multipart.optional),
        .upload = multipart.fileWithPolicy(
            multipart.DiscardSink,
            multipart.required,
            multipart.claimedMediaTypes(&.{ "image/png", "image/jpeg" }, .reject),
        ),
    };
    const spec = multipart.decode(schema, .{
        .limits = .{
            .encoded_wire_bytes_max = 5_000,
            .total_body_bytes_max = 4_096,
            .file_bytes_max = 2_048,
            .field_bytes_max = 257,
            .parts_max = 4,
            .files_max = 1,
            .part_headers_max = 7,
            .part_header_bytes_max = 97,
            .disposition_parameters_max = 5,
            .delimiter_transport_padding_bytes_max = 13,
            .name_bytes_max = 32,
            .filename_bytes_max = 44,
            .boundary_bytes_max = 23,
        },
        .unknown_parts = multipart.ignoreUnknown(211),
    });
    const Spec = @TypeOf(spec);
    const compiled = application_multipart_plan.compiledPlan(Spec);

    try std.testing.expectEqual(@as(usize, 3), compiled.entries.len);
    try expectMultipartEntry(compiled.entries[0], "age", .text, true, 2);
    try expectMultipartEntry(compiled.entries[1], "token", .bytes, false, 1);
    try expectMultipartEntry(compiled.entries[2], "upload", .file, true, 1);
    const claimed = compiled.entries[2].file_media.claimed;
    try std.testing.expectEqual(@as(usize, 2), claimed.values.len);
    try std.testing.expectEqualStrings("image", claimed.values[0].type);
    try std.testing.expectEqualStrings("png", claimed.values[0].subtype);
    try std.testing.expectEqualStrings("jpeg", claimed.values[1].subtype);
    try std.testing.expectEqual(.reject, claimed.missing);
    try std.testing.expectEqual(@as(u64, 211), compiled.unknown_parts.discard);
    try expectMultipartLimits(compiled.limits);

    const any_spec = multipart.decode(.{
        .upload = multipart.fileWithPolicy(
            multipart.DiscardSink,
            multipart.optional,
            multipart.anyClaimedMedia(.reject),
        ),
    }, .{});
    const any_plan = application_multipart_plan.compiledPlan(@TypeOf(any_spec));
    try std.testing.expectEqual(.reject, any_plan.entries[0].file_media.any);
}

test "multipart reserves fixed runtime state instead of its logical body limit" {
    const spec = multipart.decode(.{
        .csrf = multipart.field([]const u8, multipart.required),
        .upload = multipart.file(multipart.DiscardSink, multipart.optional),
    }, .{});
    const Spec = @TypeOf(spec);
    const State = struct {
        counter: usize,
        wide: u8 align(64),
    };
    const Definition = endpoint.Endpoint(.{
        .body = spec,
        .response_json_bytes_max = 257,
    });
    const handler = Definition.handle(MultipartConsumer(Spec, State){});
    const Handler = @TypeOf(handler);
    const Runtime = application_multipart_upload_runtime.Runtime(Handler);
    const layout = application_input.workspaceLayout(Handler);
    const plan = application_input.plan(Handler);
    const decoder = layout.body_decoders[0];

    try std.testing.expectEqual(body.DecoderKind.multipart, plan.decoders[0].kind);
    try std.testing.expectEqual(
        multipart.standard_limits.total_body_bytes_max,
        plan.decoded_bytes_max,
    );
    try std.testing.expectEqual(
        multipart.standard_limits.boundary_bytes_max,
        plan.decoders[0].multipart_boundary_bytes_max,
    );
    try std.testing.expectEqual(@as(usize, 0), decoder.body.bytes);
    try std.testing.expectEqual(@as(usize, 0), decoder.pairs.bytes);
    try std.testing.expectEqual(@as(usize, 0), decoder.decoded.bytes);
    try std.testing.expectEqual(@as(usize, 0), decoder.binding.bytes);
    try std.testing.expectEqual(@sizeOf(Runtime), decoder.parse.bytes);
    try std.testing.expectEqual(@alignOf(Runtime), decoder.parse.alignment);
    try std.testing.expectEqual(@as(usize, 0), decoder.parse.offset);
    try std.testing.expectEqual(decoder.parse.end(), layout.body_bytes_max);
    try std.testing.expect(layout.body_bytes_max < 256 * 1024);
    try std.testing.expect(layout.total_bytes_max < plan.decoded_bytes_max);
    try std.testing.expect(@sizeOf(Runtime) >= @sizeOf(State));
}

test "configured multipart buffers determine parser workspace" {
    const schema = .{
        .value = multipart.bytes_field(multipart.required),
    };
    const compact = multipart.decode(schema, .{ .limits = .{
        .total_body_bytes_max = 4_096,
        .file_bytes_max = 2_048,
        .field_bytes_max = 64,
        .part_header_bytes_max = 32,
        .delimiter_transport_padding_bytes_max = 8,
    } });
    const expanded = multipart.decode(schema, .{ .limits = .{
        .total_body_bytes_max = 4_096,
        .file_bytes_max = 2_048,
        .field_bytes_max = 512,
        .part_header_bytes_max = 256,
        .delimiter_transport_padding_bytes_max = 128,
    } });

    const Compact = @TypeOf(compact);
    const CompactDefinition = endpoint.Endpoint(.{ .body = compact });
    const compact_handler = CompactDefinition.handle(MultipartConsumer(Compact, void){});
    const compact_layout = application_input.workspaceLayout(@TypeOf(compact_handler));
    const Expanded = @TypeOf(expanded);
    const ExpandedDefinition = endpoint.Endpoint(.{ .body = expanded });
    const expanded_handler = ExpandedDefinition.handle(MultipartConsumer(Expanded, void){});
    const expanded_layout = application_input.workspaceLayout(@TypeOf(expanded_handler));

    try std.testing.expect(expanded_layout.body_bytes_max > compact_layout.body_bytes_max);
}

test "query and alternatives overlay multipart runtime with buffered bodies" {
    const upload = multipart.decode(.{
        .csrf = multipart.field([]const u8, multipart.required),
    }, .{ .limits = .{
        .encoded_wire_bytes_max = 9_001,
        .total_body_bytes_max = 9_000,
        .file_bytes_max = 8_000,
        .field_bytes_max = 1_111,
        .part_header_bytes_max = 333,
        .delimiter_transport_padding_bytes_max = 19,
        .boundary_bytes_max = 19,
    } });
    const Upload = @TypeOf(upload);
    const binary_media = [_]body.MediaPattern{.{ .exact = "application/octet-stream" }};
    const Definition = endpoint.Endpoint(.{
        .query = query.raw(.{ .segments_max = 3 }),
        .body = body.oneOf(.{
            .binary = body.raw(.{
                .encoded_wire_bytes_max = 31,
                .decoded_bytes_max = 23,
                .accepted_media = &binary_media,
            }),
            .upload = upload,
        }),
        .response_json_bytes_max = 41,
    });
    const handler = Definition.handle(MultipartConsumer(Upload, void){});
    const Handler = @TypeOf(handler);
    const Runtime = application_multipart_runtime.Runtime(Handler);
    const layout = application_input.workspaceLayout(Handler);
    const plan = application_input.plan(Handler);

    try std.testing.expectEqual(@as(usize, 2), layout.body_decoders.len);
    try std.testing.expectEqual(@as(usize, 23), layout.body_decoders[0].body.bytes);
    try std.testing.expectEqual(@as(usize, 0), layout.body_decoders[1].body.bytes);
    try std.testing.expectEqual(@sizeOf(Runtime), layout.body_decoders[1].parse.bytes);
    try std.testing.expectEqual(
        @max(layout.body_decoders[0].bytes_max, layout.body_decoders[1].bytes_max),
        layout.body_bytes_max,
    );
    try std.testing.expectEqual(layout.body_bytes_max, layout.query_offset);
    try std.testing.expect(layout.query_pairs.offset >= layout.body_bytes_max);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, plan.media_decoder_indices);
    try std.testing.expectEqual(@as(u8, 19), plan.decoders[1].multipart_boundary_bytes_max);
    try std.testing.expectEqual(
        layout.body_bytes_max + layout.query_bytes_max + 41,
        layout.total_bytes_max,
    );
}

fn MultipartConsumer(comptime Spec: type, comptime StateType: type) type {
    return struct {
        pub const State = StateType;

        pub fn init(_: anytype) State {
            return undefined;
        }

        pub fn field(_: *State, _: Spec.Field) void {}

        pub fn fileStart(
            _: @This(),
            _: *MultipartTestContext,
            _: *State,
            _: Spec.FileStart,
        ) Spec.FileAdmission(MultipartTestContext.ResponseType) {
            if (comptime Spec.FileStart != void) {
                return .{ .accept = .{ .upload = {} } };
            }
            unreachable;
        }

        pub fn complete(
            _: @This(),
            _: anytype,
            _: *State,
            _: anytype,
            _: Spec.Summaries,
        ) multipart.Decision(void) {
            return multipart.commit({});
        }
    };
}

fn expectMultipartEntry(
    entry: @import("../../src/internal/multipart/plan.zig").Entry,
    name: []const u8,
    kind: @import("../../src/internal/multipart/plan.zig").PartKind,
    required: bool,
    maximum: u16,
) !void {
    try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqual(kind, entry.kind);
    try std.testing.expectEqual(required, entry.required);
    try std.testing.expectEqual(maximum, entry.maximum);
}

fn expectMultipartLimits(limits: @import("../../src/internal/multipart/plan.zig").Limits) !void {
    try std.testing.expectEqual(@as(u64, 4_096), limits.total_body_bytes_max);
    try std.testing.expectEqual(@as(u64, 2_048), limits.file_bytes_max);
    try std.testing.expectEqual(@as(usize, 257), limits.field_bytes_max);
    try std.testing.expectEqual(@as(u16, 4), limits.parts_max);
    try std.testing.expectEqual(@as(u16, 1), limits.files_max);
    try std.testing.expectEqual(@as(u16, 7), limits.part_headers_max);
    try std.testing.expectEqual(@as(usize, 97), limits.part_header_bytes_max);
    try std.testing.expectEqual(@as(u8, 5), limits.disposition_parameters_max);
    try std.testing.expectEqual(@as(u16, 13), limits.delimiter_transport_padding_bytes_max);
    try std.testing.expectEqual(@as(usize, 32), limits.name_bytes_max);
    try std.testing.expectEqual(@as(usize, 44), limits.filename_bytes_max);
    try std.testing.expectEqual(@as(u8, 23), limits.boundary_bytes_max);
}

fn JsonDecoder(
    comptime TargetType: type,
    comptime encoded_max: u64,
    comptime decoded_max: u64,
    comptime parse_max: usize,
) type {
    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind: body.DecoderKind = .json;
        pub const Target = TargetType;
        pub const encoded_wire_bytes_max = encoded_max;
        pub const decoded_bytes_max = decoded_max;
        pub const parse_memory_bytes_max = parse_max;
    };
}

fn FakeDecoder(
    comptime kind: body.DecoderKind,
    comptime TargetType: type,
    comptime encoded_max: u64,
    comptime decoded_max: u64,
    comptime media: []const body.MediaPattern,
) type {
    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind = kind;
        pub const Target = TargetType;
        pub const encoded_wire_bytes_max = encoded_max;
        pub const decoded_bytes_max = decoded_max;
        pub const accepted_media = media;
    };
}

fn JsonWorkspaceDecoder(
    comptime TargetType: type,
    comptime parse_max: usize,
    comptime parse_alignment: usize,
) type {
    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const decoder_kind: body.DecoderKind = .json;
        pub const Target = TargetType;
        pub const encoded_wire_bytes_max: u64 = 8;
        pub const decoded_bytes_max: u64 = 8;
        pub const parse_memory_bytes_max = parse_max;
        pub const parse_memory_alignment = parse_alignment;
    };
}

test {
    std.testing.refAllDecls(application_input);
}
