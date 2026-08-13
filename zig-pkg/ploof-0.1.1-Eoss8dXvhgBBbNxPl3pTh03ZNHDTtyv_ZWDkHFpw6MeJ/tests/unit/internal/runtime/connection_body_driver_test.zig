pub const std = @import("std");
pub const address = @import("../../../../src/address.zig");
pub const application = @import("../../../../src/application.zig");
pub const body = @import("../../../../src/body.zig");
pub const endpoint = @import("../../../../src/endpoint.zig");
pub const forwarding = @import("../../../../src/forwarding.zig");
pub const multipart = @import("../../../../src/multipart.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const authority = @import("../../../../src/internal/http1/authority.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
pub const deterministic_reactor = @import(
    "../../../../src/internal/runtime/deterministic_reactor.zig",
);
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const fixed_date = "Tue, 14 Jul 2026 12:00:00 GMT";
pub const continue_response = "HTTP/1.1 100 Continue\r\n\r\n";
pub const ping_request = "GET /ping HTTP/1.1\r\nHost: example.test\r\n\r\n";
pub const echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 6\r\n\r\n";
pub const expect_echo_head =
    "POST /echo HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: application/octet-stream\r\n" ++
    "Content-Length: 6\r\n" ++
    "Expect: 100-continue\r\n\r\n";
pub const large_body_encoded_bytes_max = 64 * 1024;
pub const large_body_decoded_bytes_max = 60 * 1024;
pub const head_json_secret = "head-workspace-secret";
pub const multipart_boundary = "driver-boundary";
pub const multipart_total_bytes_max = 1536;
pub const multipart_count_part =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n\r\n" ++
    "23\r\n";
pub const multipart_upload_head =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"upload\"; filename=\"a.bin\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n";
pub const multipart_close = "\r\n--" ++ multipart_boundary ++ "--\r\n";
pub const multipart_body = multipart_count_part ++ multipart_upload_head ++
    "abcdef" ++ multipart_close;
pub const multipart_large_body = multipart_count_part ++ multipart_upload_head ++
    [_]u8{'x'} ** 700 ++ multipart_close;
pub const multipart_invalid_body =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"unknown\"\r\n\r\nx" ++ multipart_close;
pub const multipart_field_limit_body =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n\r\n" ++
    [_]u8{'1'} ** 17 ++ multipart_close;
pub const multipart_file_limit_body = multipart_count_part ++ multipart_upload_head ++
    [_]u8{'x'} ** 1025 ++ multipart_close;
pub const multipart_total_limit_body =
    [_]u8{'p'} ** (multipart_total_bytes_max + 1);
pub const multipart_unsupported_body =
    "--" ++ multipart_boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=\"count\"\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n23" ++ multipart_close;
pub const multipart_fixed_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ multipart_boundary ++ "\r\n" ++
    "Content-Length: " ++ std.fmt.comptimePrint("{d}", .{multipart_body.len}) ++ "\r\n\r\n";
pub const multipart_chunked_head =
    "POST /multipart HTTP/1.1\r\n" ++
    "Host: example.test\r\n" ++
    "Content-Type: multipart/form-data; boundary=" ++ multipart_boundary ++ "\r\n" ++
    "Transfer-Encoding: chunked\r\n\r\n";
pub const multipart_chunked_wire = std.fmt.comptimePrint(
    "{x}\r\n{s}\r\n0\r\n\r\n",
    .{ multipart_body.len, multipart_body },
);

pub const TestState = struct {
    body_calls: u8 = 0,
    text_calls: u8 = 0,
    body_length: usize = 0,
    body_is_abcdef: bool = false,
    body_saw_trailers: bool = false,
    after_saw_trailers: bool = false,
    ping_calls: u8 = 0,
    short_head_calls: u8 = 0,
    head_json_calls: u8 = 0,
    after_calls: u8 = 0,
    completed: u8 = 0,
    aborted: u8 = 0,
    last_status: ?response.Status = null,
    check_forwarding: bool = false,
    forwarding_valid: bool = true,
    forwarding_head_checks: u8 = 0,
    forwarding_handler_checks: u8 = 0,
    forwarding_after_checks: u8 = 0,
    expected_authority: ?forwarding.Authority = null,
    expected_client: ?address.Endpoint = null,
    borrowed_authority: ?forwarding.Authority = null,
    multipart_calls: u8 = 0,
    multipart_count: u16 = 0,
};

pub const TestContext = application.Context(TestState, response.standard_head_limits);
pub const TestResponse = TestContext.ResponseType;

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn head(_: Observe, context: *TestContext, _: *void) ?TestResponse {
        if (!context.state.check_forwarding) return null;
        context.state.forwarding_head_checks += 1;
        context.state.forwarding_valid = context.state.forwarding_valid and
            forwardingMatches(context);
        context.state.borrowed_authority = context.request.effectiveAuthority();
        return null;
    }

    pub fn after(
        _: Observe,
        context: *const TestContext,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        context.state.last_status = outcome.status;
        context.state.after_saw_trailers = hasExpectedTrailers(context.request.trailers);
        if (context.state.check_forwarding) {
            context.state.forwarding_after_checks += 1;
            const borrowed = context.state.borrowed_authority orelse {
                context.state.forwarding_valid = false;
                return;
            };
            const expected = context.state.expected_authority orelse {
                context.state.forwarding_valid = false;
                return;
            };
            context.state.forwarding_valid = context.state.forwarding_valid and
                borrowed.eql(expected) and forwardingMatches(context);
        }
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub const ShortCircuit = struct {
    pub const State = void;

    pub fn head(
        _: ShortCircuit,
        context: *TestContext,
        _: *void,
    ) ?TestResponse {
        context.state.short_head_calls += 1;
        return context.empty(.forbidden);
    }
};

pub const HeadJsonTaint = struct {
    pub const State = void;

    pub fn head(
        _: HeadJsonTaint,
        context: *TestContext,
        _: *void,
    ) ?TestResponse {
        context.state.head_json_calls += 1;
        const ignored = context.json(.ok, .{
            .secret = head_json_secret,
        }) catch return context.empty(.internal_server_error);
        _ = ignored;
        return null;
    }
};

pub fn echo(context: *TestContext, value: body.Bytes) TestResponse {
    context.state.body_calls += 1;
    context.state.body_length = value.len();
    context.state.body_is_abcdef = value.eql("abcdef");
    context.state.body_saw_trailers = hasExpectedTrailers(context.request.trailers);
    checkForwardingHandler(context);
    return context.textStatic(.ok, "body-ok");
}

pub fn hasExpectedTrailers(trailers: application.RequestTrailers) bool {
    const values = trailers.all("x-check");
    if (values.count() != 2) return false;
    var value_iterator = values.iterator();
    const first_value = value_iterator.next() orelse return false;
    if (!std.mem.eql(u8, first_value, "first")) return false;
    const second_value = value_iterator.next() orelse return false;
    if (!std.mem.eql(u8, second_value, "second")) return false;
    if (value_iterator.next() != null) return false;

    const raw = trailers.raw();
    if (raw.count() != 2) return false;
    var raw_iterator = raw.iterator();
    const first = raw_iterator.next() orelse return false;
    if (!std.mem.eql(u8, first.name, "X-Check")) return false;
    if (!std.mem.eql(u8, first.value, "  first \t")) return false;
    const second = raw_iterator.next() orelse return false;
    if (!std.mem.eql(u8, second.name, "x-CHECK")) return false;
    if (!std.mem.eql(u8, second.value, "\tsecond")) return false;
    return raw_iterator.next() == null;
}

pub fn ping(context: *TestContext) TestResponse {
    context.state.ping_calls += 1;
    checkForwardingHandler(context);
    return context.textStatic(.ok, "pong");
}

pub fn checkForwardingHandler(context: *TestContext) void {
    if (!context.state.check_forwarding) return;
    context.state.forwarding_handler_checks += 1;
    const borrowed = context.state.borrowed_authority orelse {
        context.state.forwarding_valid = false;
        return;
    };
    const expected = context.state.expected_authority orelse {
        context.state.forwarding_valid = false;
        return;
    };
    context.state.forwarding_valid = context.state.forwarding_valid and
        borrowed.eql(expected) and forwardingMatches(context);
}

pub fn forwardingMatches(context: *const TestContext) bool {
    const expected_authority = context.state.expected_authority orelse return false;
    const expected_client = context.state.expected_client orelse return false;
    const authority_value = context.request.effectiveAuthority() orelse return false;
    const client = context.request.clientEndpoint() orelse return false;
    const transport = context.request.transportPeer() orelse return false;
    const provenance = context.request.forwardingProvenance() orelse return false;
    return authority_value.eql(expected_authority) and
        client.eql(expected_client) and
        transport.eql(address.Endpoint.initIpv4(.{ 127, 0, 0, 1 }, 0)) and
        context.request.effectiveScheme() == .https and
        provenance.client == .x_forwarded and
        provenance.host == .x_forwarded_host and
        provenance.scheme == .x_forwarded_proto and
        provenance.headers == .applied and
        provenance.trusted_hops == 1;
}

pub fn text(context: *TestContext, _: body.Text) TestResponse {
    context.state.text_calls += 1;
    return context.textStatic(.ok, "text-ok");
}

pub const MultipartBody = multipart.decode(.{
    .count = multipart.field(u16, multipart.required),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 2048,
    .total_body_bytes_max = multipart_total_bytes_max,
    .file_bytes_max = 1024,
    .field_bytes_max = 16,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 32,
}) });
pub const MultipartEndpoint = endpoint.Endpoint(.{ .body = MultipartBody });
pub const MultipartSpec = @TypeOf(MultipartBody);

pub const MultipartConsumer = struct {
    pub const State = struct { count: u16 = 0 };

    pub fn init(_: MultipartConsumer, _: *TestContext) State {
        return .{};
    }

    pub fn field(
        _: MultipartConsumer,
        state: *State,
        value: @TypeOf(MultipartBody).Field,
    ) void {
        state.count = value.count;
    }

    pub fn fileStart(
        _: MultipartConsumer,
        _: *TestContext,
        _: *State,
        _: MultipartSpec.FileStart,
    ) MultipartSpec.FileAdmission(TestResponse) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: MultipartConsumer,
        context: *TestContext,
        state: *State,
        _: MultipartEndpoint.InputType,
        _: MultipartSpec.Summaries,
    ) multipart.Decision(TestResponse) {
        context.state.multipart_calls += 1;
        context.state.multipart_count = state.count;
        return multipart.commit(context.textStatic(.ok, "multipart-ok"));
    }
};

pub const TaintedEndpoint = endpoint.Endpoint(.{
    .body = body.raw(.{
        .encoded_wire_bytes_max = 128,
        .decoded_bytes_max = 8,
    }),
    .response_json_bytes_max = 128,
});

pub fn tainted(
    context: *TestContext,
    input: TaintedEndpoint.InputType,
) TestResponse {
    return echo(context, input.body);
}

pub const TestApp = application.Application(.{
    .State = TestState,
    .middleware = .{Observe{}},
    .routes = .{
        route.post("/echo", body.bytes(.{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 8,
        }, echo)),
        route.post("/large", body.bytes(.{
            .encoded_wire_bytes_max = large_body_encoded_bytes_max,
            .decoded_bytes_max = large_body_decoded_bytes_max,
        }, echo)),
        route.post("/text", body.text(.{
            .encoded_wire_bytes_max = 8,
            .decoded_bytes_max = 8,
        }, text)),
        route.post("/multipart", MultipartEndpoint.handle(MultipartConsumer{})),
        route.configured(
            .post,
            "/tainted",
            TaintedEndpoint.handle(tainted),
            .{HeadJsonTaint{}},
            null,
        ),
        route.get("/ping", ping),
        route.configured(
            .post,
            "/short",
            body.bytes(.{
                .encoded_wire_bytes_max = 8,
                .decoded_bytes_max = 8,
            }, echo),
            .{ShortCircuit{}},
            null,
        ),
    },
});

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 4,
    .request_slots = 2,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 512,
    .pipeline_bytes_per_connection = 1024,
    .response_bytes_per_request = 2048,
    .submission_entries = 64,
    .completion_entries = 128,
    .chunked = .{
        .chunks_max = 3,
        .trailer_section_bytes_max = 256,
        .trailer_field_line_bytes_max = 192,
        .trailer_names_max = 2,
        .trailer_fields_max = 3,
    },
    .timeouts = .{
        .first_head_ns = 100,
        .keepalive_idle_ns = 200,
        .reused_head_progress_ns = 100,
        .body_inactivity_ns = 200,
        .write_stall_ns = 100,
    },
});

pub const TestStorage = worker_storage.Storage(TestApp, test_limits);
pub const TestReactor = deterministic_reactor.DeterministicReactor(128);
pub const TestProfile = forwarding.Profile(forwarding.standard_limits);
pub const TestDriver = connection_driver.ConfiguredDriver(
    TestApp,
    TestStorage,
    TestReactor,
    forwarding.standard_limits,
);

pub const Harness = struct {
    slab: [TestStorage.required_bytes]u8 align(TestStorage.slab_alignment) = undefined,
    storage: TestStorage = undefined,
    io: TestReactor = .{},
    state: TestState = .{},
    forwarding_profile: TestProfile = undefined,
    driver: TestDriver = undefined,
    now_ns: u64 = 1,
    buffer_cursor: u16 = 0,
    buffer_generations: [test_limits.receive_buffers]u16 =
        [_]u16{1} ** test_limits.receive_buffers,

    pub fn init(self: *Harness) !void {
        self.io = .{};
        self.state = .{};
        try self.storage.init(&self.slab);
        self.driver = try TestDriver.init(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
        );
        self.now_ns = 1;
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** test_limits.receive_buffers;
    }

    pub fn initForwarding(self: *Harness, value: forwarding.Config) !void {
        self.io = .{};
        self.state = .{ .check_forwarding = true };
        self.forwarding_profile = try TestProfile.init(value);
        try self.storage.init(&self.slab);
        self.driver = try TestDriver.initForwarding(
            &self.state,
            &self.storage,
            &self.io,
            0,
            .{ .date = fixed_date },
            &self.forwarding_profile,
        );
        self.now_ns = 1;
        self.buffer_cursor = 0;
        self.buffer_generations = [_]u16{1} ** test_limits.receive_buffers;
    }

    pub fn addConnection(self: *Harness, socket: u64) !u16 {
        const index = self.storage.acquireConnection(.{ .value = socket }) orelse {
            return error.TestUnexpectedResult;
        };
        try self.driver.start(index, self.now_ns);
        return index;
    }

    pub fn receive(
        self: *Harness,
        connection_index: u16,
        bytes: []const u8,
        more: bool,
    ) !connection_driver.Disposition {
        const token = self.storage.connections[connection_index].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        const buffer_index = self.buffer_cursor;
        self.buffer_cursor = (buffer_index + 1) % test_limits.receive_buffers;
        const generation = self.buffer_generations[buffer_index];
        self.buffer_generations[buffer_index] = reactor.nextGeneration(generation);
        return self.complete(token, .{ .success = .{ .receive = .{ .bytes = .{
            .identity = .{
                .owner = try token.slot(),
                .buffer_index = buffer_index,
                .buffer_generation = generation,
            },
            .bytes = bytes,
        } } } }, more);
    }

    pub fn endOfStream(
        self: *Harness,
        connection_index: u16,
    ) !connection_driver.Disposition {
        const token = self.storage.connections[connection_index].receive_token orelse {
            return error.TestUnexpectedResult;
        };
        return self.complete(
            token,
            .{ .success = .{ .receive = .end_of_stream } },
            false,
        );
    }

    pub fn complete(
        self: *Harness,
        token: reactor.OperationToken,
        result: reactor.CompletionResult,
        more: bool,
    ) !connection_driver.Disposition {
        try self.io.complete(token, result, more);
        const completion = self.io.nextCompletion() orelse {
            return error.TestUnexpectedResult;
        };
        return self.driver.handle(completion, self.now_ns);
    }

    pub fn sendBytes(self: *const Harness, connection_index: u16) []const u8 {
        const token = self.storage.connections[connection_index].send_token.?;
        return self.io.operation(token).?.send.bytes;
    }

    pub fn completeSend(self: *Harness, connection_index: u16, count: u32) !void {
        const token = self.storage.connections[connection_index].send_token orelse {
            return error.TestUnexpectedResult;
        };
        _ = try self.complete(token, .{ .success = .{ .send = count } }, false);
    }

    pub fn completeSendAll(self: *Harness, connection_index: u16) !void {
        const length = std.math.cast(u32, self.sendBytes(connection_index).len) orelse {
            return error.TestUnexpectedResult;
        };
        try self.completeSend(connection_index, length);
    }

    pub fn findToken(
        self: *const Harness,
        connection_index: u16,
        kind: reactor.OperationKind,
    ) ?reactor.OperationToken {
        var active_index: u16 = 0;
        while (active_index < self.io.activeCount()) : (active_index += 1) {
            const submission = self.io.activeSubmission(active_index).?;
            const fields = submission.token.fields() catch unreachable;
            if (fields.slot_index == connection_index and fields.kind == kind) {
                return submission.token;
            }
        }
        return null;
    }

    pub fn retireResponse(self: *Harness, connection_index: u16) !void {
        var iterations: u8 = 0;
        while (self.storage.connections[connection_index].phase == .responding and
            self.storage.connections[connection_index].active_request == null and
            self.storage.connections[connection_index].send_token == null)
        {
            if (iterations == 32) return error.TestUnexpectedResult;
            iterations += 1;
            const token = self.findToken(connection_index, .cancel) orelse
                self.findToken(connection_index, .timeout) orelse
                return error.TestUnexpectedResult;
            const result: reactor.CompletionResult = if ((try token.fields()).kind == .cancel)
                .{ .success = .{ .cancel = .canceled } }
            else
                .{ .failure = .canceled };
            _ = try self.complete(token, result, false);
        }
    }

    pub fn drainClosing(self: *Harness, connection_index: u16) !void {
        var iterations: u8 = 0;
        while (self.storage.connections[connection_index].phase != .free) {
            if (iterations == 64) return error.TestUnexpectedResult;
            iterations += 1;
            const token = self.findToken(connection_index, .cancel) orelse
                self.findToken(connection_index, .close) orelse
                self.findToken(connection_index, .timeout) orelse
                self.findToken(connection_index, .receive) orelse
                self.findToken(connection_index, .send) orelse
                return error.TestUnexpectedResult;
            const result: reactor.CompletionResult = switch ((try token.fields()).kind) {
                .cancel => .{ .success = .{ .cancel = .canceled } },
                .close => .{ .success = .{ .close = {} } },
                .timeout, .receive, .send => .{ .failure = .canceled },
                .accept,
                .wake,
                .file_open,
                .file_write,
                .file_close,
                .file_link,
                .file_unlink,
                .file_rename_no_replace,
                .file_sync,
                .upload_cancel,
                .file_read,
                .file_stat,
                .file_cancel,
                => return error.TestUnexpectedResult,
            };
            _ = try self.complete(token, result, false);
        }
    }
};

pub fn expectMultipartRejection(wire: []const u8, status: []const u8, socket: u16) !void {
    var harness: Harness = undefined;
    try harness.init();
    const connection = try harness.addConnection(socket);
    _ = try harness.receive(connection, wire, false);
    try std.testing.expect(std.mem.startsWith(u8, harness.sendBytes(connection), status));
    try std.testing.expectEqual(@as(u8, 0), harness.state.multipart_calls);
    try std.testing.expect(harness.storage.connections[connection].close_after_response);
    try harness.completeSendAll(connection);
    try harness.drainClosing(connection);
    try std.testing.expectEqual(@as(u8, 1), harness.state.after_calls);
    try std.testing.expectEqual(@as(u8, 1), harness.state.completed);
    try std.testing.expectEqual(@as(u8, 0), harness.state.aborted);
    try std.testing.expectEqual(
        test_limits.request_slots,
        harness.storage.request_pool.available(),
    );
    try std.testing.expectEqual(
        test_limits.body_workspace_slots,
        harness.storage.bodyWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        test_limits.chunked_workspace_slots,
        harness.storage.chunkedWorkspaceAvailable(),
    );
    try std.testing.expectEqual(
        test_limits.connection_slots,
        harness.storage.connection_pool.available(),
    );
    try std.testing.expectEqual(@as(u16, 0), harness.io.activeCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.pendingCompletionCount());
    try std.testing.expectEqual(@as(u16, 0), harness.io.borrowedCount());
}

pub fn expectFinalWithoutContinue(
    harness: *const Harness,
    connection_index: u16,
    status_line: []const u8,
) !void {
    const bytes = harness.sendBytes(connection_index);
    try std.testing.expect(!std.mem.startsWith(u8, bytes, continue_response));
    try std.testing.expect(std.mem.startsWith(u8, bytes, status_line));
}

test {
    _ = @import("connection_body_driver_test_part_1.zig");
}
