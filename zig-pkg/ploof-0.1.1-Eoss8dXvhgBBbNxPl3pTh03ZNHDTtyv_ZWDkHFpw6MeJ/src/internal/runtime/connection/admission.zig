const std = @import("std");
const address = @import("../../../address.zig");
const forwarding = @import("../../../forwarding.zig");
const application_adapter = @import("../application_adapter.zig");
const authority = @import("../../http1/authority.zig");
const request_content = @import("../../http1/request_content.zig");
const request_framing = @import("../../http1/request_framing.zig");
const request_head = @import("../../http1/request_head.zig");
const request_proxy_identity = @import("../../http1/request_proxy_identity.zig");
const request_target = @import("../../http1/request_target.zig");

pub const Error = error{StateInvariant};

pub const ConnectionIdentity = struct {
    transport_peer: address.Endpoint,
    connection_peer: address.Endpoint,
    connection_source: forwarding.ConnectionSource = .transport,
    direct_scheme: authority.Scheme = .http,
};

const DirectProfile = forwarding.Profile(forwarding.standard_limits);
const direct_profile = DirectProfile.init(.{}) catch unreachable;
const direct_peer = address.Endpoint.initIpv4(.{ 127, 0, 0, 1 }, 0);

pub fn Gate(comptime App: type, comptime trailer_names_max: u16) type {
    const Admission = application_adapter.Admission(trailer_names_max);
    return struct {
        request: struct {
            analysis: @FieldType(Admission, "analysis"),
            expect_continue: bool,
            decoded_path_used: u32,
        },
        plan: App.Plan,
        coding: request_content.Coding,
        multipart_boundary: application_adapter.MultipartBoundary,
    };
}

pub fn Result(comptime App: type, comptime trailer_names_max: u16) type {
    return union(enum) {
        admitted: Gate(App, trailer_names_max),
        rejected: struct {
            response: request_head.Rejection,
            decoded_path_used: u32,
        },
        silent_close: struct { decoded_path_used: u32 },
    };
}

pub fn analyze(
    comptime App: type,
    comptime trailer_names_max: u16,
    route_workspace: anytype,
    decoder: anytype,
    head: request_head.Head,
    decoded_path: []u8,
    date: []const u8,
) Error!Result(App, trailer_names_max) {
    return analyzeForwarded(
        App,
        trailer_names_max,
        forwarding.standard_limits,
        &direct_profile,
        .{
            .transport_peer = direct_peer,
            .connection_peer = direct_peer,
        },
        route_workspace,
        decoder,
        head,
        decoded_path,
        date,
    );
}

pub fn analyzeForwarded(
    comptime App: type,
    comptime trailer_names_max: u16,
    comptime forwarding_limits: forwarding.Limits,
    profile: *const forwarding.Profile(forwarding_limits),
    identity: ConnectionIdentity,
    route_workspace: anytype,
    decoder: anytype,
    head: request_head.Head,
    decoded_path: []u8,
    date: []const u8,
) Error!Result(App, trailer_names_max) {
    var admission = switch (application_adapter.admit(
        trailer_names_max,
        decoder,
        head,
        decoded_path,
        date,
    )) {
        .admitted => |value| value,
        .rejected => |rejection| return .{ .rejected = .{
            .response = rejection,
            .decoded_path_used = 0,
        } },
    };
    const metadata = switch (request_proxy_identity.resolve(
        forwarding_limits,
        profile,
        .{
            .bytes = decoder.bytes(),
            .fields = decoder.fields(),
            .transport_peer = identity.transport_peer,
            .connection_peer = identity.connection_peer,
            .connection_source = identity.connection_source,
            .direct_scheme = identity.direct_scheme,
        },
    )) {
        .accepted => |value| value,
        .rejected => |rejection| switch (rejection) {
            .bad_request => return rejectAdmission(
                App,
                trailer_names_max,
                admission,
                .bad_request,
            ),
            .untrusted_peer => return .{ .silent_close = .{
                .decoded_path_used = admission.decoded_path_used,
            } },
        },
    };
    if (!absoluteTargetMatches(admission.analysis.target, metadata)) {
        return rejectAdmission(App, trailer_names_max, admission, .bad_request);
    }
    admission.input.forwarding = metadata;
    return admitContentAndFinish(
        App,
        trailer_names_max,
        decoder,
        admission,
        planApplication(App, admission.input, route_workspace),
    );
}

fn planApplication(comptime App: type, input: anytype, workspace: anytype) App.Plan {
    if (comptime @hasDecl(App, "RouteSearchWorkspace")) {
        return App.plan(input, workspace);
    }
    return App.plan(input);
}

fn admitContentAndFinish(
    comptime App: type,
    comptime trailer_names_max: u16,
    decoder: anytype,
    admission: application_adapter.Admission(trailer_names_max),
    initial_plan: App.Plan,
) Error!Result(App, trailer_names_max) {
    var plan = initial_plan;
    const content_admission = switch (application_adapter.admitContent(
        plan.body,
        admission.analysis.framing.body,
        decoder.fields(),
        decoder.bytes(),
    )) {
        .admitted => |value| value,
        .rejected => |rejection| return .{ .rejected = .{
            .response = rejection,
            .decoded_path_used = admission.decoded_path_used,
        } },
        .invalid_plan => return error.StateInvariant,
    };
    if (comptime @hasDecl(App, "__refinePlanBody")) {
        if (bodySelectionChanged(plan.body, content_admission.plan)) {
            App.__refinePlanBody(&plan, content_admission.plan) catch {
                return error.StateInvariant;
            };
        }
    } else {
        plan.body = content_admission.plan;
    }
    const content = content_admission.content;
    const coding: request_content.Coding = if (plan.body.kind != .none) coding: {
        if (plan.body.kind == .input) break :coding .identity;
        break :coding (content orelse return error.StateInvariant).coding;
    } else if (content != null) {
        return error.StateInvariant;
    } else .identity;
    return .{ .admitted = .{
        .request = .{
            .analysis = admission.analysis,
            .expect_continue = admission.expect_continue,
            .decoded_path_used = admission.decoded_path_used,
        },
        .plan = plan,
        .coding = coding,
        .multipart_boundary = content_admission.multipart_boundary,
    } };
}

fn bodySelectionChanged(
    planned: application_body.Plan,
    admitted: application_body.Plan,
) bool {
    return planned.selected_decoder != admitted.selected_decoder or
        planned.encoded_wire_bytes_max != admitted.encoded_wire_bytes_max or
        planned.decoded_bytes_max != admitted.decoded_bytes_max;
}

fn absoluteTargetMatches(target: request_target.Target, metadata: forwarding.Metadata) bool {
    const absolute = switch (target) {
        .absolute => |value| value,
        .origin, .asterisk => return true,
    };
    const scheme: authority.Scheme = switch (absolute.scheme) {
        .http => .http,
        .https => .https,
    };
    if (scheme != metadata.scheme) return false;
    const target_authority = authority.parse(absolute.authority_unverified, scheme) catch {
        return false;
    };
    return target_authority.eql(metadata.authority);
}

fn rejectAdmission(
    comptime App: type,
    comptime trailer_names_max: u16,
    admission: anytype,
    status: request_head.Status,
) Result(App, trailer_names_max) {
    return .{ .rejected = .{
        .response = .{ .status = status },
        .decoded_path_used = admission.decoded_path_used,
    } };
}

pub fn hasUnreadBody(framing: request_framing.BodyFraming) bool {
    return switch (framing) {
        .none => false,
        .fixed => |length| length != 0,
        .chunked => true,
    };
}

pub fn acquireRequest(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    workspace_class: u16,
    decoded_path_used: u32,
    now_ns: u64,
) DriverError!?u16 {
    const acquired = driver.storage.acquireRequestClassified(
        connection_index,
        workspace_class,
        false,
    );
    return switch (acquired) {
        .acquired => |index| index,
        .request_slots_exhausted,
        .body_workspace_exhausted,
        .chunked_workspace_exhausted,
        => {
            std.crypto.secureZero(
                u8,
                driver.storage.decodedPath(connection_index)[0..decoded_path_used],
            );
            try driver.startRejection(
                connection_index,
                .{ .status = .service_unavailable },
                now_ns,
            );
            return null;
        },
    };
}

pub fn requestWorkspace(
    storage: anytype,
    request_index: u16,
    workspace_class: u16,
) Error![]u8 {
    const Body = @TypeOf(storage.requests[request_index].body);
    if (comptime !@hasField(Body, "workspace_index")) {
        if (workspace_class != 0) return error.StateInvariant;
        return &.{};
    } else {
        if (workspace_class == 0) return &.{};
        return storage.bodyWorkspace(request_index) catch error.StateInvariant;
    }
}

pub const HeadReservation = struct {
    request_index: u16,
    workspace: []u8,
};

pub fn reserveHeadWorkspace(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    body_plan: anytype,
    decoded_path_used: u32,
    now_ns: u64,
) DriverError!?HeadReservation {
    const workspace_class = body_plan.headWorkspaceClass();
    const request_index = try acquireRequest(
        DriverError,
        driver,
        connection_index,
        workspace_class,
        decoded_path_used,
        now_ns,
    ) orelse return null;
    driver.storage.connections[connection_index].decoded_path_used = decoded_path_used;
    const workspace = requestWorkspace(
        driver.storage,
        request_index,
        workspace_class,
    ) catch {
        try driver.releaseRequest(connection_index, request_index);
        return error.StateInvariant;
    };
    return .{ .request_index = request_index, .workspace = workspace };
}

pub fn finishHead(
    comptime DriverError: type,
    driver: anytype,
    connection_index: u16,
    feed_state: request_head.FeedState,
    tail: []const u8,
    source: anytype,
    now_ns: u64,
) DriverError!void {
    switch (feed_state) {
        .need_more => if (tail.len != 0) return error.StateInvariant,
        .ready => |head| try driver.prepareResponse(
            connection_index,
            head,
            tail,
            source,
            now_ns,
        ),
        .rejected => |rejection| try driver.startRejection(
            connection_index,
            rejection,
            now_ns,
        ),
    }
}

const application_body = @import("../../application/body.zig");
const application_context = @import("../../../application/context.zig");
const body = @import("../../../body.zig");
const http1_limits = @import("../../http1/limits.zig");
const request_trailers = @import("../../http1/request_trailers.zig");

const TestApp = struct {
    pub const Plan = struct {
        input: application_context.Input,
        body: application_body.Plan,
    };

    pub fn plan(input: application_context.Input) Plan {
        std.debug.assert(input.forwarding != null);
        return .{ .input = input, .body = application_body.none_plan };
    }
};

const MultipartTestApp = struct {
    const media = [_]body.MediaPattern{
        .{ .exact = "multipart/form-data" },
    };
    const decoders = [_]application_body.Decoder{.{
        .kind = .multipart,
        .encoded_wire_bytes_max = 1024,
        .decoded_bytes_max = 1024,
        .multipart_boundary_bytes_max = 70,
    }};
    const body_plan = application_body.Plan{
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

    pub const Plan = struct {
        input: application_context.Input,
        body: application_body.Plan,
    };

    pub fn plan(input: application_context.Input) Plan {
        std.debug.assert(input.forwarding != null);
        return .{ .input = input, .body = body_plan };
    }
};

const test_forwarding_limits = forwarding.Limits{
    .trusted_matchers_max = 4,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};
const TestProfile = forwarding.Profile(test_forwarding_limits);
const TestDecoder = request_head.Decoder(http1_limits.standard_request_head_limits);
const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";

comptime {
    if (@sizeOf(TestApp.Plan) != 392) @compileError("admission Plan size drift");
    if (@sizeOf(Gate(TestApp, 8)) != 800) @compileError("admission Gate size drift");
}

test "forwarding admission distinguishes trusted and spoofed identity" {
    var harness = TestHarness{};
    const profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    const trusted = try harness.analyze(
        &profile,
        testIdentity("10.0.0.1"),
        "GET / HTTP/1.1\r\nHost: internal.test\r\n" ++
            "X-Forwarded-For: 192.0.2.7\r\n" ++
            "X-Forwarded-Host: public.test\r\n" ++
            "X-Forwarded-Proto: https\r\n\r\n",
    );
    const trusted_metadata = trusted.admitted.plan.input.forwarding.?;
    try std.testing.expectEqual(
        forwarding.ClientProvenance.x_forwarded,
        trusted_metadata.client_provenance,
    );
    try std.testing.expectEqual(authority.Scheme.https, trusted_metadata.scheme);

    const spoofed = try harness.analyze(
        &profile,
        testIdentity("192.0.2.9"),
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "X-Forwarded-For: malformed\r\n\r\n",
    );
    const spoofed_metadata = spoofed.admitted.plan.input.forwarding.?;
    try std.testing.expectEqual(
        forwarding.HeaderDisposition.ignored_untrusted,
        spoofed_metadata.forwarding_headers,
    );
    try std.testing.expectEqual(
        forwarding.ClientProvenance.transport,
        spoofed_metadata.client_provenance,
    );
}

test "forwarding admission validates absolute form against effective origin" {
    var harness = TestHarness{};
    const profile = try TestProfile.init(.{});
    const matching = try harness.analyze(
        &profile,
        testIdentity("192.0.2.9"),
        "GET http://EXAMPLE.test:80/ping HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try std.testing.expect(matching == .admitted);

    const scheme_mismatch = try harness.analyze(
        &profile,
        testIdentity("192.0.2.9"),
        "GET https://example.test/ping HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try expectBadRequest(scheme_mismatch);
    const host_mismatch = try harness.analyze(
        &profile,
        testIdentity("192.0.2.9"),
        "GET http://other.test/ping HTTP/1.1\r\nHost: example.test\r\n\r\n",
    );
    try expectBadRequest(host_mismatch);

    const edge_profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    const edge_match = try harness.analyze(
        &edge_profile,
        testIdentity("10.0.0.1"),
        "GET https://public.test/ping HTTP/1.1\r\nHost: internal.test\r\n" ++
            "X-Forwarded-Host: public.test\r\nX-Forwarded-Proto: https\r\n\r\n",
    );
    try std.testing.expect(edge_match == .admitted);
}

test "trusted malformed forwarding metadata rejects before application" {
    var harness = TestHarness{};
    const profile = try TestProfile.init(.{
        .family = .x_forwarded,
        .trusted = &.{"10.0.0.0/8"},
    });
    const result = try harness.analyze(
        &profile,
        testIdentity("10.0.0.1"),
        "GET / HTTP/1.1\r\nHost: direct.test\r\n" ++
            "X-Forwarded-Host: one.test\r\nX-Forwarded-Host: two.test\r\n\r\n",
    );
    try expectBadRequest(result);
}

test "proxy-only forwarding admission closes an untrusted transport silently" {
    var harness = TestHarness{};
    const profile = try TestProfile.init(.{
        .untrusted_peer = .reject,
        .trusted = &.{"10.0.0.0/8"},
    });
    const result = try harness.analyze(
        &profile,
        testIdentity("192.0.2.9"),
        "GET / HTTP/1.1\r\nHost: direct.test\r\n\r\n",
    );
    try std.testing.expect(result == .silent_close);
}

test "multipart gate owns decoded boundary after head storage reuse" {
    const wire = "POST /upload HTTP/1.1\r\nHost: direct.test\r\n" ++
        "Transfer-Encoding: chunked\r\nContent-Encoding: gzip\r\n" ++
        "Content-Type: multipart/form-data; boundary=\"owned boundary\"\r\n\r\n";
    var decoder = TestDecoder.init();
    const head = switch (decoder.feed(wire).state) {
        .ready => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var decoded_path: [http1_limits.standard_request_head_limits.request_line_bytes_max]u8 =
        undefined;
    var gate = switch (try analyze(
        MultipartTestApp,
        request_trailers.standard_names_max,
        .{},
        &decoder,
        head,
        &decoded_path,
        fixed_date,
    )) {
        .admitted => |value| value,
        .rejected, .silent_close => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(request_content.Coding.gzip, gate.coding);
    try std.testing.expectEqualStrings("owned boundary", gate.multipart_boundary.bytes().?);
    try std.testing.expectEqual(
        @intFromPtr(&gate.multipart_boundary.storage),
        @intFromPtr(gate.multipart_boundary.bytes().?.ptr),
    );

    decoder = TestDecoder.init();
    _ = decoder.feed(
        "GET / HTTP/1.1\r\nHost: overwritten.test\r\nX-Fill: overwritten\r\n\r\n",
    );
    try std.testing.expectEqualStrings("owned boundary", gate.multipart_boundary.bytes().?);
}

const TestHarness = struct {
    decoder: TestDecoder = TestDecoder.init(),
    decoded_path: [http1_limits.standard_request_head_limits.request_line_bytes_max]u8 = undefined,

    fn analyze(
        harness: *TestHarness,
        profile: *const TestProfile,
        identity: ConnectionIdentity,
        wire: []const u8,
    ) !Result(TestApp, request_trailers.standard_names_max) {
        harness.decoder = TestDecoder.init();
        const head = switch (harness.decoder.feed(wire).state) {
            .ready => |value| value,
            else => return error.TestUnexpectedResult,
        };
        return analyzeForwarded(
            TestApp,
            request_trailers.standard_names_max,
            test_forwarding_limits,
            profile,
            identity,
            .{},
            &harness.decoder,
            head,
            &harness.decoded_path,
            fixed_date,
        );
    }
};

fn testIdentity(raw: []const u8) ConnectionIdentity {
    const peer = address.Endpoint{ .address = tryAddress(raw), .port = 8080 };
    return .{ .transport_peer = peer, .connection_peer = peer };
}

fn tryAddress(raw: []const u8) address.Address {
    return address.Address.parse(raw) catch unreachable;
}

fn expectBadRequest(result: Result(TestApp, request_trailers.standard_names_max)) !void {
    try std.testing.expect(result == .rejected);
    try std.testing.expectEqual(request_head.Status.bad_request, result.rejected.response.status);
    try std.testing.expect(result.rejected.response.close);
}
