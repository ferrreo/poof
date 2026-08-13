const std = @import("std");
const body = @import("../../src/body.zig");
const endpoint = @import("../../src/endpoint.zig");
const multipart = @import("../../src/multipart.zig");

fn TestUploadSink(comptime Begin: type, comptime Result: type) type {
    return struct {
        pub const ploof_multipart_sink = true;
        pub const State = void;
        pub const WriteState = void;
        pub const Summary = Result;
        pub const BeginInput = Begin;
        pub const Runtime = void;
        pub const StartupState = void;
        pub const io_requirements = multipart.IoRequirements.none;
        pub const Error = error{};
        pub const request_handles_max: u8 = 0;
        pub const runtime_handles_max: u8 = 0;
        pub const initial_state: State = {};
        pub const initial_write_state: WriteState = {};
        pub const initial_startup_state: StartupState = {};

        pub fn runtimeStart(
            _: *StartupState,
            event: multipart.PollEvent(multipart.RuntimeStartInput),
        ) Error!multipart.Poll(Runtime) {
            return completeStart(multipart.RuntimeStartInput, Runtime, event, {});
        }

        pub fn runtimeStop(
            _: *Runtime,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return completeStart(void, void, event, {});
        }

        pub fn begin(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(BeginInput),
        ) Error!multipart.Poll(void) {
            return completeStart(BeginInput, void, event, {});
        }

        pub fn write(
            _: *Runtime,
            _: *State,
            _: *WriteState,
            event: multipart.PollEvent(multipart.WriteInput),
        ) Error!multipart.Poll(void) {
            return completeStart(multipart.WriteInput, void, event, {});
        }

        pub fn finish(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(multipart.FinishInput),
        ) Error!multipart.Poll(Summary) {
            _ = event;
            unreachable;
        }

        pub fn commit(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return completeStart(void, void, event, {});
        }

        pub fn abort(
            _: *Runtime,
            _: *State,
            event: multipart.PollEvent(void),
        ) Error!multipart.Poll(void) {
            return completeStart(void, void, event, {});
        }
    };
}

fn completeStart(
    comptime Input: type,
    comptime Output: type,
    event: multipart.PollEvent(Input),
    output: Output,
) multipart.Poll(Output) {
    return switch (event) {
        .start => .{ .done = output },
        .completion => unreachable,
    };
}
const query = @import("../../src/query.zig");

test "standard multipart limits match the documented profile" {
    const limits = multipart.standard_limits;
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), limits.total_body_bytes_max);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024), limits.file_bytes_max);
    try std.testing.expectEqual(@as(u64, 64 * 1024), limits.field_bytes_max);
    try std.testing.expectEqual(@as(u16, 8), limits.parts_max);
    try std.testing.expectEqual(@as(u16, 4), limits.files_max);
    try std.testing.expectEqual(@as(u16, 16), limits.part_headers_max);
    try std.testing.expectEqual(@as(u32, 8 * 1024), limits.part_header_bytes_max);
    try std.testing.expectEqual(@as(u8, 16), limits.disposition_parameters_max);
    try std.testing.expectEqual(@as(u16, 64), limits.delimiter_transport_padding_bytes_max);
    try std.testing.expectEqual(@as(u16, 128), limits.name_bytes_max);
    try std.testing.expectEqual(@as(u16, 255), limits.filename_bytes_max);
    try std.testing.expectEqual(@as(u8, 70), limits.boundary_bytes_max);
}

test "multipart limits reject inconsistent and above-hard profiles" {
    try std.testing.expectEqual(
        multipart.LimitIssue.part_header_bytes_below_minimum,
        (multipart.Limits{ .part_header_bytes_max = 1 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.LimitIssue.file_bytes_above_total,
        (multipart.Limits{
            .total_body_bytes_max = 3,
            .file_bytes_max = 4,
            .field_bytes_max = 3,
        }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.LimitIssue.files_above_parts,
        (multipart.Limits{ .parts_max = 1, .files_max = 2 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.LimitIssue.disposition_parameters_above_hard_max,
        (multipart.Limits{ .disposition_parameters_max = 65 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.LimitIssue.delimiter_transport_padding_above_hard_max,
        (multipart.Limits{ .delimiter_transport_padding_bytes_max = 1025 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.LimitIssue.boundary_bytes_above_hard_max,
        (multipart.Limits{ .boundary_bytes_max = 71 }).issue().?,
    );
}

test "multipart decoder composes with generic endpoint and exposes push metadata" {
    const spec = multipart.decode(.{
        .age = multipart.field(u16, multipart.required),
        .token = multipart.bytesField(multipart.optional),
        .uploads = multipart.fileWithPolicy(
            multipart.DiscardSink,
            multipart.oneTo(2),
            multipart.claimedMediaTypes(&.{"image/png"}, .reject),
        ),
    }, .{});
    const Spec = @TypeOf(spec);
    const Definition = endpoint.Endpoint(.{
        .query = query.typed(struct { trace: u16 = 0 }, .{}),
        .body = spec,
    });
    const age = Spec.Field{ .age = 42 };
    try std.testing.expectEqual(@as(u16, 42), age.age);
    try std.testing.expect(multipart.isSpec(Spec));
    try std.testing.expectEqual(body.DecoderKind.multipart, Spec.decoder_kind);
    try std.testing.expectEqualStrings("uploads", @tagName(Spec.File.uploads));
    const input = Definition.InputType{ .query = .{ .trace = 9 }, .body = .{} };
    try std.testing.expectEqual(@as(u16, 9), input.query.trace);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(input.body)));
    const Upload = @TypeOf(Spec.configured_schema.uploads);
    try std.testing.expect(Upload.SinkType == multipart.DiscardSink);
    try std.testing.expectEqualStrings("image", Upload.claimed_media_policy.exact.?[0].type);
    try std.testing.expect(multipart.DiscardSink.ploof_multipart_discard_sink);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(multipart.DiscardSink));
}

test "multipart decoder generates typed upload starts inputs and summary views" {
    const FirstSink = TestUploadSink(u32, struct { bytes: u64 });
    const SecondSink = TestUploadSink([]const u8, u8);
    const spec = multipart.decode(.{
        .avatar = multipart.file(FirstSink, multipart.oneTo(2)),
        .document = multipart.file(SecondSink, multipart.optional),
    }, .{});
    const Spec = @TypeOf(spec);
    const Response = struct { status: u16 };

    const start = Spec.FileStart{ .avatar = .{
        .part_name = "avatar",
        .occurrence = 1,
        .client_filename = null,
        .claimed_media_type = null,
    } };
    const input = Spec.BeginInput{ .avatar = 7 };
    const admission = Spec.FileAdmission(Response){ .accept = input };
    try std.testing.expectEqual(Spec.File.avatar, std.meta.activeTag(start));
    try std.testing.expectEqual(@as(u32, 7), admission.accept.avatar);

    const avatar_values = [_]FirstSink.Summary{
        .{ .bytes = 3 },
        .{ .bytes = 5 },
    };
    const document_values = [_]SecondSink.Summary{9};
    const summaries = Spec.Summaries{
        .avatar = .{ .values = &avatar_values, .len = 2 },
        .document = .{ .values = &document_values, .len = 1 },
    };
    try std.testing.expectEqual(@as(u64, 5), summaries.avatar.slice()[1].bytes);
    try std.testing.expectEqual(@as(u8, 9), summaries.document.slice()[0]);
}

test "schema totals and unknown discard stay within route limits" {
    const schema = .{
        .title = multipart.field([]const u8, multipart.oneTo(2)),
        .assets = multipart.file(multipart.DiscardSink, multipart.oneTo(2)),
    };
    const limits = multipart.Limits{
        .total_body_bytes_max = 1024,
        .file_bytes_max = 1024,
        .field_bytes_max = 1024,
        .parts_max = 4,
        .files_max = 2,
    };
    const Asset = @TypeOf(schema.assets);
    try std.testing.expect(Asset.claimed_media_policy.exact == null);
    try std.testing.expectEqual(
        multipart.MissingMedia.allow,
        Asset.claimed_media_policy.missing,
    );
    try std.testing.expect(multipart.schemaIssue(schema, .{
        .limits = limits,
        .unknown_parts = multipart.ignoreUnknown(512),
    }) == null);
    try std.testing.expectEqual(
        multipart.SchemaIssue.parts_above_limit,
        multipart.schemaIssue(schema, .{ .limits = multipart.Limits{
            .total_body_bytes_max = 1024,
            .file_bytes_max = 1024,
            .field_bytes_max = 1024,
            .parts_max = 3,
            .files_max = 2,
        } }).?,
    );
    try std.testing.expectEqual(
        multipart.SchemaIssue.ignored_part_bytes_above_total,
        multipart.schemaIssue(.{ .known = multipart.bytes_field(multipart.required) }, .{
            .limits = limits,
            .unknown_parts = .{ .ignore_unknown = 1025 },
        }).?,
    );
    try std.testing.expectEqual(
        multipart.SchemaIssue.ignored_part_bytes_zero,
        multipart.schemaIssue(.{ .known = multipart.bytes_field(multipart.required) }, .{
            .limits = limits,
            .unknown_parts = .{ .ignore_unknown = 0 },
        }).?,
    );
    try std.testing.expectEqual(
        multipart.SchemaIssue.name_too_long,
        multipart.schemaIssue(.{ .long = multipart.bytes_field(multipart.required) }, .{
            .limits = multipart.Limits{ .name_bytes_max = 3 },
        }).?,
    );
    try std.testing.expectEqual(
        multipart.SchemaIssue.not_named_struct,
        multipart.schemaIssue(.{multipart.bytes_field(multipart.required)}, .{}).?,
    );
    try std.testing.expectEqual(
        multipart.SchemaIssue.invalid_part,
        multipart.schemaIssue(.{ .known = 7 }, .{}).?,
    );
}

test "claimed file media policies are exact normalized and duplicate free" {
    const policy = multipart.claimedMediaTypes(&.{ "image/png", "image/jpeg" }, .allow);
    try std.testing.expectEqual(multipart.MissingMedia.allow, policy.missing);
    try std.testing.expectEqualStrings("jpeg", policy.exact.?[1].subtype);
    const duplicate = [_]multipart.MediaClaim{
        .{ .type = "image", .subtype = "png" },
        .{ .type = "image", .subtype = "png" },
    };
    try std.testing.expectEqual(
        multipart.MediaPolicyIssue.duplicate_claim,
        multipart.mediaPolicyIssue(.{ .exact = &duplicate, .missing = .reject }).?,
    );
    const upper = [_]multipart.MediaClaim{.{ .type = "Image", .subtype = "png" }};
    try std.testing.expectEqual(
        multipart.MediaPolicyIssue.claim_not_normalized,
        multipart.mediaPolicyIssue(.{ .exact = &upper, .missing = .allow }).?,
    );
    const empty = [_]multipart.MediaClaim{};
    try std.testing.expectEqual(
        multipart.MediaPolicyIssue.exact_list_empty,
        multipart.mediaPolicyIssue(.{ .exact = &empty, .missing = .allow }).?,
    );
}

test "multipart decoder remains a tagged body alternative" {
    const alternatives = body.oneOf(.{
        .upload = multipart.decode(.{
            .payload = multipart.bytes_field(multipart.required),
        }, .{}),
        .raw = body.raw(.{}),
    });
    const Alternatives = @TypeOf(alternatives);
    const input = Alternatives.Input{ .upload = .{} };
    try std.testing.expectEqualStrings("upload", @tagName(std.meta.activeTag(input)));
    try std.testing.expectEqual(@as(u8, 2), Alternatives.decoder_count);
    try std.testing.expect(multipart.required.isRequired());
    try std.testing.expect(multipart.oneTo(2).isRequired());
    try std.testing.expect(!multipart.optional.isRequired());
}
