const std = @import("std");
const address = @import("../../src/address.zig");
const application_context = @import("../../src/application/context.zig");
const forwarding = @import("../../src/forwarding.zig");
const response = @import("../../src/response.zig");
const response_stream = @import("../../src/response/stream.zig");
const request_head = @import("../../src/internal/http1/request_head.zig");

test "context constructs its owned typed streaming response" {
    const State = struct {};
    const P = struct { id: u8 };
    const Limits = comptime response.HeadLimits.validate(.{
        .head_bytes_max = 256,
        .field_line_bytes_max = 64,
        .fields_max = 4,
    });
    const Context = application_context.Context(State, Limits);

    var state = State{};
    var workspace = Context.ResponseWorkspaceType{};
    var context = Context{
        .state = &state,
        .request = .{
            .method = "GET",
            .raw_target = "/stream",
            .raw_path = "/stream",
            .path = "/stream",
            .raw_query = null,
        },
        .response_workspace = &workspace,
    };
    const result = try context.stream(
        .ok,
        response.media.text,
        response_stream.unknown(P{ .id = 9 }, &.{"digest"}),
    );
    try std.testing.expect(@TypeOf(result) == Context.StreamResponse(P));
    try result.validateOwned(&workspace);
    try std.testing.expectEqual(@as(u8, 9), result.stream.producer.id);

    const unknown_result = context.streamUnknown(
        .ok,
        response.media.json,
        P{ .id = 10 },
        &.{"digest"},
    );
    try unknown_result.validateOwned(&workspace);
    try std.testing.expect(unknown_result.stream.framing == .unknown);
    try std.testing.expectEqualStrings("digest", unknown_result.stream.trailer_names[0]);

    const exact_result = context.streamExact(
        .created,
        response.media.text,
        42,
        P{ .id = 11 },
    );
    try exact_result.validateOwned(&workspace);
    try std.testing.expectEqual(@as(u64, 42), exact_result.stream.framing.exact);
    try std.testing.expectEqual(@as(usize, 0), exact_result.stream.trailer_names.len);
}

test "dynamic finite responses copy and format into request-owned storage" {
    const State = struct {};
    const Context = application_context.Context(State, response.standard_head_limits);
    var state = State{};
    var workspace = Context.ResponseWorkspaceType{};
    var body_storage: [16]u8 = undefined;
    var context = Context{
        .state = &state,
        .request = .{
            .method = "GET",
            .raw_target = "/",
            .raw_path = "/",
            .path = "/",
            .raw_query = null,
        },
        .response_workspace = &workspace,
        .response_body = &body_storage,
    };
    var transient = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const text_response = try context.text(.ok, &transient);
    @memset(&transient, 'x');
    try std.testing.expectEqualStrings("hello", text_response.bodyBytes());

    const formatted = try context.textFormat(.ok, "id={d}", .{@as(u16, 42)});
    try std.testing.expectEqualStrings("id=42", formatted.bodyBytes());
    const bytes_response = try context.bytes(.created, &.{ 0, 1, 2 });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, bytes_response.bodyBytes());
    try std.testing.expectError(
        error.ResponseBodyTooLarge,
        context.text(.ok, "0123456789abcdefg"),
    );

    context.response_body = null;
    try std.testing.expectError(
        error.ResponseBodyWorkspaceUnavailable,
        context.bytes(.ok, "x"),
    );
}

test "request headers preserve field order and explicit cardinality" {
    const wire =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.test\r\n" ++
        "X-Test: first\r\n" ++
        "x-test:\tsecond \r\n\r\n";
    const Decoder = request_head.Decoder(
        @import("../../src/internal/http1/limits.zig").standard_request_head_limits,
    );
    var decoder = Decoder.init();
    switch (decoder.feed(wire).state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    const headers = application_context.RequestHeaders{
        .bytes = decoder.bytes(),
        .fields = decoder.fields(),
    };
    const values = headers.all("X-TEST");
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectError(error.Multiple, values.one());
    var iterator = values.iterator();
    try std.testing.expectEqualStrings("first", iterator.next().?);
    try std.testing.expectEqualStrings("second", iterator.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iterator.next());
    try std.testing.expectEqualStrings("first", headers.first("x-test").?);
    try std.testing.expectError(error.Multiple, headers.one("x-test"));
    try std.testing.expectEqualStrings("example.test", try headers.one("host"));
    try std.testing.expectError(error.Missing, headers.one("missing"));
}

test "request forwarding conveniences preserve typed identity and provenance" {
    const transport = address.Endpoint.initIpv4(.{ 10, 0, 0, 1 }, 443);
    const client = address.Endpoint.initIpv4(.{ 192, 0, 2, 7 }, 5080);
    const effective = try @import("../../src/internal/http1/authority.zig").parse(
        "app.example",
        .https,
    );
    const request = application_context.Request{
        .method = "GET",
        .raw_target = "/",
        .raw_path = "/",
        .path = "/",
        .raw_query = null,
        .forwarding = .{
            .transport_peer = transport,
            .connection_peer = transport,
            .client = client,
            .authority = effective,
            .scheme = .https,
            .connection_source = .transport,
            .client_provenance = .x_forwarded,
            .host_provenance = .x_forwarded_host,
            .scheme_provenance = .x_forwarded_proto,
            .forwarding_headers = .applied,
            .trusted_hops = 1,
        },
    };
    try std.testing.expect(request.clientEndpoint().?.eql(client));
    try std.testing.expect(request.clientIp().?.eql(client.address));
    try std.testing.expect(request.transportPeer().?.eql(transport));
    try std.testing.expect(request.effectiveAuthority().?.eql(effective));
    try std.testing.expect(request.effectiveHost().?.eql(effective.host));
    try std.testing.expectEqual(forwarding.Scheme.https, request.effectiveScheme().?);
    const provenance = request.forwardingProvenance().?;
    try std.testing.expectEqual(forwarding.ClientProvenance.x_forwarded, provenance.client);
    try std.testing.expectEqual(forwarding.HeaderDisposition.applied, provenance.headers);
    try std.testing.expectEqual(@as(u16, 1), provenance.trusted_hops);

    var client_buffer: [address.Address.formatted_bytes_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "192.0.2.7",
        try request.clientIp().?.formatInto(&client_buffer),
    );

    var direct = request;
    direct.forwarding = null;
    try std.testing.expect(direct.clientIp() == null);
    try std.testing.expect(direct.effectiveAuthority() == null);
    try std.testing.expect(direct.forwardingProvenance() == null);
}

test "forged request header spans cannot escape their borrowed bytes" {
    const malformed = [_]request_head.Field{
        .{
            .name = .{ .offset = 0, .length = 4 },
            .raw_value = .{ .offset = 4, .length = std.math.maxInt(u32) },
            .value = .{ .offset = 4, .length = std.math.maxInt(u32) },
        },
        .{
            .name = .{ .offset = std.math.maxInt(u32), .length = 1 },
            .raw_value = .{ .offset = 0, .length = 1 },
            .value = .{ .offset = 0, .length = 1 },
        },
    };
    const headers = application_context.RequestHeaders{ .bytes = "host", .fields = &malformed };
    try std.testing.expectEqual(@as(usize, 0), headers.all("host").count());
    try std.testing.expectEqual(@as(?[]const u8, null), headers.first("host"));
    try std.testing.expectError(error.Missing, headers.one("host"));
    try std.testing.expectEqual(@as(usize, 0), headers.raw().count());
}
