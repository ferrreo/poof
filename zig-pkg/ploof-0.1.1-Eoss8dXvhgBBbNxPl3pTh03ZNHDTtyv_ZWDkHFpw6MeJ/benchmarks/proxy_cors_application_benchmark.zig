const std = @import("std");
const sigbench = @import("sigbench");
const application = @import("../src/application.zig");
const cors = @import("../src/cors.zig");
const response = @import("../src/response.zig");
const route = @import("../src/route.zig");
const http1_limits = @import("../src/internal/http1/limits.zig");
const request_accept_encoding = @import("../src/internal/http1/request_accept_encoding.zig");
const request_head = @import("../src/internal/http1/request_head.zig");

const fixed_date = "Wed, 15 Jul 2026 12:00:00 GMT";
const Decoder = request_head.Decoder(http1_limits.standard_request_head_limits);
const Context = application.Context(void, response.standard_head_limits);
const Response = Context.ResponseType;
const gzip_payload = [_]u8{'a'} ** 4096;
const output_bytes_max = 32 * 1024;
const request_bytes_max = 4096;
const non_cors_request = "GET /bench HTTP/1.1\r\nHost: example.test\r\n\r\n";
const gzip_request = "GET /bench HTTP/1.1\r\nHost: example.test\r\n" ++
    "Origin: https://app.example\r\n" ++
    "Accept-Encoding: gzip, identity;q=0\r\n\r\n";

const Case = enum {
    disabled_non_cors,
    enabled_non_cors,
    allowed_actual,
    allowed_preflight,
    denied_preflight,
    max_origins_actual,
    max_origins_headers_preflight,
    gzip_disabled_origin,
    gzip_enabled_actual,
};

const expected_fingerprints = [_]u64{
    0x196f7df0bed72d49,
    0x767da4611e6b030c,
    0x6073066037d88222,
    0xb68edf638aa7ce98,
    0xc239588be4a85bd2,
    0xfd4c4c72d65b4fb9,
    0x059d98fa9b8213b8,
    0x79296171467fb3bd,
    0xa208d70018d80b08,
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof Application CORS benchmark validity check failed");
}

fn smallHandler(context: *Context) Response {
    return context.textStatic(.ok, "ok");
}

fn gzipHandler(context: *Context) Response {
    return context.textStatic(.ok, &gzip_payload);
}

fn exactOrigins() [cors.exact_origins_hard_max][]const u8 {
    @setEvalBranchQuota(50_000);
    var result: [cors.exact_origins_hard_max][]const u8 = undefined;
    inline for (0..result.len) |index| {
        result[index] = std.fmt.comptimePrint("https://origin-{d}.example", .{index});
    }
    return result;
}

fn exactHeaders() [cors.exact_request_headers_hard_max][]const u8 {
    @setEvalBranchQuota(50_000);
    var result: [cors.exact_request_headers_hard_max][]const u8 = undefined;
    inline for (0..result.len) |index| {
        result[index] = std.fmt.comptimePrint("X-Bench-{d}", .{index});
    }
    return result;
}

const max_origins = exactOrigins();
const max_headers = exactHeaders();
const basic_policy = cors.exact(&.{"https://app.example"}, .{
    .credentials = true,
    .request_headers = .{ .exact = &.{ "Authorization", "X-Trace" } },
});
const maximum_policy = cors.exact(&max_origins, .{
    .credentials = true,
    .request_headers = .{ .exact = &max_headers },
});

const DisabledApp = application.Application(.{
    .State = void,
    .routes = .{route.get("/bench", smallHandler)},
});
const EnabledApp = application.Application(.{
    .State = void,
    .cors = basic_policy,
    .routes = .{route.get("/bench", smallHandler)},
});
const MaximumApp = application.Application(.{
    .State = void,
    .cors = maximum_policy,
    .routes = .{route.get("/bench", smallHandler)},
});
const GzipDisabledApp = application.Application(.{
    .State = void,
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
    .routes = .{route.get("/bench", gzipHandler)},
});
const GzipEnabledApp = application.Application(.{
    .State = void,
    .cors = basic_policy,
    .response_gzip = application.ResponseGzip{ .minimum_bytes = 0 },
    .routes = .{route.get("/bench", gzipHandler)},
});

fn Runner(comptime App: type, comptime case: Case) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var request_storage: [request_bytes_max]u8 = undefined;
            const wire = buildRequest(case, &request_storage);
            var decoder = Decoder.init();
            const input = decodeInput(&decoder, wire);
            var state: void = {};
            var workspace = App.Workspace{};
            var route_workspace: App.RouteSearchWorkspace = undefined;
            var gzip_workspace: App.ResponseGzipWorkspace = undefined;
            var output: [output_bytes_max]u8 = undefined;
            var last: application.ServeResult = undefined;
            std.mem.doNotOptimizeAway(&input);
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = serveApplication(
                    App,
                    case,
                    &state,
                    &workspace,
                    &route_workspace,
                    input,
                    &output,
                    &gzip_workspace,
                ) catch {
                    benchmarkFailure();
                };
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validate(case, last);
            return elapsed_ns;
        }
    };
}

fn serveApplication(
    comptime App: type,
    comptime case: Case,
    state: *void,
    workspace: *App.Workspace,
    route_workspace: *App.RouteSearchWorkspace,
    input: application.Input,
    output: []u8,
    gzip_workspace: *App.ResponseGzipWorkspace,
) !application.ServeResult {
    if (case != .gzip_disabled_origin and case != .gzip_enabled_actual) {
        return App.serve(state, workspace, route_workspace, input, output);
    }
    var request_plan = App.plan(input, route_workspace);
    const head_result = try App.__prepareHeadPlannedWithResponseGzip(
        state,
        workspace,
        &.{},
        output,
        &request_plan,
        .{},
        gzip_workspace,
    );
    const prepared = switch (head_result) {
        .prepared => |value| value,
        .receive_body => return error.UnexpectedBody,
    };
    const outcome = try App.complete(workspace);
    return .{
        .bytes = prepared.bytes,
        .status = prepared.status,
        .transport = outcome.transport,
    };
}

fn buildRequest(comptime case: Case, storage: []u8) []const u8 {
    return switch (case) {
        .disabled_non_cors, .enabled_non_cors => non_cors_request,
        .allowed_actual => "GET /bench HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\n\r\n",
        .allowed_preflight => "OPTIONS /bench HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://app.example\r\nAccess-Control-Request-Method: GET\r\n" ++
            "Access-Control-Request-Headers: authorization, x-trace\r\n\r\n",
        .denied_preflight => "OPTIONS /bench HTTP/1.1\r\nHost: example.test\r\n" ++
            "Origin: https://denied.example\r\nAccess-Control-Request-Method: GET\r\n\r\n",
        .max_origins_actual => buildMaximumActual(storage),
        .max_origins_headers_preflight => buildMaximumPreflight(storage),
        .gzip_disabled_origin, .gzip_enabled_actual => gzip_request,
    };
}

fn buildMaximumActual(storage: []u8) []const u8 {
    var used: usize = 0;
    append(storage, &used, "GET /bench HTTP/1.1\r\nHost: example.test\r\nOrigin: ");
    append(storage, &used, max_origins[max_origins.len - 1]);
    append(storage, &used, "\r\n\r\n");
    return storage[0..used];
}

fn buildMaximumPreflight(storage: []u8) []const u8 {
    var used: usize = 0;
    append(storage, &used, "OPTIONS /bench HTTP/1.1\r\nHost: example.test\r\nOrigin: ");
    append(storage, &used, max_origins[max_origins.len - 1]);
    append(storage, &used, "\r\nAccess-Control-Request-Method: GET\r\n");
    append(storage, &used, "Access-Control-Request-Headers: ");
    for (max_headers, 0..) |name, index| {
        if (index != 0) append(storage, &used, ", ");
        append(storage, &used, name);
    }
    append(storage, &used, "\r\n\r\n");
    return storage[0..used];
}

fn append(output: []u8, used: *usize, bytes: []const u8) void {
    if (bytes.len > output.len - used.*) benchmarkFailure();
    @memcpy(output[used.*..][0..bytes.len], bytes);
    used.* += bytes.len;
}

fn decodeInput(decoder: *Decoder, wire: []const u8) application.Input {
    const feed = decoder.feed(wire);
    const head = switch (feed.state) {
        .ready => |value| value,
        .need_more, .rejected => benchmarkFailure(),
    };
    if (feed.consumed != wire.len) benchmarkFailure();
    const bytes = decoder.bytes();
    const target = head.target.slice(bytes);
    const accept_encoding = switch (request_accept_encoding.analyze(
        decoder.fields(),
        bytes,
    )) {
        .accepted => |value| value,
        .rejected => benchmarkFailure(),
    };
    return .{
        .method = head.method.slice(bytes),
        .path = target,
        .raw_target = target,
        .raw_path = target,
        .date = fixed_date,
        .accept_encoding = accept_encoding,
        .headers = .{ .bytes = bytes, .fields = decoder.fields() },
    };
}

fn validate(case: Case, result: application.ServeResult) void {
    if (result.transport != .completed) benchmarkFailure();
    const body = responseBody(result.bytes);
    switch (case) {
        .disabled_non_cors => {
            expectStatusBody(result, .ok, "ok");
            expectAbsent(result.bytes, "access-control-");
            expectAbsent(result.bytes, "vary: Origin\r\n");
        },
        .enabled_non_cors => {
            expectStatusBody(result, .ok, "ok");
            expectAbsent(result.bytes, "access-control-");
            expectPresent(result.bytes, "vary: Origin\r\n");
        },
        .allowed_actual => {
            expectStatusBody(result, .ok, "ok");
            expectPresent(result.bytes, "access-control-allow-origin: https://app.example\r\n");
            expectPresent(result.bytes, "access-control-allow-credentials: true\r\n");
        },
        .max_origins_actual => {
            expectStatusBody(result, .ok, "ok");
            expectPresent(result.bytes, max_origins[max_origins.len - 1]);
            expectPresent(result.bytes, "access-control-allow-credentials: true\r\n");
        },
        .allowed_preflight => {
            if (result.status != .no_content or body.len != 0) benchmarkFailure();
            expectPresent(result.bytes, "access-control-allow-methods: GET\r\n");
            expectPresent(result.bytes, "access-control-allow-origin: https://app.example\r\n");
            expectPresent(result.bytes, "access-control-allow-headers: authorization, x-trace\r\n");
        },
        .max_origins_headers_preflight => {
            if (result.status != .no_content or body.len != 0) benchmarkFailure();
            expectPresent(result.bytes, "access-control-allow-methods: GET\r\n");
            expectPresent(result.bytes, max_origins[max_origins.len - 1]);
            expectPresent(result.bytes, "access-control-allow-headers: X-Bench-0");
            expectPresent(result.bytes, "X-Bench-63\r\n");
        },
        .denied_preflight => {
            if (result.status != .forbidden or body.len != 0) benchmarkFailure();
            expectAbsent(result.bytes, "access-control-allow-origin");
        },
        .gzip_disabled_origin, .gzip_enabled_actual => {
            if (result.status != .ok or body.len == 0) benchmarkFailure();
            expectPresent(result.bytes, "content-encoding: gzip\r\n");
            if (case == .gzip_enabled_actual) {
                expectPresent(result.bytes, "access-control-allow-origin: https://app.example");
            } else {
                expectAbsent(result.bytes, "access-control-allow-origin");
            }
        },
    }
    const actual_fingerprint = resultFingerprint(result);
    const case_index: u4 = @intCast(@intFromEnum(case));
    const expected = expected_fingerprints[case_index];
    if (actual_fingerprint != expected) benchmarkFailure();
}

fn resultFingerprint(result: application.ServeResult) u64 {
    const status: u16 = @intFromEnum(result.status);
    const status_bytes = [2]u8{ @truncate(status), @truncate(status >> 8) };
    var checksum = std.hash.Fnv1a_64.init();
    checksum.update(&status_bytes);
    checksum.update(result.bytes);
    return checksum.final();
}

fn expectStatusBody(
    result: application.ServeResult,
    status: response.Status,
    expected_body: []const u8,
) void {
    if (result.status != status) benchmarkFailure();
    if (!std.mem.eql(u8, responseBody(result.bytes), expected_body)) benchmarkFailure();
}

fn responseBody(wire: []const u8) []const u8 {
    const separator = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse benchmarkFailure();
    return wire[separator + 4 ..];
}

fn expectPresent(wire: []const u8, expected: []const u8) void {
    if (std.mem.indexOf(u8, wire, expected) == null) benchmarkFailure();
}

fn expectAbsent(wire: []const u8, denied: []const u8) void {
    if (std.mem.indexOf(u8, wire, denied) != null) benchmarkFailure();
}

const DisabledNonCors = Runner(DisabledApp, .disabled_non_cors);
const EnabledNonCors = Runner(EnabledApp, .enabled_non_cors);
const AllowedActual = Runner(EnabledApp, .allowed_actual);
const AllowedPreflight = Runner(EnabledApp, .allowed_preflight);
const DeniedPreflight = Runner(EnabledApp, .denied_preflight);
const MaximumOrigins = Runner(MaximumApp, .max_origins_actual);
const MaximumPreflight = Runner(MaximumApp, .max_origins_headers_preflight);
const GzipDisabled = Runner(GzipDisabledApp, .gzip_disabled_origin);
const GzipEnabled = Runner(GzipEnabledApp, .gzip_enabled_actual);

pub const group = sigbench.groupWithId(
    "m7-cors-application",
    "M7 full Application CORS feature tax",
    .{
        sigbench.benchWithThroughput(
            "disabled-non-cors",
            "CORS-disabled Application non-CORS request",
            .{ .elements = 1 },
            DisabledNonCors.bench,
        ),
        sigbench.benchWithThroughput(
            "enabled-non-cors",
            "CORS-enabled Application non-CORS request",
            .{ .elements = 1 },
            EnabledNonCors.bench,
        ),
        sigbench.benchWithThroughput(
            "allowed-actual",
            "allowed exact credentialed actual request",
            .{ .elements = 1 },
            AllowedActual.bench,
        ),
        sigbench.benchWithThroughput(
            "allowed-preflight",
            "allowed route-derived preflight",
            .{ .elements = 1 },
            AllowedPreflight.bench,
        ),
        sigbench.benchWithThroughput(
            "denied-preflight",
            "denied route-derived preflight",
            .{ .elements = 1 },
            DeniedPreflight.bench,
        ),
        sigbench.benchWithThroughput(
            "max-64-origins-actual",
            "last match across 64 exact origins",
            .{ .elements = 1 },
            MaximumOrigins.bench,
        ),
        sigbench.benchWithThroughput(
            "max-64-origins-headers-preflight",
            "64 exact origins and 64 requested headers preflight",
            .{ .elements = 1 },
            MaximumPreflight.bench,
        ),
        sigbench.benchWithThroughput(
            "gzip-disabled-origin",
            "CORS-disabled Application gzip response with Origin",
            .{ .bytes = gzip_payload.len },
            GzipDisabled.bench,
        ),
        sigbench.benchWithThroughput(
            "gzip-enabled-actual",
            "CORS-enabled allowed actual gzip response",
            .{ .bytes = gzip_payload.len },
            GzipEnabled.bench,
        ),
    },
);
