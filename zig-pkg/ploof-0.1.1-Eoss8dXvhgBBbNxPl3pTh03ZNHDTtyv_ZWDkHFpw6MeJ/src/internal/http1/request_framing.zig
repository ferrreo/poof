const std = @import("std");
const request_head = @import("request_head.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;

pub const Rejection = struct {
    status: Status,
    close: bool = true,
};

pub const BodyFraming = union(enum) {
    none,
    fixed: u64,
    chunked,
};

pub const Analysis = struct {
    body: BodyFraming,
    trailer_declared: bool,
};

pub const Result = union(enum) {
    accepted: Analysis,
    rejected: Rejection,
};

const TransferEncodingClass = enum(u8) {
    chunked,
    unsupported,
    malformed,
};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Result {
    var content_length: ?request_head.Span = null;
    var transfer_encoding: ?request_head.Span = null;
    var trailer_declared = false;

    for (fields) |field| {
        const name = field.name.slice(bytes);
        if (syntax.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null) return reject(.bad_request);
            content_length = field.value;
            continue;
        }
        if (syntax.eqlIgnoreCase(name, "transfer-encoding")) {
            if (transfer_encoding != null) return reject(.bad_request);
            transfer_encoding = field.value;
            continue;
        }
        if (syntax.eqlIgnoreCase(name, "trailer")) trailer_declared = true;
    }

    if (content_length != null and transfer_encoding != null) {
        return reject(.bad_request);
    }
    if (transfer_encoding) |span| {
        return switch (classifyTransferEncoding(span.slice(bytes))) {
            .malformed => reject(.bad_request),
            .unsupported => if (trailer_declared)
                reject(.bad_request)
            else
                reject(.not_implemented),
            .chunked => accept(.chunked, trailer_declared),
        };
    }
    if (trailer_declared) return reject(.bad_request);
    if (content_length) |span| {
        const length = syntax.parseDecimal(span.slice(bytes)) catch {
            return reject(.bad_request);
        };
        return accept(.{ .fixed = length }, false);
    }
    return accept(.none, false);
}

fn classifyTransferEncoding(value_raw: []const u8) TransferEncodingClass {
    const value = syntax.trimOws(value_raw);
    var index: usize = 0;
    skipOws(value, &index);
    var unsupported = false;
    var chunked_seen = false;

    while (true) {
        const coding = consumeTransferCoding(value, &index) orelse return .malformed;
        if (syntax.eqlIgnoreCase(coding.name, "chunked")) {
            if (chunked_seen or coding.parameterized) return .malformed;
            chunked_seen = true;
        } else {
            unsupported = true;
        }

        if (index == value.len) break;
        if (value[index] != ',' or chunked_seen) return .malformed;
        index += 1;
        skipOws(value, &index);
    }
    if (!chunked_seen or unsupported) return .unsupported;
    return .chunked;
}

const TransferCoding = struct {
    name: []const u8,
    parameterized: bool,
};

fn consumeTransferCoding(value: []const u8, index: *usize) ?TransferCoding {
    const name_start = index.*;
    if (!consumeToken(value, index)) return null;
    const name = value[name_start..index.*];
    skipOws(value, index);

    var parameterized = false;
    while (index.* < value.len and value[index.*] == ';') {
        parameterized = true;
        index.* += 1;
        skipOws(value, index);
        if (!consumeParameter(value, index)) return null;
        skipOws(value, index);
    }
    return .{ .name = name, .parameterized = parameterized };
}

fn consumeParameter(value: []const u8, index: *usize) bool {
    if (!consumeToken(value, index)) return false;
    skipOws(value, index);
    if (index.* == value.len or value[index.*] != '=') return false;
    index.* += 1;
    skipOws(value, index);
    if (index.* < value.len and value[index.*] == '"') {
        return consumeQuotedString(value, index);
    }
    return consumeToken(value, index);
}

fn consumeToken(value: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < value.len and syntax.isTokenByte(value[index.*])) {
        index.* += 1;
    }
    return index.* != start;
}

fn consumeQuotedString(value: []const u8, index: *usize) bool {
    std.debug.assert(index.* < value.len);
    std.debug.assert(value[index.*] == '"');
    index.* += 1;

    while (index.* < value.len) {
        const byte = value[index.*];
        index.* += 1;
        if (byte == '"') return true;
        if (byte == '\\') {
            if (index.* == value.len or !validQuotedPairByte(value[index.*])) return false;
            index.* += 1;
            continue;
        }
        if (!validQuotedTextByte(byte)) return false;
    }
    return false;
}

fn validQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == 0x21 or
        (byte >= 0x23 and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e) or byte >= 0x80;
}

fn validQuotedPairByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn skipOws(value: []const u8, index: *usize) void {
    while (index.* < value.len and
        (value[index.*] == ' ' or value[index.*] == '\t'))
    {
        index.* += 1;
    }
}

fn accept(body: BodyFraming, trailer_declared: bool) Result {
    return .{ .accepted = .{
        .body = body,
        .trailer_declared = trailer_declared,
    } };
}

fn reject(status: Status) Result {
    return .{ .rejected = .{ .status = status } };
}

const request_prefix = "POST / HTTP/1.1\r\nHost: example.test\r\n";

test "selects no body without framing fields" {
    try expectNone(request_prefix ++ "\r\n");
}

test "accepts one strict content length" {
    try expectFixed(request_prefix ++ "cOnTeNt-LeNgTh:\t 42 \t\r\n\r\n", 42);
    try expectFixed(
        request_prefix ++ "Content-Length: 18446744073709551615\r\n\r\n",
        std.math.maxInt(u64),
    );
}

test "rejects invalid and overflowing content lengths" {
    const cases = [_][]const u8{
        request_prefix ++ "Content-Length:\r\n\r\n",
        request_prefix ++ "Content-Length: nope\r\n\r\n",
        request_prefix ++ "Content-Length: 1, 1\r\n\r\n",
        request_prefix ++ "Content-Length: 18446744073709551616\r\n\r\n",
    };
    for (cases) |case| try expectRejected(case, .bad_request);
}

test "rejects all duplicate content lengths" {
    try expectRejected(
        request_prefix ++
            "Content-Length: 3\r\nContent-Length: 3\r\n\r\n",
        .bad_request,
    );
    try expectRejected(
        request_prefix ++
            "Content-Length: 3\r\nContent-Length: 4\r\n\r\n",
        .bad_request,
    );
}

test "accepts only exact case-insensitive chunked coding" {
    try expectChunked(
        request_prefix ++ "TrAnSfEr-EnCoDiNg:\t ChUnKeD \t\r\n\r\n",
        false,
    );
}

test "rejects duplicate transfer encoding and length combinations" {
    try expectRejected(
        request_prefix ++
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        .bad_request,
    );
    try expectRejected(
        request_prefix ++
            "Transfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n",
        .bad_request,
    );
    try expectRejected(
        request_prefix ++
            "Transfer-Encoding: gzip\r\nContent-Length: 3\r\n\r\n",
        .bad_request,
    );
    try expectRejected(
        request_prefix ++
            "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
        .bad_request,
    );
}

test "classifies valid unsupported transfer codings as 501" {
    const cases = [_][]const u8{
        request_prefix ++ "Transfer-Encoding: gzip\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip, chunked\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip; level = 1\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: custom; p=\"a\\\"b\"\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip, deflate, chunked\r\n\r\n",
    };
    for (cases) |case| try expectRejected(case, .not_implemented);
}

test "classifies malformed transfer encoding as 400" {
    const cases = [_][]const u8{
        request_prefix ++ "Transfer-Encoding:\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip,,chunked\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip,\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip;\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip; p\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip; p=\"open\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: chunk ed\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: chunked, gzip\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: chunked, chunked\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip, chunked, chunked\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: chunked; p=x\r\n\r\n",
        request_prefix ++ "Transfer-Encoding: gzip, chunked; p=x\r\n\r\n",
    };
    for (cases) |case| try expectRejected(case, .bad_request);
}

test "allows trailer declarations only for chunked bodies" {
    try expectRejected(request_prefix ++ "Trailer: Digest\r\n\r\n", .bad_request);
    try expectRejected(
        request_prefix ++ "Content-Length: 3\r\nTrailer: Digest\r\n\r\n",
        .bad_request,
    );
    try expectRejected(
        request_prefix ++ "Transfer-Encoding: gzip\r\nTrailer: Digest\r\n\r\n",
        .bad_request,
    );
    try expectChunked(
        request_prefix ++ "Transfer-Encoding: chunked\r\nTrailer: Digest\r\n\r\n",
        true,
    );
}

fn analyzeRequest(input: []const u8) !Result {
    const Parser = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
    var parser = Parser.init();
    const decoded = parser.feed(input);
    _ = switch (decoded.state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    return analyze(parser.fields(), parser.bytes());
}

fn expectNone(input: []const u8) !void {
    const analysis = try expectAccepted(input);
    try std.testing.expect(analysis.body == .none);
    try std.testing.expect(!analysis.trailer_declared);
}

fn expectFixed(input: []const u8, expected: u64) !void {
    const analysis = try expectAccepted(input);
    const length = switch (analysis.body) {
        .fixed => |length| length,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected, length);
    try std.testing.expect(!analysis.trailer_declared);
}

fn expectChunked(input: []const u8, trailer_declared: bool) !void {
    const analysis = try expectAccepted(input);
    try std.testing.expect(analysis.body == .chunked);
    try std.testing.expectEqual(trailer_declared, analysis.trailer_declared);
}

fn expectAccepted(input: []const u8) !Analysis {
    return switch (try analyzeRequest(input)) {
        .accepted => |analysis| analysis,
        .rejected => error.TestUnexpectedResult,
    };
}

fn expectRejected(input: []const u8, status: Status) !void {
    const rejection = switch (try analyzeRequest(input)) {
        .rejected => |rejection| rejection,
        .accepted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}
