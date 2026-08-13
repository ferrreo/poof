const std = @import("std");
const builtin = @import("builtin");
const fuzz_support = @import("testing/smith.zig");
const limits_module = @import("limits.zig");
const request_head_ingest = @import("request_head_ingest.zig");
const request_head_oracle = if (builtin.is_test)
    @import("testing/request_head_oracle.zig")
else
    struct {};
const request_target = @import("request_target.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;
pub const Rejection = struct {
    status: Status,
    close: bool = true,
};
pub const Span = struct {
    offset: u32,
    length: u32,

    pub fn slice(self: Span, bytes: []const u8) []const u8 {
        const start: usize = self.offset;
        const end = start + self.length;
        std.debug.assert(end <= bytes.len);
        return bytes[start..end];
    }
};
pub const Field = struct {
    name: Span,
    raw_value: Span,
    value: Span,
};
pub const Head = struct {
    method: Span,
    target: Span,
    fields_count: u16,
    bytes_count: u32,
};
pub const FeedState = union(enum) {
    need_more,
    ready: Head,
    rejected: Rejection,
};
pub const FeedResult = struct {
    consumed: usize,
    state: FeedState,
};

const ParseError = error{
    BadRequest,
    RequestHeaderFieldsTooLarge,
    HttpVersionNotSupported,
};

const Terminal = union(enum) {
    receiving,
    ready: Head,
    rejected: Rejection,
};

pub fn Decoder(comptime limits: limits_module.RequestHeadLimits) type {
    _ = limits.validate();

    return struct {
        const Self = @This();

        bytes_storage: [limits.head_bytes_max]u8 = undefined,
        fields_storage: [limits.fields_max]Field = undefined,
        bytes_count: usize = 0,
        fields_count: usize = 0,
        line_bytes: usize = 0,
        request_line: bool = true,
        terminal: Terminal = .receiving,

        pub fn init() Self {
            return .{};
        }

        pub fn bytes(self: *const Self) []const u8 {
            return self.bytes_storage[0..self.bytes_count];
        }

        pub fn fields(self: *const Self) []const Field {
            return self.fields_storage[0..self.fields_count];
        }

        pub fn reset(self: *Self) void {
            const used = self.bytes();
            self.bytes_count = 0;
            self.fields_count = 0;
            self.line_bytes = 0;
            self.request_line = true;
            self.terminal = .receiving;
            std.crypto.secureZero(u8, @constCast(used));
        }

        pub const TestAccess = if (builtin.is_test) struct {
            pub fn feedScalar(decoder: *Self, input: []const u8) FeedResult {
                return decoder.feedScalarForTest(input);
            }
        } else struct {};

        pub fn feed(self: *Self, input: []const u8) FeedResult {
            switch (self.terminal) {
                .receiving => {},
                .ready => |head| return .{ .consumed = 0, .state = .{ .ready = head } },
                .rejected => |rejection| return .{
                    .consumed = 0,
                    .state = .{ .rejected = rejection },
                },
            }

            if (input.len == 0) return .{ .consumed = 0, .state = .need_more };
            if (self.capacityRejection()) |rejection| {
                return self.reject(0, rejection.status);
            }
            const initial_count = self.bytes_count;
            const state = request_head_ingest.scanInput(limits, self, input);
            const consumed = self.bytes_count - initial_count;
            @memmove(
                self.bytes_storage[initial_count..][0..consumed],
                input[0..consumed],
            );
            return switch (state) {
                .need_more => .{ .consumed = consumed, .state = .need_more },
                .complete => self.finish(consumed),
                .rejected => |status| self.reject(consumed, status),
            };
        }

        fn feedScalarForTest(self: *Self, input: []const u8) FeedResult {
            switch (self.terminal) {
                .receiving => {},
                .ready => |head| return .{ .consumed = 0, .state = .{ .ready = head } },
                .rejected => |rejection| return .{
                    .consumed = 0,
                    .state = .{ .rejected = rejection },
                },
            }
            for (input, 0..) |byte, index| {
                if (self.capacityRejection()) |rejection| {
                    return self.reject(index, rejection.status);
                }
                self.bytes_storage[self.bytes_count] = byte;
                self.bytes_count += 1;
                self.line_bytes += 1;
                if (!self.validLineEnding(byte)) {
                    return self.reject(index + 1, .bad_request);
                }
                if (byte == '\n') {
                    if (self.request_line) {
                        self.request_line = false;
                        self.line_bytes = 0;
                    } else if (self.line_bytes != 2) {
                        self.line_bytes = 0;
                    } else {
                        return self.finish(index + 1);
                    }
                }
                if (self.capacityRejection()) |rejection| {
                    return self.reject(index + 1, rejection.status);
                }
            }
            return .{ .consumed = input.len, .state = .need_more };
        }

        fn capacityRejection(self: *const Self) ?Rejection {
            const line_max = if (self.request_line)
                limits.request_line_bytes_max
            else
                limits.field_line_bytes_max;
            if (self.line_bytes >= line_max) {
                const status: Status = if (self.request_line)
                    .uri_too_long
                else
                    .request_header_fields_too_large;
                return .{ .status = status };
            }
            if (self.bytes_count >= limits.head_bytes_max) {
                return .{ .status = .request_header_fields_too_large };
            }
            return null;
        }

        fn validLineEnding(self: *const Self, byte: u8) bool {
            if (byte == '\n') {
                return self.bytes_count >= 2 and
                    self.bytes_storage[self.bytes_count - 2] == '\r';
            }
            if (self.bytes_count < 2) return true;
            return self.bytes_storage[self.bytes_count - 2] != '\r';
        }

        fn finish(self: *Self, consumed: usize) FeedResult {
            const head = self.parse() catch |err| {
                const status: Status = switch (err) {
                    error.BadRequest => .bad_request,
                    error.RequestHeaderFieldsTooLarge => .request_header_fields_too_large,
                    error.HttpVersionNotSupported => .http_version_not_supported,
                };
                return self.reject(consumed, status);
            };
            self.terminal = .{ .ready = head };
            return .{ .consumed = consumed, .state = .{ .ready = head } };
        }

        fn reject(self: *Self, consumed: usize, status: Status) FeedResult {
            const rejection = Rejection{ .status = status };
            self.terminal = .{ .rejected = rejection };
            return .{ .consumed = consumed, .state = .{ .rejected = rejection } };
        }

        fn parse(self: *Self) ParseError!Head {
            const first_end = findCrlf(self.bytes(), 0) orelse return error.BadRequest;
            const request = try parseRequestLine(self.bytes()[0..first_end]);
            var cursor = first_end + 2;
            var host_count: usize = 0;
            while (cursor + 2 <= self.bytes_count) {
                const line_end = findCrlf(self.bytes(), cursor) orelse return error.BadRequest;
                if (line_end == cursor) break;
                if (self.fields_count == limits.fields_max) {
                    return error.RequestHeaderFieldsTooLarge;
                }
                const field = try parseField(self.bytes(), cursor, line_end);
                self.fields_storage[self.fields_count] = field;
                self.fields_count += 1;
                if (syntax.eqlIgnoreCase(field.name.slice(self.bytes()), "host")) {
                    host_count += 1;
                    if (!request_target.validAuthoritySyntax(
                        field.value.slice(self.bytes()),
                        .optional,
                    )) return error.BadRequest;
                }
                cursor = line_end + 2;
            }
            if (host_count != 1) return error.BadRequest;
            return .{
                .method = request.method,
                .target = request.target,
                .fields_count = @intCast(self.fields_count),
                .bytes_count = @intCast(self.bytes_count),
            };
        }
    };
}

const RequestLine = struct {
    method: Span,
    target: Span,
};

fn parseRequestLine(line: []const u8) ParseError!RequestLine {
    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const second_space = std.mem.indexOfScalarPos(
        u8,
        line,
        first_space + 1,
        ' ',
    ) orelse return error.BadRequest;
    if (std.mem.indexOfScalarPos(u8, line, second_space + 1, ' ') != null) {
        return error.BadRequest;
    }
    const method = line[0..first_space];
    const target = line[first_space + 1 .. second_space];
    const version = line[second_space + 1 ..];
    if (!syntax.isToken(method) or !validRequestTarget(target)) return error.BadRequest;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) {
        if (validHttpVersion(version)) {
            return error.HttpVersionNotSupported;
        }
        return error.BadRequest;
    }
    return .{
        .method = makeSpan(0, method.len),
        .target = makeSpan(first_space + 1, target.len),
    };
}

fn validRequestTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    for (target) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

fn validHttpVersion(version: []const u8) bool {
    return version.len == "HTTP/1.1".len and
        std.mem.startsWith(u8, version, "HTTP/") and
        version[5] >= '0' and version[5] <= '9' and
        version[6] == '.' and
        version[7] >= '0' and version[7] <= '9';
}

fn parseField(bytes: []const u8, start: usize, end: usize) ParseError!Field {
    const line = bytes[start..end];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
    const name = line[0..colon];
    const raw_value = line[colon + 1 ..];
    if (!syntax.isToken(name) or !syntax.isFieldValue(raw_value)) return error.BadRequest;
    const value = syntax.trimOws(raw_value);
    const raw_start = start + colon + 1;
    var leading_ows: usize = 0;
    while (leading_ows < raw_value.len and
        (raw_value[leading_ows] == ' ' or raw_value[leading_ows] == '\t'))
    {
        leading_ows += 1;
    }
    const value_start = raw_start + leading_ows;
    return .{
        .name = makeSpan(start, name.len),
        .raw_value = makeSpan(raw_start, raw_value.len),
        .value = makeSpan(value_start, value.len),
    };
}

fn findCrlf(bytes: []const u8, start: usize) ?usize {
    return std.mem.indexOfPos(u8, bytes, start, "\r\n");
}

fn makeSpan(offset: usize, length: usize) Span {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

const example_request = "GET /ping HTTP/1.1\r\nHost: example.test\r\n\r\n";
const example_with_remainder = example_request ++ "next";
const minimal_request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
const example_with_large_body = example_request ++ ([_]u8{'x'} ** 4096);

test "request head parses contiguously and leaves remainder" {
    const Parser = Decoder(limits_module.standard_request_head_limits);
    var parser = Parser.init();
    const result = parser.feed(example_with_remainder);

    try std.testing.expectEqual(example_request.len, result.consumed);
    const head = switch (result.state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    try expectExample(&parser, head);
}

test "request head bulk ingest does not copy or consume a large body" {
    const Parser = Decoder(limits_module.standard_request_head_limits);
    var parser = Parser.init();
    const result = parser.feed(example_with_large_body);

    try std.testing.expectEqual(example_request.len, result.consumed);
    try std.testing.expectEqualStrings(example_request, parser.bytes());
    switch (result.state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
}

test "request head parses identically at every split" {
    const Parser = Decoder(limits_module.standard_request_head_limits);
    var split: usize = 0;
    while (split <= example_request.len) : (split += 1) {
        var parser = Parser.init();
        const first = parser.feed(example_request[0..split]);
        if (split < example_request.len) {
            try std.testing.expect(first.state == .need_more);
        }
        const second = parser.feed(example_request[split..]);
        const head = switch (second.state) {
            .ready => |head| head,
            else => return error.TestUnexpectedResult,
        };
        try expectExample(&parser, head);
    }
}

test "request head parses one byte fragments" {
    const Parser = Decoder(limits_module.standard_request_head_limits);
    var parser = Parser.init();
    var head: ?Head = null;
    for (example_request) |byte| {
        const result = parser.feed(&.{byte});
        switch (result.state) {
            .need_more => {},
            .ready => |ready| head = ready,
            .rejected => return error.TestUnexpectedResult,
        }
    }
    try expectExample(&parser, head orelse return error.TestUnexpectedResult);
}

test "request head rejects strict grammar and Host violations" {
    const cases = [_][]const u8{
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET  / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost : x\r\n\r\n",
        "GET / HTTP/1.1\r\n folded\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost:\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET /\x00 HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/x.y\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nX-Nul: \x00\r\nHost: x\r\n\r\n",
    };
    for (cases) |case| try expectRejected(case, .bad_request);
}

test "request head validates Host authority syntax" {
    const valid = [_][]const u8{
        "example.test",
        "example.test:",
        "example.test:443",
        "[::1]",
        "[::1]:",
        "[v1.a:b]:443",
    };
    for (valid) |host| {
        var wire: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &wire,
            "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n",
            .{host},
        );
        try expectReadyRequest(request);
    }

    const invalid = [_][]const u8{
        "user@example.test",
        "example.test:65536",
        "[::::]",
        "[fe80::1%25eth0]",
        "host\\name",
    };
    for (invalid) |host| {
        var wire: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &wire,
            "GET / HTTP/1.1\r\nHost: {s}\r\n\r\n",
            .{host},
        );
        try expectRejected(request, .bad_request);
    }
}

test "request head classifies version and bounded overflows" {
    try expectRejected(
        "GET / HTTP/1.0\r\nHost: x\r\n\r\n",
        .http_version_not_supported,
    );
    const tiny_line = limits_module.RequestHeadLimits{
        .head_bytes_max = 64,
        .request_line_bytes_max = 8,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    };
    try expectRejectedWith(tiny_line, example_request, .uri_too_long);

    const tiny_fields = limits_module.RequestHeadLimits{
        .head_bytes_max = 64,
        .request_line_bytes_max = 32,
        .field_line_bytes_max = 8,
        .fields_max = 2,
    };
    try expectRejectedWith(tiny_fields, example_request, .request_header_fields_too_large);

    const tiny_head = limits_module.RequestHeadLimits{
        .head_bytes_max = 26,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 9,
        .fields_max = 2,
    };
    try expectRejectedWith(
        tiny_head,
        "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        .request_header_fields_too_large,
    );

    const one_field = limits_module.RequestHeadLimits{
        .head_bytes_max = 64,
        .request_line_bytes_max = 32,
        .field_line_bytes_max = 32,
        .fields_max = 1,
    };
    try expectRejectedWith(
        one_field,
        "GET / HTTP/1.1\r\nHost: x\r\nX-Test: y\r\n\r\n",
        .request_header_fields_too_large,
    );
}

test "request head accepts completed inclusive limits at every split" {
    const exact_limits = limits_module.RequestHeadLimits{
        .head_bytes_max = minimal_request.len,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 9,
        .fields_max = 1,
    };
    const Parser = Decoder(exact_limits);
    for (0..minimal_request.len + 1) |split| {
        var parser = Parser.init();
        const first = parser.feed(minimal_request[0..split]);
        try std.testing.expectEqual(split, first.consumed);
        const empty = parser.feed("");
        try std.testing.expectEqual(@as(usize, 0), empty.consumed);

        const second = parser.feed(minimal_request[split..]);
        try std.testing.expectEqual(minimal_request.len - split, second.consumed);
        switch (second.state) {
            .ready => {},
            else => return error.TestUnexpectedResult,
        }
        const sticky = parser.feed("next");
        try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
        try std.testing.expect(sticky.state == .ready);
    }
}

test "request head reset wipes used bytes and reuses backing storage" {
    const Parser = Decoder(.{
        .head_bytes_max = 64,
        .request_line_bytes_max = 32,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    });
    var parser = Parser.init();
    try std.testing.expect(parser.feed(minimal_request).state == .ready);
    parser.reset();
    try std.testing.expectEqual(@as(usize, 0), parser.bytes().len);
    try std.testing.expectEqual(@as(usize, 0), parser.fields().len);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** minimal_request.len),
        parser.bytes_storage[0..minimal_request.len],
    );
    try std.testing.expect(parser.feed(minimal_request).state == .ready);
}

test "request head rejects exact incomplete capacities at every split" {
    try expectCapacityRejectionAtEverySplit(.{
        .head_bytes_max = 64,
        .request_line_bytes_max = 15,
        .field_line_bytes_max = 16,
        .fields_max = 1,
    }, "GET / HTTP/1.1\r", .uri_too_long);
    try expectCapacityRejectionAtEverySplit(.{
        .head_bytes_max = 64,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 8,
        .fields_max = 1,
    }, "GET / HTTP/1.1\r\nHost: x\r", .request_header_fields_too_large);
    try expectCapacityRejectionAtEverySplit(.{
        .head_bytes_max = minimal_request.len - 1,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 9,
        .fields_max = 1,
    }, minimal_request[0 .. minimal_request.len - 1], .request_header_fields_too_large);
}

test "request head bulk ingest matches scalar oracle at every split" {
    const standard_cases = [_][]const u8{
        example_with_remainder,
        "GET / HTTP/1.1\r\nHost: x\r\nX-Test: alpha-bravo-charlie\r\n\r\nbody",
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET / HTTP/1.1\rX",
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
        "GET / HTTP/1.0\r\nHost: x\r\n\r\n",
    };
    for (standard_cases) |input| {
        try request_head_oracle.expectAtEverySplit(
            Decoder(limits_module.standard_request_head_limits),
            input,
        );
    }

    try request_head_oracle.expectAtEverySplit(Decoder(.{
        .head_bytes_max = 64,
        .request_line_bytes_max = 15,
        .field_line_bytes_max = 16,
        .fields_max = 1,
    }), "GET / HTTP/1.1\r");
    try request_head_oracle.expectAtEverySplit(Decoder(.{
        .head_bytes_max = 64,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 8,
        .fields_max = 1,
    }), "GET / HTTP/1.1\r\nHost: x\r");
    try request_head_oracle.expectAtEverySplit(Decoder(.{
        .head_bytes_max = minimal_request.len - 1,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 9,
        .fields_max = 1,
    }), minimal_request);
    try request_head_oracle.expectAtEverySplit(Decoder(.{
        .head_bytes_max = minimal_request.len,
        .request_line_bytes_max = 16,
        .field_line_bytes_max = 9,
        .fields_max = 1,
    }), minimal_request);
}

test "request head fragmentation differential fuzz" {
    try std.testing.fuzz({}, fuzzRequestHead, .{ .corpus = &request_head_fuzz_corpus });
}

const request_head_fuzz_corpus = struct {
    const example = fuzz_support.smithInput(example_request);
    const content_length = fuzz_support.smithInput(
        "GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx",
    );
    const bare_lf = fuzz_support.smithInput("GET / HTTP/1.1\nHost: x\n\n");
    const duplicate_host = fuzz_support.smithInput(
        "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
    );

    const values = [_][]const u8{
        &example,
        &content_length,
        &bare_lf,
        &duplicate_host,
    };
}.values;

fn fuzzRequestHead(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const input_length = smith.slice(&input_storage);
    const input = input_storage[0..input_length];
    const Parser = Decoder(limits_module.standard_request_head_limits);

    var contiguous = Parser.init();
    const contiguous_result = contiguous.feed(input);
    var scalar_contiguous = Parser.init();
    const scalar_contiguous_result = Parser.TestAccess.feedScalar(&scalar_contiguous, input);
    try request_head_oracle.expectFeedEquivalent(
        &contiguous,
        contiguous_result,
        &scalar_contiguous,
        scalar_contiguous_result,
    );

    var fragmented = Parser.init();
    var fragmented_result = fragmented.feed("");
    var scalar_fragmented = Parser.init();
    var scalar_fragmented_result = Parser.TestAccess.feedScalar(&scalar_fragmented, "");
    try request_head_oracle.expectFeedEquivalent(
        &fragmented,
        fragmented_result,
        &scalar_fragmented,
        scalar_fragmented_result,
    );
    var consumed: usize = 0;
    var cursor: usize = 0;
    while (cursor < input.len) {
        const remaining = input.len - cursor;
        const chunk_length = smith.valueRangeAtMost(
            u8,
            1,
            @intCast(@min(remaining, 64)),
        );
        const chunk = input[cursor..][0..chunk_length];
        fragmented_result = fragmented.feed(chunk);
        scalar_fragmented_result = Parser.TestAccess.feedScalar(&scalar_fragmented, chunk);
        try request_head_oracle.expectFeedEquivalent(
            &fragmented,
            fragmented_result,
            &scalar_fragmented,
            scalar_fragmented_result,
        );
        consumed += fragmented_result.consumed;
        cursor += chunk_length;
        if (fragmented_result.state != .need_more) break;
    }

    try std.testing.expectEqual(contiguous_result.consumed, consumed);
    try request_head_oracle.expectParserStateEquivalent(
        &contiguous,
        contiguous_result,
        &fragmented,
        fragmented_result,
    );
}

fn expectExample(parser: anytype, head: Head) !void {
    try std.testing.expectEqualStrings("GET", head.method.slice(parser.bytes()));
    try std.testing.expectEqualStrings("/ping", head.target.slice(parser.bytes()));
    try std.testing.expectEqual(@as(u16, 1), head.fields_count);
    const host = parser.fields()[0];
    try std.testing.expectEqualStrings("Host", host.name.slice(parser.bytes()));
    try std.testing.expectEqualStrings(" example.test", host.raw_value.slice(parser.bytes()));
    try std.testing.expectEqualStrings("example.test", host.value.slice(parser.bytes()));
}

fn expectReadyRequest(input: []const u8) !void {
    const Parser = Decoder(limits_module.standard_request_head_limits);
    var parser = Parser.init();
    switch (parser.feed(input).state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
}

fn expectRejected(input: []const u8, status: Status) !void {
    try expectRejectedWith(limits_module.standard_request_head_limits, input, status);
}

fn expectCapacityRejectionAtEverySplit(
    comptime limits: limits_module.RequestHeadLimits,
    input: []const u8,
    status: Status,
) !void {
    const Parser = Decoder(limits);
    for (0..input.len + 1) |split| {
        var parser = Parser.init();
        const first = parser.feed(input[0..split]);
        var result = first;
        var consumed = first.consumed;
        if (first.state == .need_more) {
            const empty = parser.feed("");
            try std.testing.expectEqual(@as(usize, 0), empty.consumed);
            try std.testing.expect(empty.state == .need_more);
            result = parser.feed(input[split..]);
            consumed += result.consumed;
        }
        try std.testing.expectEqual(input.len, consumed);
        try std.testing.expectEqual(input.len, parser.bytes().len);
        const rejection = switch (result.state) {
            .rejected => |rejection| rejection,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(status, rejection.status);
        for ([_][]const u8{ "", "ignored" }) |fragment| {
            const sticky = parser.feed(fragment);
            try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
            try std.testing.expectEqual(status, sticky.state.rejected.status);
        }
    }
}

fn expectRejectedWith(
    comptime limits: limits_module.RequestHeadLimits,
    input: []const u8,
    status: Status,
) !void {
    const Parser = Decoder(limits);
    var parser = Parser.init();
    const result = parser.feed(input);
    const rejection = switch (result.state) {
        .rejected => |rejection| rejection,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}
