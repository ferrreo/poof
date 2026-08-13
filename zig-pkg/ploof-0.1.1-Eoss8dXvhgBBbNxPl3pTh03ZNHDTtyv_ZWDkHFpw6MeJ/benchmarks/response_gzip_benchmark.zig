const std = @import("std");
const sigbench = @import("sigbench");
const response = @import("../src/response.zig");
const serializer = @import("../src/internal/application/response_gzip.zig");
const gzip_encoder = @import("../src/internal/runtime/gzip/encoder.zig");
const runtime_config = @import("../src/internal/runtime/config.zig");
const syntax = @import("../src/internal/http1/syntax.zig");
const support = @import("response_gzip_benchmark_support.zig");

const limits = response.standard_head_limits;
const ResponseWorkspace = response.Workspace(limits);
const Response = response.Response(limits);
const output_bytes_max: usize = 96 * 1024;
const fallback_output_bytes: usize = 8 * 1024;
const payload_bytes_max: usize = 48 * 1024;
const default_output_bytes: usize = (runtime_config.Limits{}).response_bytes_per_request;
const bound_minus_one_output_bytes: usize = limits.head_bytes_max +
    (gzip_encoder.bound(payload_bytes_max) catch unreachable) - 1;
const date = "Thu, 01 Jan 1970 00:00:00 GMT";

const Media = support.Media;
const Entropy = support.Entropy;

const tight_head_limits = response.HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 4,
});

const Mode = enum {
    gzip,
    head,
    identity,
    below_threshold,
    capacity_fallback,
    default_staging_gzip,
    bound_minus_one_fallback,
    post_compress_head_fallback,
    header_rich_identity,
    no_transform,
    strong_etag,
};

const Spec = struct {
    media: Media,
    entropy: Entropy,
    bytes: usize,
    level: gzip_encoder.Level = .fastest,
    mode: Mode = .gzip,
};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof response-gzip benchmark validity check failed");
}

fn fixture(comptime spec: Spec) support.Fixture(spec.bytes) {
    return support.fixture(spec.media, spec.entropy, spec.bytes);
}

fn Runner(comptime spec: Spec) type {
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            return runCase(spec, iterations);
        }
    };
}

const Definition = struct {
    id: []const u8,
    name: []const u8,
    spec: Spec,
    inspect_metric: *const fn () support.Metric,
};

fn benchmark(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime spec: Spec,
) Definition {
    return .{
        .id = id,
        .name = name,
        .spec = spec,
        .inspect_metric = MetricRunner(id, spec).inspect,
    };
}

fn MetricRunner(comptime id: []const u8, comptime spec: Spec) type {
    return struct {
        fn inspect() support.Metric {
            return inspectMetric(id, spec);
        }
    };
}

fn sigbenchCase(comptime definition: Definition) sigbench.BenchmarkCase {
    return sigbench.benchWithThroughput(
        definition.id,
        definition.name,
        .{ .bytes = definition.spec.bytes },
        Runner(definition.spec).bench,
    );
}

fn runCase(comptime spec: Spec, iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    const payload = comptime fixture(spec);
    var response_workspace = ResponseWorkspace{};
    var value = responseValue(spec, &response_workspace, &payload);
    addSpecialHeader(spec, &value);
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [output_bytes_max]u8 = undefined;
    const selected_output = output[0..outputLength(spec)];
    const request = requestFields(spec);

    @memset(std.mem.asBytes(&encoder), 0xa5);
    const before = serialize(spec, &value, request, selected_output, &encoder);
    validatePrepared(spec, before, &payload);
    validateScrub(spec, &encoder);
    if (spec.mode == .head) {
        const head_length = parseContentLength(splitWire(before.bytes).head);
        validateHeadRoundTrip(spec, &value, request, &output, &encoder, head_length);
    }

    var last = before;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        const prepared = serialize(spec, &value, request, selected_output, &encoder);
        std.mem.doNotOptimizeAway(prepared.bytes.ptr);
        std.mem.doNotOptimizeAway(prepared.bytes.len);
        last = prepared;
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;

    validateScrub(spec, &encoder);
    validatePrepared(spec, last, &payload);
    return elapsed_ns;
}

fn responseValue(
    comptime spec: Spec,
    workspace: *ResponseWorkspace,
    payload: []const u8,
) Response {
    return switch (spec.media) {
        .html => Response.htmlBorrowed(workspace, .ok, payload),
        .json => Response.jsonBorrowed(workspace, .ok, payload),
    };
}

fn addSpecialHeader(comptime spec: Spec, value: *Response) void {
    switch (spec.mode) {
        .header_rich_identity => inline for (.{
            .{ "X-Request-Id", "req_01J2Y8Z6F4" },
            .{ "Content-Language", "en-GB" },
            .{ "X-Frame-Options", "DENY" },
            .{ "X-Content-Type-Options", "nosniff" },
            .{ "Cross-Origin-Resource-Policy", "same-site" },
            .{ "Permissions-Policy", "camera=(), microphone=()" },
            .{ "Server-Timing", "app;dur=2.4, db;dur=0.8" },
            .{ "Link", "</app.css>; rel=preload; as=style" },
            .{ "Vary", "Origin, Accept-Language" },
            .{ "ETag", "W/\"activity-feed-1042\"" },
            .{ "Cache-Control", "public, max-age=60, stale-while-revalidate=30" },
        }) |field| value.setHeaderStatic(
            field[0],
            field[1],
        ) catch benchmarkFailure(),
        .no_transform => value.setHeaderStatic(
            "Cache-Control",
            "public, no-transform",
        ) catch benchmarkFailure(),
        .strong_etag => value.setHeaderStatic(
            "ETag",
            "\"response-gzip-benchmark\"",
        ) catch benchmarkFailure(),
        else => {},
    }
}

fn requestFields(comptime spec: Spec) serializer.RequestFields {
    return .{
        .method = if (spec.mode == .head) "HEAD" else "GET",
        .accept_encoding = switch (spec.mode) {
            .identity, .header_rich_identity => .{ .gzip = 500, .identity = 1000 },
            else => .{ .gzip = 1000, .identity = 1000 },
        },
        .accepts_response_trailers = false,
        .date = date,
        .connection_close = false,
    };
}

fn serialize(
    comptime spec: Spec,
    value: *Response,
    request: serializer.RequestFields,
    output: []u8,
    encoder: *gzip_encoder.Workspace,
) serializer.Prepared {
    const selected_limits = if (spec.mode == .post_compress_head_fallback)
        tight_head_limits
    else
        limits;
    return serializer.serialize(
        selected_limits,
        limits,
        value,
        request,
        output,
        encoder,
        .{
            .minimum_bytes = if (spec.mode == .below_threshold) 1024 else 0,
            .level = spec.level,
        },
        null,
    ) catch benchmarkFailure();
}

fn outputLength(comptime spec: Spec) usize {
    return if (spec.mode == .capacity_fallback)
        fallback_output_bytes
    else if (spec.mode == .default_staging_gzip)
        default_output_bytes
    else if (spec.mode == .bound_minus_one_fallback)
        bound_minus_one_output_bytes
    else
        output_bytes_max;
}

fn expectedOutcome(comptime mode: Mode) serializer.CodingOutcome {
    return switch (mode) {
        .gzip, .head, .default_staging_gzip => .gzip,
        .identity, .header_rich_identity => .identity_negotiated,
        .below_threshold => .identity_below_threshold,
        .capacity_fallback,
        .bound_minus_one_fallback,
        .post_compress_head_fallback,
        => .identity_capacity_fallback,
        .no_transform, .strong_etag => .skipped_ineligible,
    };
}

fn validateScrub(comptime spec: Spec, encoder: *gzip_encoder.Workspace) void {
    if (!attemptsGzip(spec.mode)) return;
    const expected: u8 = switch (spec.mode) {
        .capacity_fallback, .bound_minus_one_fallback => 0xa5,
        else => 0,
    };
    for (std.mem.asBytes(encoder)) |byte| {
        if (byte != expected) benchmarkFailure();
    }
}

fn attemptsGzip(comptime mode: Mode) bool {
    return switch (mode) {
        .gzip,
        .head,
        .capacity_fallback,
        .default_staging_gzip,
        .bound_minus_one_fallback,
        .post_compress_head_fallback,
        => true,
        else => false,
    };
}

fn validatePrepared(
    comptime spec: Spec,
    prepared: serializer.Prepared,
    expected: []const u8,
) void {
    if (prepared.status != .ok or prepared.close_connection) benchmarkFailure();
    if (prepared.coding_outcome != expectedOutcome(spec.mode)) benchmarkFailure();
    const wire = splitWire(prepared.bytes);
    const content_length = parseContentLength(wire.head);
    const content_type = headerValue(wire.head, "content-type") orelse benchmarkFailure();
    const expected_type = switch (spec.media) {
        .html => "text/html; charset=utf-8",
        .json => "application/json; charset=utf-8",
    };
    if (!std.mem.eql(u8, content_type, expected_type)) benchmarkFailure();
    const compressed = expectedOutcome(spec.mode) == .gzip;
    const content_encoding = headerValue(wire.head, "content-encoding");
    if (compressed) {
        if (!std.mem.eql(u8, content_encoding orelse benchmarkFailure(), "gzip")) {
            benchmarkFailure();
        }
    } else if (content_encoding != null) {
        benchmarkFailure();
    }
    if (!headerListContains(wire.head, "vary", "Accept-Encoding")) {
        benchmarkFailure();
    }
    validateSpecialHeader(spec, wire.head);

    if (spec.mode == .head) {
        if (wire.body.len != 0) benchmarkFailure();
        validateRatio(spec, content_length);
    } else if (compressed) {
        if (wire.body.len != content_length) benchmarkFailure();
        validateRoundTrip(wire.body, expected);
        validateRatio(spec, wire.body.len);
    } else {
        if (content_length != expected.len) benchmarkFailure();
        if (!std.mem.eql(u8, wire.body, expected)) benchmarkFailure();
    }
}

fn validateSpecialHeader(comptime spec: Spec, head: []const u8) void {
    switch (spec.mode) {
        .no_transform => {
            const value = headerValue(head, "cache-control") orelse benchmarkFailure();
            if (!std.mem.eql(u8, value, "public, no-transform")) benchmarkFailure();
        },
        .strong_etag => {
            const value = headerValue(head, "etag") orelse benchmarkFailure();
            if (!std.mem.eql(u8, value, "\"response-gzip-benchmark\"")) {
                benchmarkFailure();
            }
        },
        else => {},
    }
}

fn validateHeadRoundTrip(
    comptime spec: Spec,
    value: *Response,
    request: serializer.RequestFields,
    output: *[output_bytes_max]u8,
    encoder: *gzip_encoder.Workspace,
    head_length: usize,
) void {
    var get_request = request;
    get_request.method = "GET";
    const prepared = serialize(spec, value, get_request, output, encoder);
    if (prepared.coding_outcome != .gzip) benchmarkFailure();
    const wire = splitWire(prepared.bytes);
    if (wire.body.len != head_length) benchmarkFailure();
    validateRoundTrip(wire.body, value.bodyBytes());
    validateScrub(spec, encoder);
}

const Wire = struct {
    head: []const u8,
    body: []const u8,
};

fn splitWire(bytes: []const u8) Wire {
    const marker = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse benchmarkFailure();
    const body_start = marker + 4;
    return .{ .head = bytes[0..body_start], .body = bytes[body_start..] };
}

fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!syntax.eqlIgnoreCase(line[0..colon], name)) continue;
        return syntax.trimOws(line[colon + 1 ..]);
    }
    return null;
}

fn headerListContains(head: []const u8, name: []const u8, member: []const u8) bool {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!syntax.eqlIgnoreCase(line[0..colon], name)) continue;
        var values = std.mem.splitScalar(u8, line[colon + 1 ..], ',');
        while (values.next()) |value| {
            if (syntax.eqlIgnoreCase(syntax.trimOws(value), member)) return true;
        }
    }
    return false;
}

fn parseContentLength(head: []const u8) usize {
    const value = headerValue(head, "content-length") orelse benchmarkFailure();
    return std.fmt.parseUnsigned(usize, value, 10) catch benchmarkFailure();
}

fn validateRoundTrip(encoded: []const u8, expected: []const u8) void {
    var decoded: [payload_bytes_max]u8 = undefined;
    if (expected.len > decoded.len) benchmarkFailure();
    var input_reader = std.Io.Reader.fixed(encoded);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var writer = std.Io.Writer.fixed(&decoded);
    const written = decoder.reader.streamRemaining(&writer) catch benchmarkFailure();
    if (written != expected.len) benchmarkFailure();
    if (!std.mem.eql(u8, decoded[0..written], expected)) benchmarkFailure();
}

fn validateRatio(comptime spec: Spec, encoded_bytes: usize) void {
    if (spec.entropy == .compressible and spec.bytes >= 4096) {
        if (encoded_bytes * 4 >= spec.bytes) benchmarkFailure();
    }
    if (spec.entropy == .realistic) {
        if (encoded_bytes * 5 < spec.bytes or encoded_bytes * 4 > spec.bytes * 3) {
            benchmarkFailure();
        }
    }
    if (spec.entropy == .seeded_incompressible) {
        if (encoded_bytes * 4 < spec.bytes * 3) benchmarkFailure();
        if (encoded_bytes > spec.bytes + spec.bytes / 8) benchmarkFailure();
    }
    if (spec.entropy == .utf8_incompressible) {
        if (encoded_bytes * 4 < spec.bytes * 3) benchmarkFailure();
        if (encoded_bytes > spec.bytes + spec.bytes / 8) benchmarkFailure();
    }
}

pub fn writeMetricsReport(
    init: std.process.Init,
    default_output_root: []const u8,
) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }

    var metrics: [definitions.len]support.Metric = undefined;
    for (definitions, 0..) |definition, index| {
        metrics[index] = definition.inspect_metric();
    }
    try support.writeMetrics(init, output_root, &metrics);
}

fn inspectMetric(comptime id: []const u8, comptime spec: Spec) support.Metric {
    const payload = comptime fixture(spec);
    var candidate_workspace: gzip_encoder.Workspace = undefined;
    var candidate_output: [output_bytes_max]u8 = undefined;
    const bound = gzip_encoder.bound(payload.len) catch benchmarkFailure();
    const candidate = gzip_encoder.compress(
        &candidate_workspace,
        &payload,
        candidate_output[0..bound],
        spec.level,
    ) catch benchmarkFailure();
    validateRoundTrip(candidate, &payload);
    validateRatio(spec, candidate.len);
    std.crypto.secureZero(u8, std.mem.asBytes(&candidate_workspace));

    var response_workspace = ResponseWorkspace{};
    var value = responseValue(spec, &response_workspace, &payload);
    addSpecialHeader(spec, &value);
    var encoder: gzip_encoder.Workspace = undefined;
    var output: [output_bytes_max]u8 = undefined;
    @memset(std.mem.asBytes(&encoder), 0xa5);
    const prepared = serialize(
        spec,
        &value,
        requestFields(spec),
        output[0..outputLength(spec)],
        &encoder,
    );
    validateScrub(spec, &encoder);
    const compressed = expectedOutcome(spec.mode) == .gzip;
    if (compressed) {
        validatePrepared(spec, prepared, &payload);
        const wire = splitWire(prepared.bytes);
        if (spec.mode != .head and !std.mem.eql(u8, wire.body, candidate)) {
            benchmarkFailure();
        }
    } else {
        if (prepared.status != .ok or prepared.close_connection) benchmarkFailure();
        if (prepared.coding_outcome != expectedOutcome(spec.mode)) benchmarkFailure();
        if (!std.mem.endsWith(u8, prepared.bytes, &payload)) benchmarkFailure();
    }
    return .{
        .id = id,
        .input_bytes = payload.len,
        .candidate_gzip_bytes = candidate.len,
        .content_length = if (compressed) candidate.len else payload.len,
        .wire_body_bytes = if (spec.mode == .head)
            0
        else if (compressed)
            candidate.len
        else
            payload.len,
        .coding_outcome = @tagName(prepared.coding_outcome),
    };
}

const definitions = [_]Definition{
    benchmark("html-comp-512-fastest", "HTML compressible 512 B fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 512,
    }),
    benchmark("html-comp-1023-fastest", "HTML compressible 1,023 B fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 1023,
    }),
    benchmark("html-comp-1024-fastest", "HTML compressible 1 KiB fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 1024,
    }),
    benchmark("html-comp-1025-fastest", "HTML compressible 1,025 B fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 1025,
    }),
    benchmark("html-comp-4096-fastest", "HTML compressible 4 KiB fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 4096,
    }),
    benchmark("html-comp-16384-fastest", "HTML compressible 16 KiB fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 16 * 1024,
    }),
    benchmark("html-comp-49152-fastest", "HTML compressible 48 KiB fastest", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 48 * 1024,
    }),
    benchmark("json-comp-512-fastest", "JSON compressible 512 B fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 512,
    }),
    benchmark("json-comp-1023-fastest", "JSON compressible 1,023 B fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 1023,
    }),
    benchmark("json-comp-1024-fastest", "JSON compressible 1 KiB fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 1024,
    }),
    benchmark("json-comp-1025-fastest", "JSON compressible 1,025 B fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 1025,
    }),
    benchmark("json-comp-4096-fastest", "JSON compressible 4 KiB fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 4096,
    }),
    benchmark("json-comp-16384-fastest", "JSON compressible 16 KiB fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 16 * 1024,
    }),
    benchmark("json-comp-49152-fastest", "JSON compressible 48 KiB fastest", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 48 * 1024,
    }),
    benchmark("html-seeded-1024-fastest", "HTML seeded incompressible 1 KiB fastest", .{
        .media = .html,
        .entropy = .seeded_incompressible,
        .bytes = 1024,
    }),
    benchmark("html-seeded-16384-fastest", "HTML seeded incompressible 16 KiB fastest", .{
        .media = .html,
        .entropy = .seeded_incompressible,
        .bytes = 16 * 1024,
    }),
    benchmark("html-seeded-49152-fastest", "HTML seeded incompressible 48 KiB fastest", .{
        .media = .html,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
    }),
    benchmark("json-seeded-1024-fastest", "JSON seeded incompressible 1 KiB fastest", .{
        .media = .json,
        .entropy = .seeded_incompressible,
        .bytes = 1024,
    }),
    benchmark("json-seeded-16384-fastest", "JSON seeded incompressible 16 KiB fastest", .{
        .media = .json,
        .entropy = .seeded_incompressible,
        .bytes = 16 * 1024,
    }),
    benchmark("json-seeded-49152-fastest", "JSON seeded incompressible 48 KiB fastest", .{
        .media = .json,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
    }),
    benchmark("html-realistic-16384-fastest", "HTML realistic 16 KiB fastest", .{
        .media = .html,
        .entropy = .realistic,
        .bytes = 16 * 1024,
    }),
    benchmark("json-realistic-16384-fastest", "JSON realistic 16 KiB fastest", .{
        .media = .json,
        .entropy = .realistic,
        .bytes = 16 * 1024,
    }),
    benchmark("html-utf8-16384-fastest", "HTML near-incompressible UTF-8 16 KiB", .{
        .media = .html,
        .entropy = .utf8_incompressible,
        .bytes = 16 * 1024,
    }),
    benchmark("json-utf8-16384-fastest", "JSON near-incompressible UTF-8 16 KiB", .{
        .media = .json,
        .entropy = .utf8_incompressible,
        .bytes = 16 * 1024,
    }),
    benchmark("html-comp-16384-default", "HTML compressible 16 KiB default", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .level = .default,
    }),
    benchmark("html-comp-16384-best", "HTML compressible 16 KiB best", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .level = .best,
    }),
    benchmark("json-comp-16384-default", "JSON compressible 16 KiB default", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .level = .default,
    }),
    benchmark("json-comp-16384-best", "JSON compressible 16 KiB best", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .level = .best,
    }),
    benchmark("html-seeded-49152-default", "HTML seeded incompressible 48 KiB default", .{
        .media = .html,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
        .level = .default,
    }),
    benchmark("html-seeded-49152-best", "HTML seeded incompressible 48 KiB best", .{
        .media = .html,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
        .level = .best,
    }),
    benchmark("json-seeded-49152-default", "JSON seeded incompressible 48 KiB default", .{
        .media = .json,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
        .level = .default,
    }),
    benchmark("json-seeded-49152-best", "JSON seeded incompressible 48 KiB best", .{
        .media = .json,
        .entropy = .seeded_incompressible,
        .bytes = 48 * 1024,
        .level = .best,
    }),
    benchmark("head-html-comp-16384", "HEAD HTML compressible 16 KiB", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .mode = .head,
    }),
    benchmark("identity-json-16384", "identity-negotiated JSON 16 KiB", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 16 * 1024,
        .mode = .identity,
    }),
    benchmark("threshold-html-1023", "below-threshold HTML 1,023 B", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 1023,
        .mode = .below_threshold,
    }),
    benchmark("capacity-fallback-html-4096", "capacity fallback HTML 4 KiB", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 4096,
        .mode = .capacity_fallback,
    }),
    benchmark("default-staging-html-49152", "default staging gzip HTML 48 KiB", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 48 * 1024,
        .mode = .default_staging_gzip,
    }),
    benchmark("bound-minus-one-fallback-html-49152", "one-byte-short fallback HTML 48 KiB", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 48 * 1024,
        .mode = .bound_minus_one_fallback,
    }),
    benchmark("post-compress-head-fallback-json-4096", "post-compress head fallback JSON 4 KiB", .{
        .media = .json,
        .entropy = .realistic,
        .bytes = 4096,
        .mode = .post_compress_head_fallback,
    }),
    benchmark("header-rich-identity-html-16384", "header-rich identity HTML 16 KiB", .{
        .media = .html,
        .entropy = .realistic,
        .bytes = 16 * 1024,
        .mode = .header_rich_identity,
    }),
    benchmark("no-transform-html-4096", "no-transform HTML 4 KiB", .{
        .media = .html,
        .entropy = .compressible,
        .bytes = 4096,
        .mode = .no_transform,
    }),
    benchmark("strong-etag-json-4096", "strong ETag JSON 4 KiB", .{
        .media = .json,
        .entropy = .compressible,
        .bytes = 4096,
        .mode = .strong_etag,
    }),
};

const benchmark_cases = blk: {
    var cases: [definitions.len]sigbench.BenchmarkCase = undefined;
    for (definitions, 0..) |definition, index| {
        cases[index] = sigbenchCase(definition);
    }
    break :blk cases;
};

pub const group = sigbench.groupWithId(
    "response-gzip-finite",
    "Production finite response gzip",
    benchmark_cases,
);
