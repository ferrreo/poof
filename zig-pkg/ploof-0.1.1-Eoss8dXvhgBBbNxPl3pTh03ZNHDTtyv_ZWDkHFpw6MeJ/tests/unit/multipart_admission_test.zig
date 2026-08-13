const std = @import("std");
const application = @import("../../src/application.zig");
const body = @import("../../src/body.zig");
const application_body = @import("../../src/internal/application/body.zig");
const application_adapter = @import("../../src/internal/runtime/application_adapter.zig");
const connection_admission = @import("../../src/internal/runtime/connection/admission.zig");
const http1_limits = @import("../../src/internal/http1/limits.zig");
const request_content = @import("../../src/internal/http1/request_content.zig");
const request_framing = @import("../../src/internal/http1/request_framing.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");

const Decoder = request_head.Decoder(http1_limits.standard_request_head_limits);
const media = [_]body.MediaPattern{.{ .exact = "multipart/form-data" }};
const decoders = [_]application_body.Decoder{.{
    .kind = .multipart,
    .encoded_wire_bytes_max = 1024,
    .decoded_bytes_max = 1024,
    .multipart_boundary_bytes_max = 70,
}};
const plan = application.BodyPlan{
    .kind = .structured,
    .encoded_wire_bytes_max = 1024,
    .decoded_bytes_max = 1024,
    .accepted_media = &media,
    .media_decoder_indices = &.{0},
    .decoders = &decoders,
    .selected_decoder = null,
    .workspace_bytes_max = 1,
    .workspace_alignment = 1,
    .workspace_class = 1,
};

test "multipart admission includes runtime gate checks" {
    _ = connection_admission;
}

test "multipart admission owns boundary across framing and coding" {
    const Case = struct {
        wire: []const u8,
        expected: []const u8,
        coding: request_content.Coding,
    };
    const cases = [_]Case{
        .{
            .wire = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n" ++
                "Content-Type: multipart/form-data; boundary=fixed\r\n\r\n",
            .expected = "fixed",
            .coding = .identity,
        },
        .{
            .wire = "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" ++
                "Content-Type: multipart/form-data; boundary=chunked\r\n\r\n",
            .expected = "chunked",
            .coding = .identity,
        },
        .{
            .wire = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 9\r\n" ++
                "Content-Encoding: gzip\r\nContent-Type: multipart/form-data; " ++
                "charset=nope; charset=still-nope; boundary=\"a\\'b\"\r\n\r\n",
            .expected = "a'b",
            .coding = .gzip,
        },
        .{
            .wire = "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n" ++
                "Content-Encoding: gzip\r\nContent-Type: multipart/form-data; " ++
                "boundary=gzip-chunked\r\n\r\n",
            .expected = "gzip-chunked",
            .coding = .gzip,
        },
    };
    for (cases) |case| {
        var decoder = Decoder.init();
        const framing = try decodeFraming(&decoder, case.wire);
        const admitted = switch (application_adapter.admitContent(
            plan,
            framing,
            decoder.fields(),
            decoder.bytes(),
        )) {
            .admitted => |value| value,
            .rejected, .invalid_plan => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.coding, admitted.content.?.coding);
        try std.testing.expectEqualStrings(
            case.expected,
            admitted.multipart_boundary.bytes().?,
        );
    }
}

test "multipart admission maps boundary failures exactly" {
    const seventy_one =
        "0123456789012345678901234567890123456789012345678901234567890123456789x";
    const cases = [_]struct { value: []const u8, status: request_head.Status }{
        .{ .value = "multipart/form-data", .status = .bad_request },
        .{ .value = "multipart/form-data; boundary=a; boundary=b", .status = .bad_request },
        .{ .value = "multipart/form-data; boundary=\"\"", .status = .bad_request },
        .{ .value = "multipart/form-data; boundary=\"a[b\"", .status = .bad_request },
        .{ .value = "multipart/form-data; boundary=" ++ seventy_one, .status = .bad_request },
        .{ .value = "multipart/form-data; boundary=route", .status = .payload_too_large },
    };
    for (cases, 0..) |case, index| {
        var route_decoders = decoders;
        if (index == cases.len - 1) route_decoders[0].multipart_boundary_bytes_max = 4;
        var route_plan = plan;
        route_plan.decoders = &route_decoders;
        var wire: [512]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &wire,
            "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n" ++
                "Content-Type: {s}\r\n\r\n",
            .{case.value},
        );
        const rejected = try expectRejected(route_plan, request);
        try std.testing.expectEqual(case.status, rejected.status);
        try std.testing.expect(rejected.close);
    }
}

test "multipart admission rejects invalid route boundary configuration" {
    var route_decoders = decoders;
    var route_plan = plan;
    route_plan.decoders = &route_decoders;
    const wire = "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n" ++
        "Content-Type: multipart/form-data; boundary=a\r\n\r\n";
    var decoder = Decoder.init();
    const framing = try decodeFraming(&decoder, wire);
    route_decoders[0].multipart_boundary_bytes_max = 1;
    const admitted = switch (application_adapter.admitContent(
        route_plan,
        framing,
        decoder.fields(),
        decoder.bytes(),
    )) {
        .admitted => |value| value,
        .rejected, .invalid_plan => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("a", admitted.multipart_boundary.bytes().?);
    route_decoders[0].multipart_boundary_bytes_max = 0;
    try expectInvalidPlan(route_plan, framing, &decoder);
    route_decoders[0].multipart_boundary_bytes_max = 71;
    try expectInvalidPlan(route_plan, framing, &decoder);
    route_decoders[0].kind = .json;
    route_decoders[0].multipart_boundary_bytes_max = 1;
    try expectInvalidPlan(route_plan, framing, &decoder);
}

fn expectRejected(route_plan: application.BodyPlan, wire: []const u8) !request_head.Rejection {
    var decoder = Decoder.init();
    const framing = try decodeFraming(&decoder, wire);
    return switch (application_adapter.admitContent(
        route_plan,
        framing,
        decoder.fields(),
        decoder.bytes(),
    )) {
        .rejected => |value| value,
        .admitted, .invalid_plan => error.TestUnexpectedResult,
    };
}

fn expectInvalidPlan(
    route_plan: application.BodyPlan,
    framing: request_framing.BodyFraming,
    decoder: *Decoder,
) !void {
    try std.testing.expect(application_adapter.admitContent(
        route_plan,
        framing,
        decoder.fields(),
        decoder.bytes(),
    ) == .invalid_plan);
}

fn decodeFraming(decoder: *Decoder, wire: []const u8) !request_framing.BodyFraming {
    decoder.* = Decoder.init();
    _ = switch (decoder.feed(wire).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    return switch (request_framing.analyze(decoder.fields(), decoder.bytes())) {
        .accepted => |value| value.body,
        .rejected => error.TestUnexpectedResult,
    };
}
