const std = @import("std");
const sigbench = @import("sigbench");
const address = @import("../src/address.zig");
const application_body = @import("../src/internal/application/body.zig");
const application_context = @import("../src/application/context.zig");
const connection_admission = @import("../src/internal/runtime/connection/admission.zig");
const cors = @import("../src/cors.zig");
const forwarding = @import("../src/forwarding.zig");
const http1_limits = @import("../src/internal/http1/limits.zig");
const proxy_v2 = @import("../src/internal/proxy/protocol_v2.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const request_proxy_identity = @import("../src/internal/http1/request_proxy_identity.zig");
const request_trailers = @import("../src/internal/http1/request_trailers.zig");
const response_cors = @import("../src/internal/http1/response_cors_fields.zig");

const proxy_address = [12]u8{
    192,  0,    2,    9,
    198,  51,   100,  7,
    0x30, 0x39, 0x01, 0xbb,
};
const proxy_tlv = [7]u8{ 0x04, 0, 4, 1, 2, 3, 4 };
const proxy_payload_length: u8 = proxy_address.len + proxy_tlv.len;
const proxy_frame = proxy_v2.signature ++
    [4]u8{ 0x21, 0x11, 0, proxy_payload_length } ++ proxy_address ++ proxy_tlv;

const forwarded_wire =
    "GET /items HTTP/1.1\r\n" ++
    "Host: internal.test\r\n" ++
    "Forwarded: for=192.0.2.7, for=10.1.1.2;host=public.test;proto=https\r\n" ++
    "\r\n";
const x_forwarded_wire =
    "GET /items HTTP/1.1\r\n" ++
    "Host: internal.test\r\n" ++
    "X-Forwarded-For: 192.0.2.7, 10.1.1.2\r\n" ++
    "X-Forwarded-Host: public.test\r\n" ++
    "X-Forwarded-Proto: https\r\n" ++
    "\r\n";
const absolute_wire =
    "GET http://EXAMPLE.test:80/items HTTP/1.1\r\n" ++
    "Host: example.test\r\n\r\n";
const fixed_date = "Wed, 15 Jul 2026 12:00:00 GMT";

const HeadDecoder = request_head.Decoder(http1_limits.standard_request_head_limits);
const Profile = forwarding.Profile(forwarding.standard_limits);
const trailer_names_max = request_trailers.standard_names_max;

const ParsedHead = struct {
    decoder: HeadDecoder,
    head: request_head.Head,
};

const ForwardCase = enum {
    forwarded_trusted,
    forwarded_untrusted,
    x_forwarded_trusted,
    x_forwarded_untrusted,
};

const AdmissionApp = struct {
    pub const Plan = struct {
        input: application_context.Input,
        body: application_body.Plan,
    };

    pub fn plan(input: application_context.Input) Plan {
        if (input.forwarding == null) benchmarkFailure();
        return .{ .input = input, .body = application_body.none_plan };
    }
};

const actual_origin = "HTTPS://App.Example:443";
const trusted_peer = address.Endpoint.initIpv4(.{ 10, 9, 9, 9 }, 8443);
const untrusted_peer = address.Endpoint.initIpv4(.{ 192, 0, 2, 99 }, 8443);
const actual_policy = cors.exact(&.{"https://app.example"}, .{
    .credentials = true,
});
const preflight_headers = "authorization, x-trace";
const preflight_policy = cors.exact(&.{"https://app.example"}, .{
    .credentials = true,
    .request_headers = .{ .exact = &.{ "Authorization", "X-Trace" } },
    .max_age_seconds = 900,
});

const proxy_checksum: u64 = 0xe8b3dd1f1814d20a;
const forwarded_trusted_checksum: u64 = 0x7960e9ec545d1cbd;
const forwarded_untrusted_checksum: u64 = 0xfbba796ee257b035;
const x_forwarded_trusted_checksum: u64 = 0x37c9cafd463e7658;
const x_forwarded_untrusted_checksum: u64 = 0xfbba796ee257b035;
const absolute_checksum: u64 = 0x57aa6e8de0ba3a30;
const cors_actual_checksum: u64 = 0x50bebf18cfde588c;
const cors_preflight_checksum: u64 = 0x90549298dbb9f054;

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof proxy/CORS benchmark validity check failed");
}

fn ProxyRunner(comptime fragmented: bool) type {
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var runtime_frame: []const u8 = &proxy_frame;
            std.mem.doNotOptimizeAway(&runtime_frame);
            var last: proxy_v2.Value = .local;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = parseProxy(runtime_frame, fragmented);
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validateProxy(last);
            return elapsed_ns;
        }
    };
}

fn parseProxy(frame: []const u8, comptime fragmented: bool) proxy_v2.Value {
    var decoder = proxy_v2.Decoder.init();
    if (!fragmented) {
        const result = decoder.feed(frame);
        if (result.consumed != frame.len) benchmarkFailure();
        return completeProxy(result.state);
    }
    var last: proxy_v2.FeedState = .need_more;
    for (frame, 0..) |_, index| {
        const result = decoder.feed(frame[index .. index + 1]);
        if (result.consumed != 1) benchmarkFailure();
        if (index + 1 != frame.len and result.state != .need_more) benchmarkFailure();
        last = result.state;
    }
    return completeProxy(last);
}

fn completeProxy(state: proxy_v2.FeedState) proxy_v2.Value {
    return switch (state) {
        .complete => |value| value,
        .need_more, .invalid => benchmarkFailure(),
    };
}

fn validateProxy(value: proxy_v2.Value) void {
    const proxied = switch (value) {
        .proxy => |result| result,
        .local => benchmarkFailure(),
    };
    if (!proxied.source.eql(address.Endpoint.initIpv4(.{ 192, 0, 2, 9 }, 12_345))) {
        benchmarkFailure();
    }
    if (!proxied.destination.eql(address.Endpoint.initIpv4(.{ 198, 51, 100, 7 }, 443))) {
        benchmarkFailure();
    }
    expectChecksum(fingerprintProxy(value), proxy_checksum);
}

fn ForwardRunner(comptime case: ForwardCase) type {
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var parsed = parseHead(forwardWire(case));
            var profile = Profile.init(.{
                .family = forwardFamily(case),
                .trusted = &.{"10.0.0.0/8"},
            }) catch benchmarkFailure();
            const peer = forwardPeer(case);
            const input = request_proxy_identity.Input{
                .bytes = parsed.decoder.bytes(),
                .fields = parsed.decoder.fields(),
                .transport_peer = peer,
                .connection_peer = peer,
            };
            std.mem.doNotOptimizeAway(&profile);
            std.mem.doNotOptimizeAway(&input);
            var last: request_proxy_identity.Result = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = request_proxy_identity.resolve(
                    forwarding.standard_limits,
                    &profile,
                    input,
                );
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validateForward(case, last);
            return elapsed_ns;
        }
    };
}

fn parseHead(wire: []const u8) ParsedHead {
    var decoder = HeadDecoder.init();
    const result = decoder.feed(wire);
    const head = switch (result.state) {
        .ready => |value| value,
        .need_more, .rejected => benchmarkFailure(),
    };
    if (result.consumed != wire.len) benchmarkFailure();
    return .{ .decoder = decoder, .head = head };
}

fn forwardWire(comptime case: ForwardCase) []const u8 {
    return switch (case) {
        .forwarded_trusted, .forwarded_untrusted => forwarded_wire,
        .x_forwarded_trusted, .x_forwarded_untrusted => x_forwarded_wire,
    };
}

fn forwardFamily(comptime case: ForwardCase) forwarding.HeaderFamily {
    return switch (case) {
        .forwarded_trusted, .forwarded_untrusted => .forwarded,
        .x_forwarded_trusted, .x_forwarded_untrusted => .x_forwarded,
    };
}

fn forwardPeer(comptime case: ForwardCase) address.Endpoint {
    return switch (case) {
        .forwarded_trusted, .x_forwarded_trusted => trusted_peer,
        .forwarded_untrusted, .x_forwarded_untrusted => untrusted_peer,
    };
}

fn validateForward(case: ForwardCase, result: request_proxy_identity.Result) void {
    const metadata = switch (result) {
        .accepted => |value| value,
        .rejected => benchmarkFailure(),
    };
    const trusted = case == .forwarded_trusted or case == .x_forwarded_trusted;
    const expected_client = if (trusted)
        address.Endpoint.initIpv4(.{ 192, 0, 2, 7 }, 0)
    else
        address.Endpoint.initIpv4(.{ 192, 0, 2, 99 }, 8443);
    if (!metadata.client.eql(expected_client)) benchmarkFailure();
    if (metadata.trusted_hops != @as(u16, if (trusted) 2 else 0)) benchmarkFailure();
    const expected_disposition: forwarding.HeaderDisposition = if (trusted)
        .applied
    else
        .ignored_untrusted;
    if (metadata.forwarding_headers != expected_disposition) benchmarkFailure();
    expectChecksum(fingerprintMetadata(metadata), forwardChecksum(case));
}

fn forwardChecksum(case: ForwardCase) u64 {
    return switch (case) {
        .forwarded_trusted => forwarded_trusted_checksum,
        .forwarded_untrusted => forwarded_untrusted_checksum,
        .x_forwarded_trusted => x_forwarded_trusted_checksum,
        .x_forwarded_untrusted => x_forwarded_untrusted_checksum,
    };
}

fn AbsoluteRunner() type {
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var parsed = parseHead(absolute_wire);
            var profile = Profile.init(.{}) catch benchmarkFailure();
            var decoded_path: [
                http1_limits.standard_request_head_limits.request_line_bytes_max
            ]u8 = undefined;
            const identity = connection_admission.ConnectionIdentity{
                .transport_peer = address.Endpoint.initIpv4(.{ 192, 0, 2, 44 }, 8443),
                .connection_peer = address.Endpoint.initIpv4(.{ 192, 0, 2, 44 }, 8443),
            };
            std.mem.doNotOptimizeAway(&profile);
            var last: connection_admission.Result(AdmissionApp, trailer_names_max) = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = connection_admission.analyzeForwarded(
                    AdmissionApp,
                    trailer_names_max,
                    forwarding.standard_limits,
                    &profile,
                    identity,
                    .{},
                    &parsed.decoder,
                    parsed.head,
                    &decoded_path,
                    fixed_date,
                ) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validateAbsolute(last);
            return elapsed_ns;
        }
    };
}

fn validateAbsolute(result: connection_admission.Result(AdmissionApp, trailer_names_max)) void {
    const gate = switch (result) {
        .admitted => |value| value,
        .rejected, .silent_close => benchmarkFailure(),
    };
    if (gate.request.analysis.target != .absolute) benchmarkFailure();
    const metadata = gate.plan.input.forwarding orelse benchmarkFailure();
    if (metadata.scheme != .http or metadata.authority.port != 80) benchmarkFailure();
    expectChecksum(fingerprintMetadata(metadata), absolute_checksum);
}

fn CorsRunner(comptime preflight: bool) type {
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var origin: []const u8 = actual_origin;
            var headers: []const u8 = preflight_headers;
            std.mem.doNotOptimizeAway(&origin);
            std.mem.doNotOptimizeAway(&headers);
            if (preflight) return runPreflight(iterations, origin, headers);
            return runActual(iterations, origin);
        }
    };
}

fn runActual(iterations: u64, origin: []const u8) u64 {
    var last: response_cors.Fields = undefined;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        last = response_cors.actual(actual_policy, .{ .value = origin });
        std.mem.doNotOptimizeAway(&last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (last.count != 3 or !last.managed) benchmarkFailure();
    expectChecksum(fingerprintCors(last), cors_actual_checksum);
    return elapsed_ns;
}

fn runPreflight(iterations: u64, origin: []const u8, headers: []const u8) u64 {
    var last: response_cors.PreflightDecision = undefined;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        last = response_cors.preflight(preflight_policy, .{
            .origin = .{ .value = origin },
            .requested_method = .{ .value = "PATCH" },
            .requested_headers = .{ .value = headers },
            .route_selected = true,
        });
        std.mem.doNotOptimizeAway(&last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (last.status != .no_content or last.fields.count != 6) benchmarkFailure();
    var fingerprint = Fingerprint{};
    fingerprint.addU16(@intFromEnum(last.status));
    addCorsFields(&fingerprint, last.fields);
    expectChecksum(fingerprint.value, cors_preflight_checksum);
    return elapsed_ns;
}

const Fingerprint = struct {
    value: u64 = 0xcbf29ce484222325,

    fn addByte(self: *Fingerprint, byte: u8) void {
        self.value = (self.value ^ byte) *% 0x100000001b3;
    }

    fn addBytes(self: *Fingerprint, bytes: []const u8) void {
        for (bytes) |byte| self.addByte(byte);
    }

    fn addSlice(self: *Fingerprint, bytes: []const u8) void {
        self.addU16(@intCast(bytes.len));
        self.addBytes(bytes);
    }

    fn addU16(self: *Fingerprint, value: u16) void {
        self.addByte(@truncate(value));
        self.addByte(@truncate(value >> 8));
    }

    fn addU32(self: *Fingerprint, value: u32) void {
        self.addU16(@truncate(value));
        self.addU16(@truncate(value >> 16));
    }
};

fn addAddress(fingerprint: *Fingerprint, value: address.Address) void {
    switch (value) {
        .ipv4 => |bytes| {
            fingerprint.addByte(4);
            fingerprint.addBytes(&bytes);
        },
        .ipv6 => |bytes| {
            fingerprint.addByte(6);
            fingerprint.addBytes(&bytes);
        },
    }
}

fn addEndpoint(fingerprint: *Fingerprint, value: address.Endpoint) void {
    addAddress(fingerprint, value.address);
    fingerprint.addU16(value.port);
}

fn addHost(fingerprint: *Fingerprint, value: forwarding.Authority) void {
    switch (value.host) {
        .reg_name => |text| {
            fingerprint.addByte(0);
            fingerprint.addByte(@intFromBool(text.quoted));
            fingerprint.addSlice(text.bytes);
        },
        .ip => |ip| {
            fingerprint.addByte(1);
            addAddress(fingerprint, ip);
        },
        .ipv_future => |text| {
            fingerprint.addByte(2);
            fingerprint.addByte(@intFromBool(text.quoted));
            fingerprint.addSlice(text.bytes);
        },
    }
    fingerprint.addU16(value.port);
}

fn fingerprintProxy(value: proxy_v2.Value) u64 {
    var fingerprint = Fingerprint{};
    switch (value) {
        .local => fingerprint.addByte(0),
        .proxy => |proxied| {
            fingerprint.addByte(1);
            addEndpoint(&fingerprint, proxied.source);
            addEndpoint(&fingerprint, proxied.destination);
        },
    }
    return fingerprint.value;
}

fn fingerprintMetadata(value: forwarding.Metadata) u64 {
    var fingerprint = Fingerprint{};
    addEndpoint(&fingerprint, value.transport_peer);
    addEndpoint(&fingerprint, value.connection_peer);
    addEndpoint(&fingerprint, value.client);
    addHost(&fingerprint, value.authority);
    inline for (.{
        value.scheme,
        value.connection_source,
        value.client_provenance,
        value.host_provenance,
        value.scheme_provenance,
        value.forwarding_headers,
    }) |tag| fingerprint.addByte(@intFromEnum(tag));
    fingerprint.addU16(value.trusted_hops);
    return fingerprint.value;
}

fn fingerprintCors(fields: response_cors.Fields) u64 {
    var fingerprint = Fingerprint{};
    addCorsFields(&fingerprint, fields);
    return fingerprint.value;
}

fn addCorsFields(fingerprint: *Fingerprint, fields: response_cors.Fields) void {
    fingerprint.addByte(@intFromBool(fields.managed));
    fingerprint.addByte(fields.count);
    for (0..fields.count) |index| {
        const field = fields.at(index);
        fingerprint.addSlice(field.name);
        switch (field.value) {
            .bytes => |bytes| {
                fingerprint.addByte(0);
                fingerprint.addSlice(bytes);
            },
            .max_age_seconds => |seconds| {
                fingerprint.addByte(1);
                fingerprint.addU32(seconds);
            },
        }
    }
}

fn expectChecksum(actual: u64, expected: u64) void {
    std.mem.doNotOptimizeAway(actual);
    if (actual != expected) benchmarkFailure();
}

const ProxyContiguous = ProxyRunner(false);
const ProxyFragmented = ProxyRunner(true);
const ForwardedTrusted = ForwardRunner(.forwarded_trusted);
const ForwardedUntrusted = ForwardRunner(.forwarded_untrusted);
const XForwardedTrusted = ForwardRunner(.x_forwarded_trusted);
const XForwardedUntrusted = ForwardRunner(.x_forwarded_untrusted);
const AbsoluteAdmission = AbsoluteRunner();
const CorsActual = CorsRunner(false);
const CorsPreflight = CorsRunner(true);

pub const group = sigbench.groupWithId("m7-proxy-cors", "M7 proxy identity and CORS", .{
    sigbench.benchWithThroughput(
        "proxy-v2-contiguous",
        "contiguous PROXY v2 TCP4 frame with opaque TLV",
        .{ .bytes = proxy_frame.len },
        ProxyContiguous.bench,
    ),
    sigbench.benchWithThroughput(
        "proxy-v2-byte-fragmented",
        "byte-fragmented PROXY v2 TCP4 frame with opaque TLV",
        .{ .bytes = proxy_frame.len },
        ProxyFragmented.bench,
    ),
    sigbench.benchWithThroughput(
        "forwarded-trusted",
        "trusted Forwarded effective identity resolution",
        .{ .bytes = forwarded_wire.len },
        ForwardedTrusted.bench,
    ),
    sigbench.benchWithThroughput(
        "forwarded-untrusted",
        "untrusted Forwarded bypass and direct identity resolution",
        .{ .bytes = forwarded_wire.len },
        ForwardedUntrusted.bench,
    ),
    sigbench.benchWithThroughput(
        "x-forwarded-trusted",
        "trusted X-Forwarded effective identity resolution",
        .{ .bytes = x_forwarded_wire.len },
        XForwardedTrusted.bench,
    ),
    sigbench.benchWithThroughput(
        "x-forwarded-untrusted",
        "untrusted X-Forwarded bypass and direct identity resolution",
        .{ .bytes = x_forwarded_wire.len },
        XForwardedUntrusted.bench,
    ),
    sigbench.benchWithThroughput(
        "absolute-effective-origin",
        "absolute-form full effective-origin admission",
        .{ .bytes = absolute_wire.len },
        AbsoluteAdmission.bench,
    ),
    sigbench.benchWithThroughput(
        "cors-actual-exact",
        "exact credentialed CORS actual-request decision",
        .{ .bytes = actual_origin.len },
        CorsActual.bench,
    ),
    sigbench.benchWithThroughput(
        "cors-preflight-exact",
        "exact credentialed CORS preflight decision",
        .{ .bytes = actual_origin.len + "PATCH".len + preflight_headers.len },
        CorsPreflight.bench,
    ),
});
