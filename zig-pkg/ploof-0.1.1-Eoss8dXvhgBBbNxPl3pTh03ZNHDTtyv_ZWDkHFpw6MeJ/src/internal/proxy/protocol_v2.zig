const std = @import("std");

const address = @import("../../address.zig");

pub const signature = [12]u8{
    0x0d, 0x0a, 0x0d, 0x0a, 0x00, 0x0d, 0x0a, 0x51, 0x55, 0x49, 0x54, 0x0a,
};

pub const InvalidReason = enum(u8) {
    signature,
    version,
    command,
    family_protocol,
    address_length,
};

pub const Proxied = struct {
    source: address.Endpoint,
    destination: address.Endpoint,
};

pub const Value = union(enum) {
    local,
    proxy: Proxied,
};

pub const FeedState = union(enum) {
    need_more,
    complete: Value,
    invalid: InvalidReason,
};

pub const FeedResult = struct {
    consumed: usize,
    state: FeedState,
};

const Command = enum(u8) { local, proxy };
const Phase = enum(u8) {
    signature,
    version_command,
    family_protocol,
    length_high,
    length_low,
    payload,
    complete,
    invalid,
};

pub const Decoder = struct {
    phase: Phase = .signature,
    signature_used: u8 = 0,
    command: Command = .local,
    family_protocol: u8 = 0,
    declared_length: u16 = 0,
    payload_used: u16 = 0,
    address_length: u8 = 0,
    source_bytes: [16]u8 = @splat(0),
    destination_bytes: [16]u8 = @splat(0),
    source_port: u16 = 0,
    destination_port: u16 = 0,
    invalid_reason: InvalidReason = .signature,

    pub fn init() Decoder {
        return .{};
    }

    pub fn feed(self: *Decoder, input: []const u8) FeedResult {
        return self.feedConfigured(input, true);
    }

    /// Benchmark-only scalar baseline using the production byte-consumption path.
    pub fn feedScalarBenchmark(self: *Decoder, input: []const u8) FeedResult {
        return self.feedConfigured(input, false);
    }

    fn feedConfigured(
        self: *Decoder,
        input: []const u8,
        comptime vectorized_signature: bool,
    ) FeedResult {
        if (self.terminalState()) |state| return .{ .consumed = 0, .state = state };
        var index: usize = if (vectorized_signature) self.consumeWholeSignature(input) else 0;
        while (index < input.len) {
            const skipped = self.consumeOpaquePayload(input.len - index);
            if (skipped != 0) {
                index += skipped;
                if (self.payload_used == self.declared_length) {
                    return .{ .consumed = index, .state = self.finish() };
                }
                continue;
            }
            if (self.consumeByte(input[index])) |terminal| {
                return .{ .consumed = index + 1, .state = terminal };
            }
            index += 1;
        }
        return .{ .consumed = input.len, .state = .need_more };
    }

    fn consumeOpaquePayload(self: *Decoder, available: usize) usize {
        if (self.phase != .payload) return 0;
        if (self.command == .proxy and self.payload_used < self.address_length) return 0;
        std.debug.assert(self.payload_used < self.declared_length);
        const remaining = self.declared_length - self.payload_used;
        const consumed: u16 = @intCast(@min(available, remaining));
        self.payload_used += consumed;
        return consumed;
    }

    fn consumeWholeSignature(self: *Decoder, input: []const u8) usize {
        if (self.phase != .signature or self.signature_used != 0 or input.len < signature.len) {
            return 0;
        }
        const actual: @Vector(signature.len, u8) = input[0..signature.len].*;
        const expected: @Vector(signature.len, u8) = signature;
        if (!@reduce(.And, actual == expected)) return 0;
        self.signature_used = signature.len;
        self.phase = .version_command;
        return signature.len;
    }

    fn consumeByte(self: *Decoder, byte: u8) ?FeedState {
        return switch (self.phase) {
            .signature => self.consumeSignature(byte),
            .version_command => self.consumeVersionCommand(byte),
            .family_protocol => self.consumeFamilyProtocol(byte),
            .length_high => {
                self.declared_length = @as(u16, byte) << 8;
                self.phase = .length_low;
                return null;
            },
            .length_low => self.consumeLengthLow(byte),
            .payload => self.consumePayload(byte),
            .complete, .invalid => unreachable,
        };
    }

    fn consumeSignature(self: *Decoder, byte: u8) ?FeedState {
        if (byte != signature[self.signature_used]) return self.reject(.signature);
        self.signature_used += 1;
        if (self.signature_used == signature.len) self.phase = .version_command;
        return null;
    }

    fn consumeVersionCommand(self: *Decoder, byte: u8) ?FeedState {
        if (byte >> 4 != 2) return self.reject(.version);
        self.command = switch (byte & 0x0f) {
            0 => .local,
            1 => .proxy,
            else => return self.reject(.command),
        };
        self.phase = .family_protocol;
        return null;
    }

    fn consumeFamilyProtocol(self: *Decoder, byte: u8) ?FeedState {
        self.family_protocol = byte;
        if (self.command == .proxy) {
            self.address_length = switch (byte) {
                0x11 => 12,
                0x21 => 36,
                else => return self.reject(.family_protocol),
            };
        }
        self.phase = .length_high;
        return null;
    }

    fn consumeLengthLow(self: *Decoder, byte: u8) ?FeedState {
        self.declared_length |= byte;
        if (self.command == .proxy and self.declared_length < self.address_length) {
            return self.reject(.address_length);
        }
        if (self.declared_length == 0) return self.finish();
        self.phase = .payload;
        return null;
    }

    fn consumePayload(self: *Decoder, byte: u8) ?FeedState {
        if (self.command == .proxy and self.payload_used < self.address_length) {
            self.captureAddressByte(self.payload_used, byte);
        }
        self.payload_used += 1;
        if (self.payload_used == self.declared_length) return self.finish();
        return null;
    }

    fn captureAddressByte(self: *Decoder, index: u16, byte: u8) void {
        const width: u16 = if (self.family_protocol == 0x11) 4 else 16;
        if (index < width) {
            self.source_bytes[index] = byte;
        } else if (index < width * 2) {
            self.destination_bytes[index - width] = byte;
        } else if (index < width * 2 + 2) {
            self.source_port = (self.source_port << 8) | byte;
        } else {
            self.destination_port = (self.destination_port << 8) | byte;
        }
    }

    fn finish(self: *Decoder) FeedState {
        self.phase = .complete;
        return .{ .complete = self.completedValue() };
    }

    fn completedValue(self: *const Decoder) Value {
        return switch (self.command) {
            .local => .local,
            .proxy => .{ .proxy = self.proxiedValue() },
        };
    }

    fn proxiedValue(self: *const Decoder) Proxied {
        if (self.family_protocol == 0x11) return .{
            .source = address.Endpoint.initIpv4(self.source_bytes[0..4].*, self.source_port),
            .destination = address.Endpoint.initIpv4(
                self.destination_bytes[0..4].*,
                self.destination_port,
            ),
        };
        return .{
            .source = address.Endpoint.initIpv6(self.source_bytes, self.source_port),
            .destination = address.Endpoint.initIpv6(
                self.destination_bytes,
                self.destination_port,
            ),
        };
    }

    fn reject(self: *Decoder, reason: InvalidReason) FeedState {
        self.invalid_reason = reason;
        self.phase = .invalid;
        return .{ .invalid = reason };
    }

    fn terminalState(self: *const Decoder) ?FeedState {
        return switch (self.phase) {
            .complete => .{ .complete = self.completedValue() },
            .invalid => .{ .invalid = self.invalid_reason },
            else => null,
        };
    }
};

const tcp4_address = [12]u8{
    192,  0,    2,    9,
    198,  51,   100,  7,
    0x30, 0x39, 0x01, 0xbb,
};
const tcp4_frame = signature ++ [4]u8{ 0x21, 0x11, 0, tcp4_address.len } ++ tcp4_address;
const short_tlv = [7]u8{ 0x04, 0, 4, 1, 2, 3, 4 };
const tcp4_tlv_frame = signature ++
    [4]u8{ 0x21, 0x11, 0, tcp4_address.len + short_tlv.len } ++
    tcp4_address ++ short_tlv;

const tcp6_address = [36]u8{
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9,
    0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7,
    0xff, 0xff, 0,    0,
};
const tcp6_frame = signature ++ [4]u8{ 0x21, 0x21, 0, tcp6_address.len } ++ tcp6_address;

test "vectorized signature path is scalar-equivalent across feed boundaries" {
    for (0..signature.len + 1) |length| {
        try expectFeedModesEquivalent(tcp4_frame[0..length]);
    }
    var mismatch_first = tcp4_frame;
    var mismatch_middle = tcp4_frame;
    var mismatch_last = tcp4_frame;
    mismatch_first[0] ^= 1;
    mismatch_middle[signature.len / 2] ^= 1;
    mismatch_last[signature.len - 1] ^= 1;
    try expectFeedModesEquivalent(&mismatch_first);
    try expectFeedModesEquivalent(&mismatch_middle);
    try expectFeedModesEquivalent(&mismatch_last);
    try expectFeedModesEquivalent(&tcp4_frame);

    for (0..tcp4_frame.len + 1) |split| {
        try expectSplitModesEquivalent(&tcp4_frame, split);
    }
    for (0..tcp6_frame.len + 1) |split| {
        try expectSplitModesEquivalent(&tcp6_frame, split);
    }
    inline for (.{ &mismatch_first, &mismatch_middle, &mismatch_last }) |frame| {
        for (0..frame.len + 1) |split| {
            try expectSplitModesEquivalent(frame, split);
        }
    }

    var scalar = Decoder.init();
    var vectorized = Decoder.init();
    for (tcp4_frame, 0..) |_, index| {
        const input = tcp4_frame[index .. index + 1];
        const scalar_result = scalar.feedScalarBenchmark(input);
        const vector_result = vectorized.feed(input);
        try std.testing.expectEqualDeep(scalar_result, vector_result);
    }
}

fn expectFeedModesEquivalent(input: []const u8) !void {
    var scalar = Decoder.init();
    var vectorized = Decoder.init();
    try std.testing.expectEqualDeep(
        scalar.feedScalarBenchmark(input),
        vectorized.feed(input),
    );
}

fn expectSplitModesEquivalent(input: []const u8, split: usize) !void {
    var scalar = Decoder.init();
    var vectorized = Decoder.init();
    try std.testing.expectEqualDeep(
        scalar.feedScalarBenchmark(input[0..split]),
        vectorized.feed(input[0..split]),
    );
    try std.testing.expectEqualDeep(
        scalar.feedScalarBenchmark(input[split..]),
        vectorized.feed(input[split..]),
    );
}

test "TCP4 and TCP6 retain exact source and destination endpoints" {
    var ipv4 = Decoder.init();
    const value4 = try expectComplete(ipv4.feed(&tcp4_frame));
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv4(.{ 192, 0, 2, 9 }, 12_345),
        value4.proxy.source,
    );
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv4(.{ 198, 51, 100, 7 }, 443),
        value4.proxy.destination,
    );

    var ipv6 = Decoder.init();
    const value6 = try expectComplete(ipv6.feed(&tcp6_frame));
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv6(tcp6_address[0..16].*, 65535),
        value6.proxy.source,
    );
    try std.testing.expectEqualDeep(
        address.Endpoint.initIpv6(tcp6_address[16..32].*, 0),
        value6.proxy.destination,
    );
}

test "LOCAL accepts every family protocol and ignores its declared payload" {
    const local = signature ++ [4]u8{ 0x20, 0xff, 0, 3 } ++ [3]u8{ 1, 2, 3 };
    var decoder = Decoder.init();
    const value = try expectComplete(decoder.feed(&local));
    try std.testing.expect(value == .local);

    const empty = signature ++ [4]u8{ 0x20, 0, 0, 0 };
    decoder = Decoder.init();
    try std.testing.expect((try expectComplete(decoder.feed(&empty))) == .local);
}

test "opaque TLVs are consumed and a coalesced HTTP tail remains untouched" {
    const tail = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    const wire = tcp4_tlv_frame ++ tail.*;
    var decoder = Decoder.init();
    const result = decoder.feed(&wire);
    try std.testing.expectEqual(tcp4_tlv_frame.len, result.consumed);
    _ = try expectComplete(result);
    try std.testing.expectEqualStrings(tail, wire[result.consumed..]);
    try expectStickyComplete(&decoder, tail);
}

test "valid frames complete identically at every split and one-byte fragmentation" {
    for ([_][]const u8{ &tcp4_frame, &tcp6_frame, &tcp4_tlv_frame }) |frame| {
        for (0..frame.len + 1) |split| {
            var decoder = Decoder.init();
            const first = decoder.feed(frame[0..split]);
            if (split < frame.len) try std.testing.expect(first.state == .need_more);
            const second = decoder.feed(frame[split..]);
            try std.testing.expectEqual(frame.len, first.consumed + second.consumed);
            _ = try expectComplete(if (first.state == .complete) first else second);
        }

        var bytes = Decoder.init();
        var final: ?FeedResult = null;
        for (frame) |byte| {
            const result = bytes.feed(&.{byte});
            if (result.state == .complete) final = result;
        }
        _ = try expectComplete(final orelse return error.TestUnexpectedResult);
    }
}

test "malformed fixed headers fail at the first decisive byte and stay terminal" {
    const Case = struct { wire: []const u8, reason: InvalidReason };
    const cases = [_]Case{
        .{ .wire = "X", .reason = .signature },
        .{ .wire = &(signature ++ [1]u8{0x11}), .reason = .version },
        .{ .wire = &(signature ++ [1]u8{0x22}), .reason = .command },
        .{ .wire = &(signature ++ [2]u8{ 0x21, 0x00 }), .reason = .family_protocol },
        .{ .wire = &(signature ++ [2]u8{ 0x21, 0x12 }), .reason = .family_protocol },
        .{ .wire = &(signature ++ [2]u8{ 0x21, 0x31 }), .reason = .family_protocol },
        .{ .wire = &(signature ++ [4]u8{ 0x21, 0x11, 0, 11 }), .reason = .address_length },
        .{ .wire = &(signature ++ [4]u8{ 0x21, 0x21, 0, 35 }), .reason = .address_length },
    };
    for (cases) |case| {
        var decoder = Decoder.init();
        const result = decoder.feed(case.wire);
        try std.testing.expectEqual(case.reason, result.state.invalid);
        const sticky = decoder.feed("HTTP bytes must not be consumed");
        try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
        try std.testing.expectEqual(case.reason, sticky.state.invalid);
    }
}

test "every strict prefix remains incomplete without guessing HTTP" {
    for (0..tcp4_frame.len) |length| {
        var decoder = Decoder.init();
        const result = decoder.feed(tcp4_frame[0..length]);
        try std.testing.expectEqual(length, result.consumed);
        try std.testing.expect(result.state == .need_more);
    }
}

test "LOCAL consumes the maximum declared payload without retaining it" {
    const header = signature ++ [4]u8{ 0x20, 0, 0xff, 0xff };
    var payload: [std.math.maxInt(u16)]u8 = @splat(0xa5);
    var decoder = Decoder.init();
    try std.testing.expect(decoder.feed(&header).state == .need_more);
    const result = decoder.feed(&payload);
    try std.testing.expectEqual(payload.len, result.consumed);
    try std.testing.expect((try expectComplete(result)) == .local);
}

test "maximum PROXY TLV payload bulk-skips fragments and preserves HTTP tail" {
    const prefix = signature ++ [4]u8{ 0x21, 0x11, 0xff, 0xff } ++ tcp4_address;
    const opaque_length = std.math.maxInt(u16) - tcp4_address.len;
    const tail = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    var opaque_and_tail: [opaque_length + tail.len]u8 = @splat(0xa5);
    @memcpy(opaque_and_tail[opaque_length..], tail);

    var decoder = Decoder.init();
    try std.testing.expect(decoder.feed(&prefix).state == .need_more);
    const first = decoder.feed(opaque_and_tail[0..257]);
    try std.testing.expectEqual(@as(usize, 257), first.consumed);
    try std.testing.expect(first.state == .need_more);
    const final = decoder.feed(opaque_and_tail[257..]);
    try std.testing.expectEqual(opaque_length - 257, final.consumed);
    _ = try expectComplete(final);
    try std.testing.expectEqualStrings(tail, opaque_and_tail[opaque_length..]);
}

test "PROXY v2 fragmentation fuzz is result and consumed-count equivalent" {
    try std.testing.fuzz({}, fuzzFragmentation, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const valid4 = smithCase(&tcp4_frame, &.{ 0, 1, 2, 7 });
    const valid6 = smithCase(&tcp6_frame, &.{1});
    const malformed = smithCase(&(signature ++ [2]u8{ 0x21, 0x12 }), &.{ 3, 0 });
    const values = [_][]const u8{ &valid4, &valid6, &malformed };
}.values;

fn fuzzFragmentation(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [256]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var plan_storage: [64]u8 = undefined;
    const plan = plan_storage[0..smith.slice(&plan_storage)];
    const contiguous = try parseSnapshot(input, null);
    const fragmented = try parseSnapshot(input, plan);
    try std.testing.expectEqualDeep(contiguous, fragmented);
}

const Snapshot = struct {
    consumed: usize,
    state: FeedState,
};

fn parseSnapshot(input: []const u8, plan: ?[]const u8) !Snapshot {
    var decoder = Decoder.init();
    var offset: usize = 0;
    var step: usize = 0;
    while (offset < input.len) : (step += 1) {
        const width = if (plan) |parts|
            if (parts.len == 0) 1 else @as(usize, parts[step % parts.len]) + 1
        else
            input.len;
        const end = offset + @min(width, input.len - offset);
        const result = decoder.feed(input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        if (result.state != .need_more) {
            const sticky = decoder.feed(input[offset..]);
            if (sticky.consumed != 0) return error.TestUnexpectedResult;
            try std.testing.expectEqualDeep(result.state, sticky.state);
            return .{ .consumed = offset, .state = result.state };
        }
        if (offset != end) return error.TestUnexpectedResult;
    }
    return .{ .consumed = offset, .state = decoder.feed("").state };
}

fn smithCase(comptime input: []const u8, comptime plan: []const u8) [input.len + plan.len + 8]u8 {
    var result: [input.len + plan.len + 8]u8 = undefined;
    writeSmithSlice(result[0 .. input.len + 4], input);
    writeSmithSlice(result[input.len + 4 ..], plan);
    return result;
}

fn writeSmithSlice(output: []u8, value: []const u8) void {
    std.mem.writeInt(u32, output[0..4], @intCast(value.len), .little);
    @memcpy(output[4..], value);
}

fn expectComplete(result: FeedResult) !Value {
    return switch (result.state) {
        .complete => |value| value,
        .need_more, .invalid => error.TestUnexpectedResult,
    };
}

fn expectStickyComplete(decoder: *Decoder, tail: []const u8) !void {
    const result = decoder.feed(tail);
    try std.testing.expectEqual(@as(usize, 0), result.consumed);
    _ = try expectComplete(result);
}
