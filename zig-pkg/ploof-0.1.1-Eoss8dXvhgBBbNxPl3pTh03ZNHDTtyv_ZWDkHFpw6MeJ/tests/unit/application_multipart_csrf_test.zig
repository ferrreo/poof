const std = @import("std");

const address = @import("../../src/address.zig");
const application = @import("../../src/application.zig");
const application_multipart_plan = @import("../../src/internal/application/multipart_plan.zig");
const csrf = @import("../../src/csrf.zig");
const csrf_request = @import("../../src/internal/csrf/request.zig");
const endpoint = @import("../../src/endpoint.zig");
const gzip_encoder = @import("../../src/internal/runtime/gzip/encoder.zig");
const legacy_runtime = @import("../../src/internal/application/multipart_runtime.zig");
const multipart = @import("../../src/multipart.zig");
const response = @import("../../src/response.zig");
const route = @import("../../src/route.zig");
const testing = @import("../../src/testing.zig");
const transaction_test = @import("multipart_upload_transaction_test.zig");
const upload_runtime = @import("../../src/internal/application/multipart_upload_runtime.zig");

const boundary = "C";
const token_raw = [_]u8{0x5a} ** csrf.synchronizer_bytes;
const encoded_token = csrf_request.encodeSynchronizer(&token_raw);

const limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 4096,
    .total_body_bytes_max = 2048,
    .file_bytes_max = 256,
    .field_bytes_max = 16,
    .parts_max = 4,
    .files_max = 1,
    .part_headers_max = 3,
    .part_header_bytes_max = 256,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 32,
    .filename_bytes_max = 32,
    .boundary_bytes_max = 8,
});

const LegacySpec = @TypeOf(multipart.decode(.{
    ._csrf = csrf.multipartField(),
    .note = multipart.bytesField(multipart.optional),
}, .{ .limits = limits }));
const MarkerOnlySpec = @TypeOf(multipart.decode(.{
    ._csrf = csrf.multipartField(),
}, .{ .limits = limits }));
const LegacyDiscardSpec = @TypeOf(multipart.decode(.{
    ._csrf = csrf.multipartField(),
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{ .limits = limits }));

const MixedOrigins = csrf.OriginSet(1, 64);

const AppState = struct {
    origins: MixedOrigins = .{},
    session: ?csrf.SessionToken = null,
    stored: ?csrf.SessionToken = null,
    multipart_init_calls: u8 = 0,
    legacy_field_calls: u8 = 0,
    file_start_calls: u8 = 0,
};
const Context = application.Context(AppState, response.standard_head_limits);

fn mixedOrigins(state: *const AppState) *const MixedOrigins {
    return &state.origins;
}

fn mixedLoad(context: *Context) ?csrf.SessionToken {
    return context.state.session;
}

fn mixedStore(context: *Context, token: csrf.SessionToken) void {
    context.state.stored = token;
}

fn mixedClear(context: *Context) void {
    context.state.stored = null;
}

const mixed_policy = csrf.synchronizer(Context, .{
    .origins = mixedOrigins,
    .load = mixedLoad,
    .store = mixedStore,
    .clear = mixedClear,
});

const LegacyConsumer = struct {
    pub const State = struct {
        application: *AppState,
        field_calls: u8 = 0,
        note_valid: bool = false,
    };

    pub fn init(_: LegacyConsumer, context: *Context) State {
        context.state.multipart_init_calls += 1;
        return .{ .application = context.state };
    }

    pub fn field(_: LegacyConsumer, state: *State, value: LegacySpec.Field) void {
        state.application.legacy_field_calls += 1;
        state.field_calls += 1;
        state.note_valid = switch (value) {
            .note => |bytes| std.mem.eql(u8, bytes, "ok"),
        };
    }
};

const LegacyHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = LegacySpec;
    };
    pub const MultipartState = LegacyConsumer.State;
    pub const handler_fn = LegacyConsumer{};
};
const LegacyRuntime = legacy_runtime.Runtime(LegacyHandler);

const LegacyDiscardConsumer = struct {
    pub const State = struct {};

    pub fn init(_: LegacyDiscardConsumer, context: *Context) State {
        context.state.multipart_init_calls += 1;
        return .{};
    }
};

const LegacyDiscardHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = LegacyDiscardSpec;
    };
    pub const MultipartState = LegacyDiscardConsumer.State;
    pub const handler_fn = LegacyDiscardConsumer{};
};
const LegacyDiscardRuntime = legacy_runtime.Runtime(LegacyDiscardHandler);

const UploadSpec = @TypeOf(multipart.decode(.{
    ._csrf = csrf.multipartField(),
    .upload = multipart.file(transaction_test.Alpha, multipart.required),
}, .{
    .limits = limits,
    .upload = .{ .window = 2, .chunk_bytes = 4 },
}));

const UploadConsumer = struct {
    pub const State = struct { starts: u8 = 0 };

    pub fn init(_: UploadConsumer, context: *Context) State {
        context.state.multipart_init_calls += 1;
        return .{};
    }

    pub fn fileStart(
        _: UploadConsumer,
        context: *Context,
        state: *State,
        _: UploadSpec.FileStart,
    ) UploadSpec.FileAdmission(Context.ResponseType) {
        context.state.file_start_calls += 1;
        state.starts += 1;
        return .{ .accept = .{ .upload = 7 } };
    }
};

const UploadHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = UploadSpec;
    };
    pub const MultipartConsumer = UploadConsumer;
    pub const MultipartState = UploadConsumer.State;
    pub const handler_fn = UploadConsumer{};
};
const UploadRuntime = upload_runtime.Runtime(UploadHandler);

const MixedLegacyDefinition = endpoint.Endpoint(.{ .body = LegacySpec{} });
const MixedUploadDefinition = endpoint.Endpoint(.{ .body = UploadSpec{} });

const MixedLegacyConsumer = struct {
    pub const State = *AppState;

    pub fn init(_: MixedLegacyConsumer, context: *Context) State {
        context.state.multipart_init_calls += 1;
        return context.state;
    }

    pub fn field(_: MixedLegacyConsumer, state: *State, _: LegacySpec.Field) void {
        state.*.legacy_field_calls += 1;
    }

    pub fn complete(
        _: MixedLegacyConsumer,
        context: *Context,
        _: *State,
        _: MixedLegacyDefinition.InputType,
        _: LegacySpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.ok));
    }
};

const MixedUploadConsumer = struct {
    pub const State = void;

    pub fn init(_: MixedUploadConsumer, _: *Context) State {}

    pub fn fileStart(
        _: MixedUploadConsumer,
        _: *Context,
        _: *State,
        _: UploadSpec.FileStart,
    ) UploadSpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = 7 } };
    }

    pub fn complete(
        _: MixedUploadConsumer,
        context: *Context,
        _: *State,
        _: MixedUploadDefinition.InputType,
        _: UploadSpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.ok));
    }
};

const MixedApp = application.Application(.{
    .State = AppState,
    .middleware = .{mixed_policy},
    .routes = .{
        route.post("/legacy", MixedLegacyDefinition.handle(MixedLegacyConsumer{})),
        route.post("/upload", MixedUploadDefinition.handle(MixedUploadConsumer{})),
    },
});

const TransportApp = application.Application(.{
    .State = AppState,
    .middleware = .{mixed_policy},
    .routes = .{
        route.post("/legacy", MixedLegacyDefinition.handle(MixedLegacyConsumer{})),
    },
});
const TransportClient = testing.ConfiguredClient(TransportApp, .{
    .request_bytes_max = 8192,
    .response_bytes_max = 2048,
});

const UploadSource = struct {
    alpha: transaction_test.Alpha.Runtime,

    fn init(trace: *transaction_test.Harness) UploadSource {
        return .{ .alpha = .{ .harness = trace } };
    }

    pub fn get(self: *UploadSource, comptime Sink: type) *Sink.Runtime {
        if (Sink == transaction_test.Alpha) return &self.alpha;
        unreachable;
    }
};

const TestContext = struct {
    state: AppState = .{},
    response_workspace: Context.ResponseWorkspaceType = .{},
    csrf_state: csrf.RequestState = undefined,
    context: Context = undefined,

    fn init(self: *TestContext) void {
        self.state = .{};
        self.response_workspace = .{};
        self.csrf_state = .{ .body_source = .multipart };
        self.csrf_state.beginSynchronizer(&token_raw);
        self.context = .{
            .state = &self.state,
            .request = .{
                .method = "POST",
                .raw_target = "/upload",
                .raw_path = "/upload",
                .path = "/upload",
                .raw_query = null,
            },
            .response_workspace = &self.response_workspace,
            .csrf_request = &self.csrf_state,
        };
    }
};

const Fragmentation = enum { whole, seven_byte, bytewise };

test "multipart CSRF metadata is exact and marker is absent from handler fields" {
    const plan = application_multipart_plan.compiledPlan(LegacySpec);
    try std.testing.expectEqual(@as(u16, 1), LegacySpec.ploof_csrf_field_count);
    try std.testing.expectEqualStrings("_csrf", LegacySpec.ploof_csrf_field_name.?);
    try std.testing.expectEqual(@as(?u16, 0), LegacySpec.ploof_csrf_field_index);
    try std.testing.expectEqual(@as(?u16, 0), application_multipart_plan.csrfFieldIndex(
        LegacySpec,
    ));
    try std.testing.expectEqual(@as(usize, 128), plan.entries[0].bytes_max);
    try std.testing.expectEqual(limits.parts_max, plan.entries[0].maximum);
    try std.testing.expect(plan.entries[0].csrf_field);
    try std.testing.expect(!plan.entries[0].required);
    try std.testing.expect(MarkerOnlySpec.Field == void);
    try std.testing.expect(!@hasField(LegacySpec.Field, "_csrf"));
}

test "multipart CSRF token is invariant across decoded-body fragmentation" {
    var body_storage: [512]u8 = undefined;
    const body = try validLegacyBody(&body_storage, true);
    inline for (std.enums.values(Fragmentation)) |fragmentation| {
        var test_context: TestContext = undefined;
        test_context.init();
        var runtime = try LegacyRuntime.init(boundary, &test_context.context);
        try feedLegacy(&runtime, body, fragmentation);
        try runtime.finish();
        try std.testing.expectEqual(csrf_request.Status.accepted, test_context.csrf_state.status);
        try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
        try std.testing.expectEqual(@as(u8, 1), test_context.state.legacy_field_calls);
        try std.testing.expectEqual(@as(u8, 1), runtime.state().field_calls);
        try std.testing.expect(runtime.state().note_valid);
        try std.testing.expectEqual(legacy_runtime.TerminalSource.none, runtime.terminalSource());
    }
}

test "multipart CSRF missing wrong duplicate filename and mixed sources fail closed" {
    var storage: [1024]u8 = undefined;
    var test_context: TestContext = undefined;

    test_context.init();
    var missing = try LegacyRuntime.init(boundary, &test_context.context);
    try missing.feed("--C--\r\n");
    try std.testing.expectError(error.FileRejected, missing.finish());
    try expectCsrfRejection(&missing, &test_context.csrf_state);
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var field_first = try LegacyRuntime.init(boundary, &test_context.context);
    const no_token = try noteBody(&storage);
    try std.testing.expectError(error.FileRejected, field_first.feed(no_token));
    try expectCsrfRejection(&field_first, &test_context.csrf_state);
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var wrong = try LegacyRuntime.init(boundary, &test_context.context);
    const wrong_body = try markerBody(&storage, "wrong", false, false);
    try std.testing.expectError(error.FileRejected, wrong.feed(wrong_body));
    try expectCsrfRejection(&wrong, &test_context.csrf_state);
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var duplicate = try LegacyRuntime.init(boundary, &test_context.context);
    const duplicate_body = try markerBody(&storage, &encoded_token, true, false);
    try std.testing.expectError(error.FileRejected, duplicate.feed(duplicate_body));
    try expectCsrfRejection(&duplicate, &test_context.csrf_state);
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    try std.testing.expect(test_context.csrf_state.observe(.header, &encoded_token));
    var header_only = try LegacyRuntime.init(boundary, &test_context.context);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    const header_body = try noteBody(&storage);
    try header_only.feed(header_body);
    try header_only.finish();
    try std.testing.expectEqual(csrf_request.Status.accepted, test_context.csrf_state.status);
    try std.testing.expectEqual(@as(u8, 1), header_only.state().field_calls);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.legacy_field_calls);

    test_context.init();
    try std.testing.expect(test_context.csrf_state.observe(.header, &encoded_token));
    var mixed = try LegacyRuntime.init(boundary, &test_context.context);
    const marker = try markerBody(&storage, &encoded_token, false, false);
    try std.testing.expectError(error.FileRejected, mixed.feed(marker));
    try expectCsrfRejection(&mixed, &test_context.csrf_state);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(@as(u8, 0), test_context.state.legacy_field_calls);

    test_context.init();
    var filename = try LegacyRuntime.init(boundary, &test_context.context);
    const filename_body = try markerBody(&storage, &encoded_token, false, true);
    try std.testing.expectError(error.InvalidMultipart, filename.feed(filename_body));
    try std.testing.expectEqual(legacy_runtime.TerminalSource.parser, filename.terminalSource());
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var oversized = try LegacyRuntime.init(boundary, &test_context.context);
    const too_large = try markerBody(&storage, &([_]u8{'x'} ** 129), false, false);
    try std.testing.expectError(error.LimitExceeded, oversized.feed(too_large));
    try std.testing.expectEqual(legacy_runtime.TerminalSource.parser, oversized.terminalSource());
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var marker_only = try LegacyRuntime.init(boundary, &test_context.context);
    const valid_marker = try validLegacyBody(&storage, false);
    try marker_only.feed(valid_marker);
    try std.testing.expectEqual(@as(u8, 0), test_context.state.multipart_init_calls);
    try marker_only.finish();
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(@as(u8, 0), test_context.state.legacy_field_calls);
}

test "multipart CSRF gates file admission and late duplicates abort staged uploads" {
    var storage: [1024]u8 = undefined;
    var test_context: TestContext = undefined;
    var trace = transaction_test.Harness{};
    var source = UploadSource.init(&trace);

    test_context.init();
    var early: UploadRuntime = undefined;
    try early.initInPlace(boundary, &test_context.context, &source);
    const file_first = try uploadBody(&storage, false, false);
    try std.testing.expectError(error.FileRejected, early.feedProgress(file_first));
    try std.testing.expectError(error.Terminal, early.state());
    try expectNoApplicationCallbacks(&test_context);
    try std.testing.expectEqual(@as(usize, 0), trace.trace_len);
    try std.testing.expectEqual(upload_runtime.TerminalSource.rejection, early.terminalSource());

    trace = .{};
    source = UploadSource.init(&trace);
    test_context.init();
    var accepted: UploadRuntime = undefined;
    try accepted.initInPlace(boundary, &test_context.context, &source);
    const valid = try uploadBody(&storage, true, false);
    try expectReady(try accepted.feedProgress(valid), valid.len);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.file_start_calls);
    try std.testing.expectEqual(.complete, (try accepted.finishProgress()).flow);
    try accepted.markCommitReady();
    try std.testing.expectEqual(.complete, try accepted.startCommit());
    try std.testing.expectEqual(@as(usize, 1), transaction_test.traceCount(&trace, .commit));
    try std.testing.expectEqual(@as(usize, 0), transaction_test.traceCount(&trace, .abort));

    trace = .{};
    source = UploadSource.init(&trace);
    test_context.init();
    var late: UploadRuntime = undefined;
    try late.initInPlace(boundary, &test_context.context, &source);
    const duplicated = try uploadBody(&storage, true, true);
    try std.testing.expectError(error.FileRejected, late.feedProgress(duplicated));
    try std.testing.expectError(error.Terminal, late.state());
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.file_start_calls);
    try std.testing.expectEqual(.complete, try late.startAbort(null));
    try std.testing.expectEqual(@as(usize, 0), transaction_test.traceCount(&trace, .commit));
    try std.testing.expectEqual(@as(usize, 1), transaction_test.traceCount(&trace, .abort));
}

test "legacy discard files require multipart CSRF before file admission" {
    var storage: [1024]u8 = undefined;
    var test_context: TestContext = undefined;

    test_context.init();
    var file_first = try LegacyDiscardRuntime.init(boundary, &test_context.context);
    const rejected = try legacyDiscardBody(&storage, false);
    try std.testing.expectError(error.FileRejected, file_first.feed(rejected));
    try std.testing.expectEqual(
        legacy_runtime.TerminalSource.rejection,
        file_first.terminalSource(),
    );
    try expectNoApplicationCallbacks(&test_context);

    test_context.init();
    var token_first = try LegacyDiscardRuntime.init(boundary, &test_context.context);
    const accepted = try legacyDiscardBody(&storage, true);
    try token_first.feed(accepted);
    try token_first.finish();
    try std.testing.expectEqual(csrf_request.Status.accepted, test_context.csrf_state.status);
    try std.testing.expectEqual(@as(u8, 1), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(
        legacy_runtime.TerminalSource.none,
        token_first.terminalSource(),
    );
}

test "mixed async-sink app reports legacy multipart CSRF rejection" {
    try std.testing.expect(MixedApp.upload_async_sink_present);
    const workspace_bytes: usize = @intCast(MixedApp.body_workspace_bytes_max);
    var state = AppState{
        .origins = try MixedOrigins.init(&.{"http://ploof.test"}),
        .session = try csrf.SessionToken.fromRandomBytes(token_raw),
    };
    var workspace = MixedApp.Workspace{};
    var registry = MixedApp.UploadRegistry{};
    var request_workspace: [workspace_bytes]u8 align(MixedApp.body_workspace_alignment) =
        undefined;
    var output: [512]u8 = undefined;
    const peer = address.Endpoint{
        .address = .{ .ipv4 = .{ 127, 0, 0, 1 } },
        .port = 1234,
    };
    const input = application.Input{
        .method = "POST",
        .path = "/legacy",
        .raw_target = "/legacy",
        .raw_path = "/legacy",
        .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        .forwarding = .{
            .transport_peer = peer,
            .connection_peer = peer,
            .client = peer,
            .authority = .{
                .host = .{ .reg_name = .{ .bytes = "ploof.test" } },
                .port = 80,
            },
            .scheme = .http,
            .connection_source = .transport,
            .client_provenance = .transport,
            .host_provenance = .host,
            .scheme_provenance = .connection,
            .forwarding_headers = .absent,
            .trusted_hops = 0,
        },
    };
    var route_workspace: MixedApp.RouteSearchWorkspace = undefined;
    var plan = MixedApp.plan(input, &route_workspace);
    try MixedApp.__refinePlanBody(
        &plan,
        plan.body.selectMedia(0) orelse return error.TestUnexpectedResult,
    );
    const prepared = try MixedApp.prepareHeadPlannedIn(
        &state,
        &workspace,
        &request_workspace,
        &output,
        &plan,
        .{},
    );
    switch (prepared) {
        .receive_body => {},
        .prepared => return error.TestUnexpectedResult,
    }
    try MixedApp.__beginMultipart(&workspace, &request_workspace, boundary, &registry);
    var body_storage: [256]u8 = undefined;
    const body = try markerBody(&body_storage, "wrong", false, false);
    try std.testing.expectError(
        error.FileRejected,
        MixedApp.__feedMultipartProgress(&workspace, &request_workspace, body),
    );
    try std.testing.expectEqual(
        MixedApp.MultipartTerminalSource.rejection,
        try MixedApp.__multipartTerminalSource(&workspace, &request_workspace),
    );
    try std.testing.expect(
        (try MixedApp.__multipartApplicationFailure(&workspace, &request_workspace)) == null,
    );
}

test "gzip multipart CSRF uses production fixed and chunked transports" {
    var valid_storage: [512]u8 = undefined;
    const valid = try validLegacyBody(&valid_storage, true);
    var wrong_storage: [256]u8 = undefined;
    const wrong = try markerBody(&wrong_storage, "wrong", false, false);
    var gzip_workspace: gzip_encoder.Workspace = undefined;
    var valid_gzip_storage: [640]u8 = undefined;
    const valid_gzip = try gzip_encoder.compress(
        &gzip_workspace,
        valid,
        &valid_gzip_storage,
        .fastest,
    );
    var wrong_gzip_storage: [384]u8 = undefined;
    const wrong_gzip = try gzip_encoder.compress(
        &gzip_workspace,
        wrong,
        &wrong_gzip_storage,
        .fastest,
    );

    inline for (.{ false, true }) |chunked| {
        var state = AppState{
            .origins = try MixedOrigins.init(&.{"http://ploof.test"}),
            .session = try csrf.SessionToken.fromRandomBytes(token_raw),
        };
        var client_storage: TransportClient.Storage = .{};
        var client = try TransportClient.init(&state, &client_storage);
        defer client.deinit() catch unreachable;

        const accepted = try client.request(.{
            .method = "POST",
            .target = "/legacy",
            .headers = &.{
                .{ .name = "Content-Type", .value = "multipart/form-data; boundary=C" },
                .{ .name = "Content-Encoding", .value = "gzip" },
            },
            .body = valid_gzip,
            .chunked = chunked,
        });
        try std.testing.expectEqual(@as(u16, 200), accepted.status);
        try std.testing.expectEqual(@as(u8, 1), state.multipart_init_calls);
        try std.testing.expectEqual(@as(u8, 1), state.legacy_field_calls);

        state.multipart_init_calls = 0;
        state.legacy_field_calls = 0;
        const rejected = try client.request(.{
            .method = "POST",
            .target = "/legacy",
            .headers = &.{
                .{ .name = "Content-Type", .value = "multipart/form-data; boundary=C" },
                .{ .name = "Content-Encoding", .value = "gzip" },
            },
            .body = wrong_gzip,
            .chunked = chunked,
        });
        try std.testing.expectEqual(@as(u16, 403), rejected.status);
        try std.testing.expectEqualStrings("no-store", rejected.header("Cache-Control").?);
        try std.testing.expectEqual(@as(u8, 0), state.multipart_init_calls);
        try std.testing.expectEqual(@as(u8, 0), state.legacy_field_calls);
    }
}

fn feedLegacy(runtime: *LegacyRuntime, body: []const u8, mode: Fragmentation) !void {
    var offset: usize = 0;
    while (offset < body.len) {
        const width: usize = switch (mode) {
            .whole => body.len,
            .seven_byte => 7,
            .bytewise => 1,
        };
        const end = @min(body.len, offset + width);
        try runtime.feed(body[offset..end]);
        offset = end;
    }
}

fn validLegacyBody(storage: []u8, include_note: bool) ![]const u8 {
    return std.fmt.bufPrint(storage, "--C\r\n" ++
        "Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n" ++
        "{s}--C--\r\n", .{
        &encoded_token,
        if (include_note)
            "--C\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nok\r\n"
        else
            "",
    });
}

fn noteBody(storage: []u8) ![]const u8 {
    return std.fmt.bufPrint(storage, "--C\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n\r\nok\r\n--C--\r\n", .{});
}

fn markerBody(storage: []u8, token: []const u8, duplicate: bool, filename: bool) ![]const u8 {
    const disposition = if (filename)
        "Content-Disposition: form-data; name=\"_csrf\"; filename=\"x\""
    else
        "Content-Disposition: form-data; name=\"_csrf\"";
    return std.fmt.bufPrint(storage, "--C\r\n{s}\r\n\r\n{s}\r\n{s}--C--\r\n", .{
        disposition,
        token,
        if (duplicate) std.fmt.comptimePrint(
            "--C\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n",
            .{encoded_token},
        ) else "",
    });
}

fn uploadBody(storage: []u8, token_first: bool, duplicate: bool) ![]const u8 {
    const token_part = std.fmt.comptimePrint(
        "--C\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n",
        .{encoded_token},
    );
    return std.fmt.bufPrint(storage, "{s}" ++
        "--C\r\nContent-Disposition: form-data; name=\"upload\"; " ++
        "filename=\"x\"\r\n\r\ndata\r\n{s}--C--\r\n", .{
        if (token_first) token_part else "",
        if (duplicate) token_part else "",
    });
}

fn legacyDiscardBody(storage: []u8, token_first: bool) ![]const u8 {
    const token_part = std.fmt.comptimePrint(
        "--C\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n{s}\r\n",
        .{encoded_token},
    );
    return std.fmt.bufPrint(storage, "{s}" ++
        "--C\r\nContent-Disposition: form-data; name=\"upload\"; " ++
        "filename=\"x\"\r\n\r\ndata\r\n--C--\r\n", .{
        if (token_first) token_part else "",
    });
}

fn expectCsrfRejection(runtime: *LegacyRuntime, state: *csrf.RequestState) !void {
    try std.testing.expectEqual(csrf_request.Status.rejected, state.status);
    try std.testing.expectEqual(legacy_runtime.TerminalSource.rejection, runtime.terminalSource());
}

fn expectNoApplicationCallbacks(test_context: *const TestContext) !void {
    try std.testing.expectEqual(@as(u8, 0), test_context.state.multipart_init_calls);
    try std.testing.expectEqual(@as(u8, 0), test_context.state.legacy_field_calls);
    try std.testing.expectEqual(@as(u8, 0), test_context.state.file_start_calls);
}

fn expectReady(progress: anytype, consumed: usize) !void {
    try std.testing.expectEqual(consumed, progress.consumed);
    try std.testing.expectEqual(.ready, progress.flow);
}
