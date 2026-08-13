const std = @import("std");
const sigbench = @import("sigbench");
const address = @import("../src/address.zig");
const forwarding = @import("../src/forwarding.zig");
const proxy_v2 = @import("../src/internal/proxy/protocol_v2.zig");
const http1_limits = @import("../src/internal/http1/limits.zig");
const request_head = @import("../src/internal/http1/request_head.zig");
const request_proxy_identity = @import("../src/internal/http1/request_proxy_identity.zig");
const reactor = @import("../src/internal/runtime/reactor.zig");
const worker = @import("../src/internal/runtime/worker.zig");
const worker_loop = @import("../src/internal/runtime/worker/loop.zig");

const proxy_address = [12]u8{
    192,  0,    2,    9,
    198,  51,   100,  7,
    0x30, 0x39, 0x01, 0xbb,
};
const short_proxy_frame = proxy_v2.signature ++
    [4]u8{ 0x21, 0x11, 0, proxy_address.len } ++ proxy_address;
const proxy_payload_hard_max = std.math.maxInt(u16);
const max_proxy_frame_bytes = proxy_v2.signature.len + 4 + proxy_payload_hard_max;
const forwarding_value = "for=192.0.2.7;host=public.test;proto=https";
const trusted_peer = address.Endpoint.initIpv4(.{ 10, 9, 9, 9 }, 8443);

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof proxy/runtime benchmark validity check failed");
}

const SignatureCorpus = struct {
    valid: [short_proxy_frame.len]u8,
    mismatch_first: [short_proxy_frame.len]u8,
    mismatch_middle: [short_proxy_frame.len]u8,
    mismatch_last: [short_proxy_frame.len]u8,
    lengths: [proxy_v2.signature.len + 1]u8,

    fn init() SignatureCorpus {
        var corpus = SignatureCorpus{
            .valid = short_proxy_frame,
            .mismatch_first = short_proxy_frame,
            .mismatch_middle = short_proxy_frame,
            .mismatch_last = short_proxy_frame,
            .lengths = undefined,
        };
        corpus.mismatch_first[0] ^= 1;
        corpus.mismatch_middle[proxy_v2.signature.len / 2] ^= 1;
        corpus.mismatch_last[proxy_v2.signature.len - 1] ^= 1;
        for (&corpus.lengths, 0..) |*length, index| length.* = @intCast(index);
        return corpus;
    }
};

fn signatureFeed(comptime vectorized: bool, input: []const u8) proxy_v2.FeedResult {
    var decoder = proxy_v2.Decoder.init();
    return if (vectorized)
        decoder.feed(input)
    else
        decoder.feedScalarBenchmark(input);
}

fn signatureBoundaryBatch(comptime vectorized: bool, corpus: *const SignatureCorpus) u64 {
    var fingerprint: u64 = 0;
    for (corpus.lengths) |length| {
        fingerprint +%= feedResultCode(signatureFeed(vectorized, corpus.valid[0..length]));
    }
    inline for (.{ "mismatch_first", "mismatch_middle", "mismatch_last" }) |name| {
        fingerprint +%= feedResultCode(signatureFeed(vectorized, &@field(corpus, name)));
    }
    return fingerprint;
}

fn feedResultCode(result: proxy_v2.FeedResult) u64 {
    var code: u64 = result.consumed;
    switch (result.state) {
        .need_more => code |= @as(u64, 1) << 32,
        .invalid => |reason| {
            code |= @as(u64, 2) << 32;
            code |= @as(u64, @intFromEnum(reason)) << 40;
        },
        .complete => |value| {
            code |= @as(u64, 3) << 32;
            code |= @as(u64, @intFromEnum(std.meta.activeTag(value))) << 40;
        },
    }
    return code;
}

fn validateSignatureDifferential(corpus: *const SignatureCorpus) void {
    for (corpus.lengths) |length| {
        compareSignatureInput(corpus.valid[0..length]);
    }
    inline for (.{ "mismatch_first", "mismatch_middle", "mismatch_last" }) |name| {
        compareSignatureInput(&@field(corpus, name));
    }
    compareSignatureInput(&corpus.valid);
    validateSignatureSemantics(corpus);
}

fn compareSignatureInput(input: []const u8) void {
    const scalar = signatureFeed(false, input);
    const vectorized = signatureFeed(true, input);
    if (!std.meta.eql(scalar, vectorized)) benchmarkFailure();
}

fn validateSignatureSemantics(corpus: *const SignatureCorpus) void {
    for (corpus.lengths) |length| {
        const result = signatureFeed(false, corpus.valid[0..length]);
        if (result.state != .need_more or result.consumed != length) benchmarkFailure();
    }
    inline for (.{
        .{ "mismatch_first", 1 },
        .{ "mismatch_middle", proxy_v2.signature.len / 2 + 1 },
        .{ "mismatch_last", proxy_v2.signature.len },
    }) |expected| {
        const result = signatureFeed(false, &@field(corpus, expected[0]));
        if (result.consumed != expected[1]) benchmarkFailure();
        switch (result.state) {
            .invalid => |reason| if (reason != .signature) benchmarkFailure(),
            .need_more, .complete => benchmarkFailure(),
        }
    }
}

fn SignatureCommonRunner(comptime vectorized: bool) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var corpus = SignatureCorpus.init();
            validateSignatureDifferential(&corpus);
            std.mem.doNotOptimizeAway(&corpus);
            const expected = feedResultCode(signatureFeed(false, &corpus.valid));
            var fingerprint: u64 = 0;
            var last: proxy_v2.FeedResult = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = signatureFeed(vectorized, &corpus.valid);
                std.mem.doNotOptimizeAway(&last);
                fingerprint +%= feedResultCode(last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (fingerprint != expected *% iterations) benchmarkFailure();
            validateProxyFeed(last);
            return elapsed_ns;
        }
    };
}

fn SignatureBoundaryRunner(comptime vectorized: bool) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var corpus = SignatureCorpus.init();
            validateSignatureDifferential(&corpus);
            std.mem.doNotOptimizeAway(&corpus);
            const expected = signatureBoundaryBatch(false, &corpus);
            var fingerprint: u64 = 0;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                const batch = signatureBoundaryBatch(vectorized, &corpus);
                std.mem.doNotOptimizeAway(&batch);
                fingerprint +%= batch;
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (fingerprint != expected *% iterations) benchmarkFailure();
            std.mem.doNotOptimizeAway(&fingerprint);
            return elapsed_ns;
        }
    };
}

fn ProxyRunner(comptime maximum: bool) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var maximum_frame: [max_proxy_frame_bytes]u8 = undefined;
            const frame: []const u8 = if (maximum)
                initMaximumProxyFrame(&maximum_frame)
            else
                &short_proxy_frame;
            std.mem.doNotOptimizeAway(&frame);
            var last: proxy_v2.Value = .local;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = parseProxy(frame);
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            validateProxy(last);
            return elapsed_ns;
        }
    };
}

fn initMaximumProxyFrame(frame: *[max_proxy_frame_bytes]u8) []const u8 {
    @memset(frame, 0xa5);
    @memcpy(frame[0..proxy_v2.signature.len], &proxy_v2.signature);
    frame[12] = 0x21;
    frame[13] = 0x11;
    frame[14] = 0xff;
    frame[15] = 0xff;
    @memcpy(frame[16 .. 16 + proxy_address.len], &proxy_address);
    return frame;
}

fn parseProxy(frame: []const u8) proxy_v2.Value {
    var decoder = proxy_v2.Decoder.init();
    const result = decoder.feed(frame);
    if (result.consumed != frame.len) benchmarkFailure();
    return switch (result.state) {
        .complete => |value| value,
        .need_more, .invalid => benchmarkFailure(),
    };
}

fn validateProxy(value: proxy_v2.Value) void {
    const proxied = switch (value) {
        .proxy => |result| result,
        .local => benchmarkFailure(),
    };
    const source = address.Endpoint.initIpv4(.{ 192, 0, 2, 9 }, 12_345);
    const destination = address.Endpoint.initIpv4(.{ 198, 51, 100, 7 }, 443);
    if (!proxied.source.eql(source) or !proxied.destination.eql(destination)) {
        benchmarkFailure();
    }
}

fn validateProxyFeed(result: proxy_v2.FeedResult) void {
    if (result.consumed != short_proxy_frame.len) benchmarkFailure();
    const value = switch (result.state) {
        .complete => |complete| complete,
        .need_more, .invalid => benchmarkFailure(),
    };
    validateProxy(value);
}

fn ForwardFixture(comptime field_count: usize) type {
    if (field_count == 0 or field_count > http1_limits.fields_hard_max) {
        @compileError("forwarding benchmark field count is outside HTTP limits");
    }
    return struct {
        const Self = @This();
        const bytes_capacity = field_count * 8 + forwarding_value.len + 16;

        bytes: [bytes_capacity]u8 = undefined,
        fields: [field_count]request_head.Field = undefined,
        used: usize = 0,

        fn init() Self {
            var fixture = Self{};
            for (fixture.fields[0 .. field_count - 1]) |*field| {
                field.* = fixture.addField("x-f", "y");
            }
            fixture.fields[field_count - 1] =
                fixture.addField("forwarded", forwarding_value);
            return fixture;
        }

        fn addField(self: *Self, name: []const u8, value: []const u8) request_head.Field {
            const name_span = self.appendBytes(name);
            const value_span = self.appendBytes(value);
            return .{
                .name = name_span,
                .raw_value = value_span,
                .value = value_span,
            };
        }

        fn appendBytes(self: *Self, value: []const u8) request_head.Span {
            if (value.len > self.bytes.len - self.used) benchmarkFailure();
            const offset = self.used;
            @memcpy(self.bytes[offset..][0..value.len], value);
            self.used += value.len;
            return .{ .offset = @intCast(offset), .length = @intCast(value.len) };
        }
    };
}

fn ForwardRunner(comptime field_count: usize) type {
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var fixture = ForwardFixture(field_count).init();
            var profile = forwarding.Profile(forwarding.standard_limits).init(.{
                .family = .forwarded,
                .trusted = &.{"10.0.0.0/8"},
            }) catch benchmarkFailure();
            const input = request_proxy_identity.Input{
                .bytes = fixture.bytes[0..fixture.used],
                .fields = &fixture.fields,
                .transport_peer = trusted_peer,
                .connection_peer = trusted_peer,
            };
            std.mem.doNotOptimizeAway(&fixture);
            std.mem.doNotOptimizeAway(&profile);
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
            validateForward(field_count, last);
            return elapsed_ns;
        }
    };
}

fn validateForward(field_count: usize, result: request_proxy_identity.Result) void {
    const metadata = switch (result) {
        .accepted => |value| value,
        .rejected => benchmarkFailure(),
    };
    const client = address.Endpoint.initIpv4(.{ 192, 0, 2, 7 }, 0);
    if (!metadata.client.eql(client) or metadata.trusted_hops != 1) benchmarkFailure();
    if (metadata.forwarding_headers != .applied or metadata.scheme != .https) {
        benchmarkFailure();
    }
    if (metadata.host_provenance != .forwarded or metadata.authority.port != 443) {
        benchmarkFailure();
    }
    const host = switch (metadata.authority.host) {
        .reg_name => |text| text.bytes,
        .ip, .ipv_future => benchmarkFailure(),
    };
    if (!std.mem.eql(u8, host, "public.test")) benchmarkFailure();
    std.mem.doNotOptimizeAway(&field_count);
}

fn FakeWorker(comptime connection_slots: usize) type {
    return struct {
        slot_state: [connection_slots]u8 = @splat(0),
        loop_status_calls: u64 = 0,
        cleanup_status_calls: u64 = 0,
        handle_calls: u64 = 0,

        pub noinline fn loopStatus(self: *@This()) worker.LoopStatus {
            self.loop_status_calls += 1;
            return .{ .phase = .running, .flush_pending = false };
        }

        pub fn cleanupStatus(self: *@This()) worker.LoopStatus {
            self.cleanup_status_calls += 1;
            return .{ .phase = .running, .flush_pending = false };
        }

        pub fn retryFlush(self: *@This()) error{RetryFailed}!worker.Step {
            _ = self;
            return .progressed;
        }

        pub noinline fn handle(
            self: *@This(),
            _: reactor.Completion,
            _: worker.ClockSample,
        ) error{HandleFailed}!worker.Step {
            self.handle_calls += 1;
            return .progressed;
        }

        pub fn failBackend(self: *@This()) error{BackendFailure} {
            _ = self;
            return error.BackendFailure;
        }

        pub fn failClock(self: *@This(), _: reactor.Completion) error{InvalidClock} {
            _ = self;
            return error.InvalidClock;
        }
    };
}

const FakeBackend = struct {
    completion: reactor.Completion,
    wait_calls: u64 = 0,

    pub noinline fn wait(
        self: *FakeBackend,
    ) error{ WaitInterrupted, WaitRetry, WaitFailed }!reactor.Completion {
        self.wait_calls += 1;
        return self.completion;
    }
};

const FakeClock = struct {
    sample_calls: u64 = 0,

    pub noinline fn sample(self: *FakeClock) error{ClockFailed}!worker.ClockSample {
        self.sample_calls += 1;
        return .{ .monotonic_ns = 7, .epoch_second = 1_784_030_400 };
    }
};

fn WorkerLoopRunner(comptime connection_slots: usize) type {
    const FakeWorkerType = FakeWorker(connection_slots);
    const RuntimeLoop = worker_loop.Loop(FakeWorkerType, FakeBackend, FakeClock);
    if (@sizeOf(FakeWorkerType) < connection_slots) @compileError("slot state was elided");
    return struct {
        fn bench(bencher: *sigbench.Bencher) void {
            bencher.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var fake_worker = FakeWorkerType{};
            var backend = FakeBackend{ .completion = sendCompletion() };
            var clock = FakeClock{};
            var loop = RuntimeLoop.init(&fake_worker, &backend, &clock);
            std.mem.doNotOptimizeAway(&fake_worker.slot_state);
            var last: worker_loop.Outcome = .stopped;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = loop.step() catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (last != .progressed or fake_worker.cleanup_status_calls != 0) {
                benchmarkFailure();
            }
            if (fake_worker.loop_status_calls != iterations or
                fake_worker.handle_calls != iterations or
                backend.wait_calls != iterations or clock.sample_calls != iterations)
            {
                benchmarkFailure();
            }
            return elapsed_ns;
        }
    };
}

fn sendCompletion() reactor.Completion {
    const token = reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = 1,
        .slot_generation = 1,
        .sequence = 1,
    }) catch benchmarkFailure();
    return .{
        .token = token,
        .result = .{ .success = .{ .send = 1 } },
        .more = false,
    };
}

const SignatureCommonScalar = SignatureCommonRunner(false);
const SignatureCommonSimd = SignatureCommonRunner(true);
const SignatureBoundariesScalar = SignatureBoundaryRunner(false);
const SignatureBoundariesSimd = SignatureBoundaryRunner(true);
const ProxyShort = ProxyRunner(false);
const ProxyMaximum = ProxyRunner(true);
const ForwardFields1 = ForwardRunner(1);
const ForwardFields128 = ForwardRunner(128);
const ForwardFields1024 = ForwardRunner(http1_limits.fields_hard_max);
const WorkerSlots1 = WorkerLoopRunner(1);
const WorkerSlots128 = WorkerLoopRunner(128);
const WorkerSlots8192 = WorkerLoopRunner(8192);

pub const group = sigbench.groupWithId(
    "m7-proxy-runtime",
    "M7 proxy and worker runtime scaling",
    .{
        sigbench.benchWithId(
            "proxy-signature-common-scalar",
            "PROXY common full feed with scalar signature",
            SignatureCommonScalar.bench,
        ),
        sigbench.benchWithId(
            "proxy-signature-common-simd",
            "PROXY common full feed with SIMD signature",
            SignatureCommonSimd.bench,
        ),
        sigbench.benchWithId(
            "proxy-signature-boundaries-scalar",
            "PROXY short and mismatch feeds with scalar signature",
            SignatureBoundariesScalar.bench,
        ),
        sigbench.benchWithId(
            "proxy-signature-boundaries-simd",
            "PROXY short and mismatch feeds with SIMD fallback",
            SignatureBoundariesSimd.bench,
        ),
        sigbench.benchWithThroughput(
            "proxy-v2-common-short",
            "PROXY v2 common short frame",
            .{ .bytes = short_proxy_frame.len },
            ProxyShort.bench,
        ),
        sigbench.benchWithThroughput(
            "proxy-v2-max-opaque",
            "PROXY v2 maximum 65,535-byte opaque payload",
            .{ .bytes = proxy_payload_hard_max },
            ProxyMaximum.bench,
        ),
        sigbench.benchWithId(
            "forwarding-fields-1",
            "forwarding across 1 field",
            ForwardFields1.bench,
        ),
        sigbench.benchWithId(
            "forwarding-fields-128",
            "forwarding across default 128 fields",
            ForwardFields128.bench,
        ),
        sigbench.benchWithId(
            "forwarding-fields-1024",
            "forwarding across hard maximum 1,024 fields",
            ForwardFields1024.bench,
        ),
        sigbench.benchWithId(
            "worker-loop-dispatch-1",
            "Loop.step dispatch with 1-slot worker shape",
            WorkerSlots1.bench,
        ),
        sigbench.benchWithId(
            "worker-loop-dispatch-128",
            "Loop.step dispatch with 128-slot worker shape",
            WorkerSlots128.bench,
        ),
        sigbench.benchWithId(
            "worker-loop-dispatch-8192",
            "Loop.step dispatch with 8,192-slot worker shape",
            WorkerSlots8192.bench,
        ),
    },
);

test "M7 proxy/runtime benchmark registry compiles" {
    _ = group;
}
