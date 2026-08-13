const std = @import("std");
const linux = std.os.linux;

const ploof = @import("../../../ploof.zig");
const authority = @import("../../http1/authority.zig");
const allocation_guard = @import("../allocation_guard.zig");
const server_startup = @import("../../../server/startup.zig");

const completion_wait_ns: u64 = 30 * std.time.ns_per_s;
const poll_pause_ns: i64 = 10 * std.time.ns_per_ms;
const compressed_request = "compressed-request-payload";
const compressed_response = "z" ** 4096;
const stream_response = "s" ** (32 * 1024);

const Mode = enum(u2) {
    direct,
    x_forwarded,
    proxy_v2_x_forwarded,
};

const Invocation = struct {
    mode: Mode,
    expected_handler_calls: u32,
};

const State = struct {
    mode: Mode,
    calls: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    valid: std.atomic.Value(bool) = .init(true),

    fn reject(state: *State) void {
        state.valid.store(false, .release);
    }
};

const Context = ploof.Context(State, ploof.response.standard_head_limits);

const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn head(
        _: Observe,
        context: *Context,
        _: *void,
    ) ?Context.ResponseType {
        if (requestMetadataValid(context)) return null;
        return context.textStatic(.internal_server_error, "proxy-fail");
    }

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: ploof.Outcome,
    ) void {
        _ = context.state.completed.fetchAdd(1, .monotonic);
        switch (outcome.transport) {
            .completed, .head_suppressed => {},
            else => context.state.reject(),
        }
        if (std.mem.eql(u8, context.request.path, "/finish")) {
            context.state.finished.store(true, .release);
        }
    }
};

fn identity(context: *Context) Context.ResponseType {
    _ = context.state.calls.fetchAdd(1, .monotonic);
    return context.textStatic(.ok, "proxy-ok");
}

fn normalizedPath(context: *Context) Context.ResponseType {
    _ = context.state.calls.fetchAdd(1, .monotonic);
    const valid =
        pathPair(context, "/normal%2Fslash", "/normal/slash") or
        pathPair(context, "/normal%5Cbackslash", "/normal\\backslash") or
        pathPair(context, "/normal%252Fdouble", "/normal%2Fdouble") or
        pathPair(context, "/normal/%75nreserved", "/normal/unreserved") or
        pathPair(context, "/normal/%2e/dot", "/normal/./dot");
    if (valid) return context.textStatic(.ok, "path-ok");
    context.state.reject();
    return context.textStatic(.internal_server_error, "path-fail");
}

fn pathPair(context: *const Context, raw: []const u8, decoded: []const u8) bool {
    return std.mem.eql(u8, context.request.raw_path, raw) and
        std.mem.eql(u8, context.request.path, decoded);
}

fn compressed(context: *Context, input: ploof.Body.Bytes) Context.ResponseType {
    _ = context.state.calls.fetchAdd(1, .monotonic);
    if (!input.eql(compressed_request)) {
        context.state.reject();
        return context.textStatic(.bad_request, "compression-fail");
    }
    return context.textStatic(.ok, compressed_response);
}

const StreamProducer = struct {
    offset: u32 = 0,

    pub fn poll(
        producer: *StreamProducer,
        output: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        if (producer.offset == stream_response.len) return .{ .done = &.{} };
        if (output.len == 0) return error.ProducerFailed;
        const remaining = stream_response[producer.offset..];
        const used = @min(output.len, remaining.len);
        @memcpy(output[0..used], remaining[0..used]);
        producer.offset += @intCast(used);
        return .{ .progress = used };
    }

    pub fn abort(_: *StreamProducer) void {}

    pub fn join(_: *StreamProducer) void {}
};

fn stream(context: *Context) Context.StreamResponse(StreamProducer) {
    _ = context.state.calls.fetchAdd(1, .monotonic);
    return context.streamUnknown(
        .ok,
        ploof.response.media.octet_stream,
        StreamProducer{},
        &.{},
    );
}

const CountingSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct { bytes: u64 = 0 };
    pub const WriteState = void;
    pub const Summary = u64;
    pub const BeginInput = void;
    pub const Runtime = void;
    pub const StartupState = void;
    pub const Error = error{InvalidBytes};
    pub const io_requirements = ploof.Multipart.IoRequirements.none;
    pub const request_handles_max: u8 = 0;
    pub const runtime_handles_max: u8 = 0;
    pub const initial_state: @This().State = .{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: ploof.Multipart.PollEvent(ploof.Multipart.RuntimeStartInput),
    ) Error!ploof.Multipart.Poll(Runtime) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.InvalidBytes,
        };
    }

    pub fn runtimeStop(
        _: *Runtime,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return synchronous(event);
    }

    pub fn begin(
        _: *Runtime,
        state: *@This().State,
        event: ploof.Multipart.PollEvent(BeginInput),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => {
                state.* = .{};
                return .{ .done = {} };
            },
            .completion => error.InvalidBytes,
        };
    }

    pub fn write(
        _: *Runtime,
        state: *@This().State,
        _: *WriteState,
        event: ploof.Multipart.PollEvent(ploof.Multipart.WriteInput),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => |input| {
                state.bytes = std.math.add(u64, state.bytes, input.bytes.len) catch {
                    return error.InvalidBytes;
                };
                return .{ .done = {} };
            },
            .completion => error.InvalidBytes,
        };
    }

    pub fn finish(
        _: *Runtime,
        state: *@This().State,
        event: ploof.Multipart.PollEvent(ploof.Multipart.FinishInput),
    ) Error!ploof.Multipart.Poll(Summary) {
        return switch (event) {
            .start => |input| if (input.bytes == state.bytes)
                .{ .done = state.bytes }
            else
                error.InvalidBytes,
            .completion => error.InvalidBytes,
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *@This().State,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return synchronous(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *@This().State,
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return synchronous(event);
    }

    fn synchronous(
        event: ploof.Multipart.PollEvent(void),
    ) Error!ploof.Multipart.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.InvalidBytes,
        };
    }
};

const UploadBody = ploof.Multipart.decode(.{
    .count = ploof.Multipart.field(u16, ploof.Multipart.required),
    .upload = ploof.Multipart.file(
        CountingSink,
        ploof.Multipart.required,
    ),
}, .{ .limits = .{
    .encoded_wire_bytes_max = 80 * 1024,
    .total_body_bytes_max = 70 * 1024,
    .file_bytes_max = 64 * 1024,
    .field_bytes_max = 16,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 3,
    .part_header_bytes_max = 512,
    .disposition_parameters_max = 4,
    .delimiter_transport_padding_bytes_max = 16,
    .name_bytes_max = 16,
    .filename_bytes_max = 64,
    .boundary_bytes_max = 70,
} });
const UploadSpec = @TypeOf(UploadBody);
const UploadEndpoint = ploof.Endpoint(.{ .body = UploadBody });

const UploadConsumer = struct {
    pub const State = struct { count: u16 = 0 };

    pub fn init(_: UploadConsumer, _: *Context) UploadConsumer.State {
        return .{};
    }

    pub fn field(
        _: UploadConsumer,
        state: *UploadConsumer.State,
        value: UploadSpec.Field,
    ) void {
        state.count = value.count;
    }

    pub fn fileStart(
        _: UploadConsumer,
        context: *Context,
        _: *UploadConsumer.State,
        value: UploadSpec.FileStart,
    ) UploadSpec.FileAdmission(Context.ResponseType) {
        const metadata = value.upload;
        const filename = metadata.client_filename orelse {
            context.state.reject();
            return .{ .reject = context.textStatic(.bad_request, "upload-fail") };
        };
        if (!std.mem.eql(u8, metadata.part_name, "upload") or
            !std.mem.eql(u8, filename.bytes, "payload.bin"))
        {
            context.state.reject();
            return .{ .reject = context.textStatic(.bad_request, "upload-fail") };
        }
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: UploadConsumer,
        context: *Context,
        state: *UploadConsumer.State,
        _: UploadEndpoint.InputType,
        summaries: UploadSpec.Summaries,
    ) ploof.Multipart.Decision(Context.ResponseType) {
        _ = context.state.calls.fetchAdd(1, .monotonic);
        const uploads = summaries.upload.slice();
        if (state.count != 42 or uploads.len != 1 or uploads[0] != 64 * 1024) {
            context.state.reject();
            return ploof.Multipart.abort(
                context.textStatic(.bad_request, "upload-fail"),
            );
        }
        return ploof.Multipart.commit(context.textStatic(.ok, "upload-ok"));
    }
};

fn requestMetadataValid(context: *Context) bool {
    const metadata = context.request.forwarding orelse {
        context.state.reject();
        return false;
    };
    const valid = metadataValid(context.state.mode, metadata);
    if (!valid) context.state.reject();
    return valid;
}

const credentialed_policy = ploof.Cors.exact(&.{"https://app.example"}, .{
    .credentials = true,
});
const preflight_policy = ploof.Cors.exact(&.{"https://app.example"}, .{
    .request_headers = .{ .exact = &.{"X-Trace"} },
});

const App = ploof.Application(.{
    .State = State,
    .middleware = .{Observe{}},
    .response_gzip = ploof.ResponseGzip{
        .minimum_bytes = 0,
        .level = .fastest,
    },
    .routes = .{
        ploof.get("/identity", identity),
        ploof.get("/cors/wildcard", identity).withCors(ploof.Cors.allow_any),
        ploof.get("/cors/credentialed", identity).withCors(credentialed_policy),
        ploof.get("/cors/null-allow", identity).withCors(
            ploof.Cors.any(.{ .allow_null = true }),
        ),
        ploof.post("/cors/preflight", identity).withCors(preflight_policy),
        ploof.post("/compression", ploof.Body.bytes(.{
            .encoded_wire_bytes_max = 1024,
            .decoded_bytes_max = 1024,
        }, compressed)),
        ploof.get("/stream", stream),
        ploof.get("/normal/slash", normalizedPath),
        ploof.get("/normal\\backslash", normalizedPath),
        ploof.get("/normal%2Fdouble", normalizedPath),
        ploof.get("/normal/unreserved", normalizedPath),
        ploof.get("/normal/./dot", normalizedPath),
        ploof.post("/upload", UploadEndpoint.handle(UploadConsumer{})),
        ploof.get("/finish", identity).withCors(ploof.Cors.allow_any),
    },
});

const forwarding_limits = ploof.Forwarding.Limits{
    .trusted_matchers_max = 2,
    .hops_max = 4,
    .parameters_per_element_max = 4,
};
const RuntimeServer = ploof.Server(App, .{
    .limits = .{
        .connection_slots = 2,
        .request_slots = 2,
        .body_workspace_slots = 2,
        .chunked_workspace_slots = 2,
        .receive_buffers = 4,
        .receive_buffer_bytes = 2048,
        .pipeline_bytes_per_connection = 4096,
        .response_bytes_per_request = 32 * 1024,
        .response_chunk_count = 32,
        .submission_entries = 64,
        .completion_entries = 128,
    },
    .forwarding_limits = forwarding_limits,
});

var origin_server: RuntimeServer align(@alignOf(RuntimeServer)) = RuntimeServer.init();
var origin_state: State = .{ .mode = .direct };

pub fn main(init: std.process.Init.Minimal) void {
    run(init.args) catch |problem| {
        writeFailure(problem);
        linux.exit_group(1);
    };
}

fn run(process_args: std.process.Args) !void {
    const invocation = try parseInvocation(process_args);
    origin_state = .{ .mode = invocation.mode };
    const ready = switch (origin_server.start(&origin_state, .{
        .listener = .{
            .address = .{ .ipv4 = .{ .bytes = .{ 0, 0, 0, 0 } } },
        },
        .forwarding = forwardingConfig(invocation.mode),
        .shutdown = .{
            .grace_ns = 5 * std.time.ns_per_s,
            .force_ns = 5 * std.time.ns_per_s,
        },
    })) {
        .ready => |value| value,
        .failure => |failure| {
            try writeStartupFailure(failure);
            return error.ServerStartupFailed;
        },
    };
    var server_live = true;
    defer if (server_live) forceStop();

    try allocation_guard.denyAddressSpaceGrowth();
    try announceReady(ready.address);
    try waitUntilFinished();
    _ = try origin_server.beginDrain();
    switch (try origin_server.shutdown()) {
        .stopped => server_live = false,
        .incomplete => |report| {
            try writeShutdownReport(report);
            return error.ServerShutdownIncomplete;
        },
    }
    try validateState(invocation.expected_handler_calls);
}

fn forwardingConfig(mode: Mode) ploof.Forwarding.Config {
    return switch (mode) {
        .direct => .{ .family = .x_forwarded },
        .x_forwarded => .{
            .family = .x_forwarded,
            .trusted = &.{"0.0.0.0/0"},
        },
        .proxy_v2_x_forwarded => .{
            .proxy_protocol = .v2_required,
            .family = .x_forwarded,
            .untrusted_peer = .reject,
            .trusted = &.{"0.0.0.0/0"},
        },
    };
}

fn metadataValid(mode: Mode, metadata: ploof.Forwarding.Metadata) bool {
    const scheme: ploof.Forwarding.Scheme = if (mode == .direct) .http else .https;
    const expected_authority = authority.parse("app.test", scheme) catch return false;
    if (!metadata.authority.eql(expected_authority)) return false;
    if (metadata.scheme != scheme) return false;

    if (mode == .direct) {
        return metadata.connection_source == .transport and
            metadata.client_provenance == .transport and
            metadata.host_provenance == .host and
            metadata.scheme_provenance == .connection and
            metadata.forwarding_headers == .ignored_untrusted and
            metadata.trusted_hops == 0 and
            ploof.address.Endpoint.eql(metadata.transport_peer, metadata.connection_peer) and
            ploof.address.Endpoint.eql(metadata.connection_peer, metadata.client);
    }

    const expected_source: ploof.Forwarding.ConnectionSource = switch (mode) {
        .direct => unreachable,
        .x_forwarded => .transport,
        .proxy_v2_x_forwarded => .proxy_protocol_v2,
    };
    return metadata.connection_source == expected_source and
        metadata.client_provenance == .x_forwarded and
        metadata.host_provenance == .x_forwarded_host and
        metadata.scheme_provenance == .x_forwarded_proto and
        metadata.forwarding_headers == .applied and
        metadata.trusted_hops == 1;
}

fn parseInvocation(process_args: std.process.Args) !Invocation {
    var args = process_args.iterate();
    defer args.deinit();
    _ = args.next() orelse return error.MissingProgramName;
    const raw = args.next() orelse return error.MissingMode;
    const raw_expected = args.next() orelse return error.MissingExpectedHandlerCalls;
    if (args.next() != null) return error.UnexpectedArgument;
    const mode: Mode = if (std.mem.eql(u8, raw, "direct"))
        .direct
    else if (std.mem.eql(u8, raw, "x-forwarded"))
        .x_forwarded
    else if (std.mem.eql(u8, raw, "proxy-v2-x-forwarded"))
        .proxy_v2_x_forwarded
    else
        return error.InvalidMode;
    const expected = std.fmt.parseUnsigned(u32, raw_expected, 10) catch {
        return error.InvalidExpectedHandlerCalls;
    };
    if (expected == 0) return error.InvalidExpectedHandlerCalls;
    return .{ .mode = mode, .expected_handler_calls = expected };
}

fn waitUntilFinished() !void {
    const deadline = try std.math.add(u64, try monotonicNow(), completion_wait_ns);
    while (!origin_state.finished.load(.acquire)) {
        if (try monotonicNow() >= deadline) return error.CompletionWaitTimedOut;
        const pause = linux.timespec{ .sec = 0, .nsec = poll_pause_ns };
        const pause_error = linux.errno(linux.nanosleep(&pause, null));
        if (pause_error != .SUCCESS and pause_error != .INTR) {
            return error.CompletionPollSleepFailed;
        }
    }
}

fn validateState(expected_handler_calls: u32) !void {
    if (origin_state.calls.load(.acquire) != expected_handler_calls) {
        return error.UnexpectedHandlerCallCount;
    }
    if (origin_state.completed.load(.acquire) != expected_handler_calls) {
        return error.UnexpectedCompletionCount;
    }
    if (!origin_state.finished.load(.acquire)) return error.CompletionNotObserved;
    if (!origin_state.valid.load(.acquire)) return error.InvalidForwardingMetadata;
}

fn forceStop() void {
    _ = origin_server.beginDrain() catch {};
    _ = origin_server.beginForced() catch {};
    _ = origin_server.shutdown() catch {};
}

fn monotonicNow() !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0) return error.ClockUnavailable;
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    return std.math.add(u64, seconds, @intCast(value.nsec));
}

fn announceReady(bound: anytype) !void {
    const port = switch (bound) {
        .ipv4 => |ipv4| ipv4.port,
        .ipv6 => return error.UnexpectedAddressFamily,
    };
    var buffer: [16]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "READY {d}\n", .{port});
    try writeAll(1, message);
}

fn writeStartupFailure(failure: RuntimeServer.StartupFailure) !void {
    var output: [server_startup.rendered_bytes_max]u8 = undefined;
    try writeAll(2, try failure.render(&output));
}

fn writeShutdownReport(report: ploof.Lifecycle.ShutdownIncomplete) !void {
    var output: [512]u8 = undefined;
    try writeAll(2, try report.render(&output));
}

fn writeAll(descriptor: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(descriptor, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.WriteFailed;
                written += result;
            },
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn writeFailure(problem: anyerror) void {
    writeAll(2, "Ploof proxy interop origin failed: ") catch {};
    writeAll(2, @errorName(problem)) catch {};
    writeAll(2, "\n") catch {};
}
