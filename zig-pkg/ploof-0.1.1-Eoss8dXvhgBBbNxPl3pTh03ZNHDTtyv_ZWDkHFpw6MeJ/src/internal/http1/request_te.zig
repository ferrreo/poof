const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const request_head = @import("request_head.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;

pub const Rejection = struct {
    status: Status,
    close: bool = true,
};

pub const Analysis = struct {
    accepts_trailers: bool,
};

pub const Result = union(enum) {
    accepted: Analysis,
    rejected: Rejection,
};

const ParseError = error{Invalid};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Result {
    var accepts_trailers = false;
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), "te")) continue;
        const value_accepts = parseFieldValue(field.value.slice(bytes)) catch {
            return reject();
        };
        accepts_trailers = accepts_trailers or value_accepts;
    }
    return .{ .accepted = .{ .accepts_trailers = accepts_trailers } };
}

fn parseFieldValue(value: []const u8) ParseError!bool {
    if (!syntax.isFieldValue(value)) return error.Invalid;

    var index: usize = 0;
    var accepts_trailers = false;
    skipOws(value, &index);
    while (index < value.len) {
        if (value[index] == ',') {
            index += 1;
            skipOws(value, &index);
            continue;
        }
        const member_accepts = try consumeMember(value, &index);
        accepts_trailers = accepts_trailers or member_accepts;
        if (index == value.len) break;
        std.debug.assert(value[index] == ',');
        index += 1;
        skipOws(value, &index);
    }
    return accepts_trailers;
}

fn consumeMember(value: []const u8, index: *usize) ParseError!bool {
    const name_start = index.*;
    try consumeToken(value, index);
    const name = value[name_start..index.*];
    skipOws(value, index);

    // The reserved trailers alternative is bare; it is not a transfer coding.
    if (syntax.eqlIgnoreCase(name, "trailers")) {
        try requireMemberEnd(value, index.*);
        return true;
    }

    while (index.* < value.len and value[index.*] != ',') {
        if (value[index.*] != ';') return error.Invalid;
        index.* += 1;
        skipOws(value, index);
        if (try consumeParameter(value, index)) {
            skipOws(value, index);
            try requireMemberEnd(value, index.*);
            return false;
        }
        skipOws(value, index);
    }
    return false;
}

fn consumeParameter(value: []const u8, index: *usize) ParseError!bool {
    const name_start = index.*;
    try consumeToken(value, index);
    const name = value[name_start..index.*];
    // RFC 9110 defines q case-insensitively as the optional final weight.
    const is_weight = syntax.eqlIgnoreCase(name, "q");

    if (!is_weight) skipOws(value, index);
    if (index.* == value.len or value[index.*] != '=') return error.Invalid;
    index.* += 1;
    if (is_weight) {
        try consumeQvalue(value, index);
        return true;
    }

    skipOws(value, index);
    if (index.* < value.len and value[index.*] == '"') {
        try consumeQuotedString(value, index);
    } else {
        try consumeToken(value, index);
    }
    return false;
}

fn consumeToken(value: []const u8, index: *usize) ParseError!void {
    const start = index.*;
    while (index.* < value.len and syntax.isTokenByte(value[index.*])) {
        index.* += 1;
    }
    if (index.* == start) return error.Invalid;
}

fn consumeQvalue(value: []const u8, index: *usize) ParseError!void {
    if (index.* == value.len) return error.Invalid;
    const whole = value[index.*];
    if (whole != '0' and whole != '1') return error.Invalid;
    index.* += 1;
    if (index.* == value.len or value[index.*] != '.') return;
    index.* += 1;

    var digits: u8 = 0;
    while (index.* < value.len and digits < 3) : (digits += 1) {
        const byte = value[index.*];
        if (byte < '0' or byte > '9') break;
        if (whole == '1' and byte != '0') return error.Invalid;
        index.* += 1;
    }
}

fn consumeQuotedString(value: []const u8, index: *usize) ParseError!void {
    std.debug.assert(index.* < value.len);
    std.debug.assert(value[index.*] == '"');
    index.* += 1;
    while (index.* < value.len) {
        const byte = value[index.*];
        index.* += 1;
        if (byte == '"') return;
        if (byte == '\\') {
            if (index.* == value.len or !validQuotedPairByte(value[index.*])) {
                return error.Invalid;
            }
            index.* += 1;
            continue;
        }
        if (!validQuotedTextByte(byte)) return error.Invalid;
    }
    return error.Invalid;
}

fn validQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == 0x21 or
        (byte >= 0x23 and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e) or byte >= 0x80;
}

fn validQuotedPairByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn requireMemberEnd(value: []const u8, index: usize) ParseError!void {
    if (index != value.len and value[index] != ',') return error.Invalid;
}

fn skipOws(value: []const u8, index: *usize) void {
    while (index.* < value.len and
        (value[index.*] == ' ' or value[index.*] == '\t'))
    {
        index.* += 1;
    }
}

fn reject() Result {
    return .{ .rejected = .{ .status = .bad_request } };
}

const request_prefix = "GET / HTTP/1.1\r\nHost: example.test\r\n";

test "absence and empty TE lists do not negotiate trailers" {
    try expectAccepted(request_prefix ++ "\r\n", false);
    try expectAccepted(request_prefix ++ "TE:\r\n\r\n", false);
    try expectAccepted(request_prefix ++ "TE: , \t, ,\r\n\r\n", false);
}

test "negotiates a case-insensitive trailers member" {
    try expectAccepted(request_prefix ++ "TE: TrAiLeRs\r\n\r\n", true);
    try expectAccepted(request_prefix ++ "TE: , gzip, trailers, \r\n\r\n", true);
    try expectAccepted(request_prefix ++ "TE: trailers, trailers\r\n\r\n", true);
}

test "combines every physical TE field as list syntax" {
    try expectAccepted(
        request_prefix ++ "TE: gzip,\r\nTE: , TrAiLeRs\r\nTE: deflate\r\n\r\n",
        true,
    );
    try expectRejected(
        request_prefix ++ "TE: trailers\r\nTE: gzip; broken\r\n\r\n",
    );
}

test "accepts syntactically valid unsupported coding preferences" {
    const cases = [_][]const u8{
        "gzip",
        "gzip;level=1",
        "gzip ; level = \"a,b\\\"c\" ; mode = fast",
        "gzip;q=0, deflate;Q=1.000",
        "gzip;q=0., deflate;q=1.",
        "custom;p=\"\t \x80\\\xff\"",
    };
    for (cases) |value| try expectRawAccepted(value, false);
}

test "enforces qvalue grammar and final weight position" {
    const cases = [_][]const u8{
        "gzip;q=",
        "gzip;q=.5",
        "gzip;q=00",
        "gzip;q=0.0000",
        "gzip;q=1.001",
        "gzip;q=2",
        "gzip;q=\"0.5\"",
        "gzip;q =0.5",
        "gzip;q= 0.5",
        "gzip;q=0.5;p=x",
        "gzip;q=0.5;q=0.4",
    };
    for (cases) |value| try expectRawRejected(value);
}

test "trailers is a parameter-free special member" {
    try expectRawRejected("trailers;q=1");
    try expectRawRejected("trailers;p=x");
    try expectRawRejected("trailers extra");
}

test "rejects malformed members and parameters" {
    const cases = [_][]const u8{
        ";",
        "gzip deflate",
        "gzip;",
        "gzip;p",
        "gzip;p=",
        "gzip;p=()",
        "gzip;p=\"open",
        "gzip;p=\"slash\\",
    };
    for (cases) |value| try expectRawRejected(value);
}

test "rejects control bytes and obs text outside quoted strings" {
    try expectRawRejected("gzip\x00");
    try expectRawRejected("gzip\x1f");
    try expectRawRejected("gzip\x7f");
    try expectRawRejected("gzip;\x80=x");
}

test "TE parser fuzzes differentially against independent grammar" {
    try std.testing.fuzz({}, fuzzRequestTe, .{ .corpus = &te_fuzz_corpus });
}

const te_fuzz_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const empty_members = fuzz_support.smithInput(", ,\t,");
    const trailers = fuzz_support.smithInput("trailers");
    const mixed_case = fuzz_support.smithInput("TrAiLeRs, gzip");
    const weight = fuzz_support.smithInput("gzip;q=0.5");
    const quoted = fuzz_support.smithInput("gzip;p=\"a,b\\\"c\"");
    const weighted_trailers = fuzz_support.smithInput("trailers;q=1");
    const invalid_weight = fuzz_support.smithInput("gzip;q=1.001");
    const control = fuzz_support.smithInput("gzip\x00");
    const open_quote = fuzz_support.smithInput("gzip;p=\"open");

    const values = [_][]const u8{
        &empty,
        &empty_members,
        &trailers,
        &mixed_case,
        &weight,
        &quoted,
        &weighted_trailers,
        &invalid_weight,
        &control,
        &open_quote,
    };
}.values;

fn fuzzRequestTe(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const value = storage[0..smith.slice(&storage)];
    const expected = referenceParse(value);

    switch (analyzeRawValue(value)) {
        .rejected => |rejection| {
            try std.testing.expect(expected == null);
            try std.testing.expectEqual(Status.bad_request, rejection.status);
            try std.testing.expect(rejection.close);
        },
        .accepted => |analysis| {
            const accepts_trailers = expected orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(accepts_trailers, analysis.accepts_trailers);
            if (analysis.accepts_trailers) try std.testing.expect(accepts_trailers);
        },
    }
}

fn referenceParse(value: []const u8) ?bool {
    for (value) |byte| {
        if (!referenceFieldValueByte(byte)) return null;
    }

    var accepts_trailers = false;
    var member_start: usize = 0;
    var index: usize = 0;
    var quoted = false;
    while (index <= value.len) : (index += 1) {
        if (index == value.len or (!quoted and value[index] == ',')) {
            const member = referenceTrimOws(value[member_start..index]);
            if (member.len != 0) {
                const member_accepts = referenceMember(member) orelse return null;
                accepts_trailers = accepts_trailers or member_accepts;
            }
            member_start = index + 1;
            continue;
        }
        if (!quoted and value[index] == '"') {
            quoted = true;
        } else if (quoted and value[index] == '\\') {
            if (index + 1 < value.len) index += 1;
        } else if (quoted and value[index] == '"') {
            quoted = false;
        }
    }
    return accepts_trailers;
}

fn referenceMember(member: []const u8) ?bool {
    var index: usize = 0;
    const name = referenceToken(member, &index) orelse return null;
    referenceSkipOws(member, &index);
    if (referenceEqlIgnoreCase(name, "trailers")) {
        return if (index == member.len) true else null;
    }

    while (index < member.len) {
        if (member[index] != ';') return null;
        index += 1;
        referenceSkipOws(member, &index);
        const parameter = referenceToken(member, &index) orelse return null;
        const is_weight = referenceEqlIgnoreCase(parameter, "q");
        if (!is_weight) referenceSkipOws(member, &index);
        if (index == member.len or member[index] != '=') return null;
        index += 1;

        if (is_weight) {
            return if (referenceQvalue(member[index..])) false else null;
        }
        referenceSkipOws(member, &index);
        if (index < member.len and member[index] == '"') {
            if (!referenceQuotedString(member, &index)) return null;
        } else if (referenceToken(member, &index) == null) {
            return null;
        }
        referenceSkipOws(member, &index);
    }
    return false;
}

fn referenceToken(value: []const u8, index: *usize) ?[]const u8 {
    const start = index.*;
    while (index.* < value.len and referenceTokenByte(value[index.*])) {
        index.* += 1;
    }
    if (index.* == start) return null;
    return value[start..index.*];
}

fn referenceQuotedString(value: []const u8, index: *usize) bool {
    if (index.* == value.len or value[index.*] != '"') return false;
    index.* += 1;
    while (index.* < value.len) {
        const byte = value[index.*];
        index.* += 1;
        if (byte == '"') return true;
        if (byte == '\\') {
            if (index.* == value.len or !referenceQuotedPairByte(value[index.*])) return false;
            index.* += 1;
        } else if (!referenceQuotedTextByte(byte)) {
            return false;
        }
    }
    return false;
}

fn referenceQvalue(value: []const u8) bool {
    if (value.len == 0 or (value[0] != '0' and value[0] != '1')) return false;
    if (value.len == 1) return true;
    if (value[1] != '.' or value.len > 5) return false;
    for (value[2..]) |byte| {
        if (byte < '0' or byte > '9') return false;
        if (value[0] == '1' and byte != '0') return false;
    }
    return true;
}

fn referenceTokenByte(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
}

fn referenceFieldValueByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn referenceQuotedTextByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == 0x21 or
        (byte >= 0x23 and byte <= 0x5b) or
        (byte >= 0x5d and byte <= 0x7e) or byte >= 0x80;
}

fn referenceQuotedPairByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn referenceEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        const left_lower = if (left_byte >= 'A' and left_byte <= 'Z') left_byte + 32 else left_byte;
        const right_lower = if (right_byte >= 'A' and right_byte <= 'Z')
            right_byte + 32
        else
            right_byte;
        if (left_lower != right_lower) return false;
    }
    return true;
}

fn referenceTrimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    var end = value.len;
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    return value[start..end];
}

fn referenceSkipOws(value: []const u8, index: *usize) void {
    while (index.* < value.len and
        (value[index.*] == ' ' or value[index.*] == '\t'))
    {
        index.* += 1;
    }
}

fn analyzeRequest(input: []const u8) !Result {
    const limits = @import("limits.zig").standard_request_head_limits;
    const Parser = request_head.Decoder(limits);
    var parser = Parser.init();
    const decoded = parser.feed(input);
    _ = switch (decoded.state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    return analyze(parser.fields(), parser.bytes());
}

fn analyzeRawValue(value: []const u8) Result {
    const field = request_head.Field{
        .name = .{ .offset = 0, .length = 2 },
        .raw_value = .{ .offset = 2, .length = @intCast(value.len) },
        .value = .{ .offset = 2, .length = @intCast(value.len) },
    };
    var bytes: [514]u8 = undefined;
    std.debug.assert(value.len <= bytes.len - 2);
    @memcpy(bytes[0..2], "TE");
    @memcpy(bytes[2 .. value.len + 2], value);
    return analyze(&.{field}, bytes[0 .. value.len + 2]);
}

fn expectAccepted(input: []const u8, expected: bool) !void {
    const analysis = switch (try analyzeRequest(input)) {
        .accepted => |analysis| analysis,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected, analysis.accepts_trailers);
}

fn expectRejected(input: []const u8) !void {
    try expectRejection(try analyzeRequest(input));
}

fn expectRawAccepted(value: []const u8, expected: bool) !void {
    const analysis = switch (analyzeRawValue(value)) {
        .accepted => |analysis| analysis,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(expected, analysis.accepts_trailers);
}

fn expectRawRejected(value: []const u8) !void {
    try expectRejection(analyzeRawValue(value));
}

fn expectRejection(result: Result) !void {
    const rejection = switch (result) {
        .rejected => |rejection| rejection,
        .accepted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(Status.bad_request, rejection.status);
    try std.testing.expect(rejection.close);
}
