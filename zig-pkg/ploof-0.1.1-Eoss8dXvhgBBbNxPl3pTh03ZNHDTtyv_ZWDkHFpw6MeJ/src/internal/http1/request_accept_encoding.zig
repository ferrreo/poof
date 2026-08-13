const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const request_head = @import("request_head.zig");
const syntax = @import("syntax.zig");

pub const coding_members_max: u8 = 64;
pub const empty_members_max: u8 = 32;
pub const weight_max: u16 = 1000;

pub const Preferences = struct {
    gzip: u16 = 0,
    identity: u16 = weight_max,
};

pub const Result = union(enum) {
    accepted: Preferences,
    rejected: request_head.Rejection,
};

const ParseError = error{Invalid};

const Seen = struct {
    name: []const u8,
    weight: u16,
};

const Scan = struct {
    seen: [coding_members_max]Seen = undefined,
    members: u8 = 0,
    unique: u8 = 0,
    empty_members: u8 = 0,
    gzip: ?u16 = null,
    identity: ?u16 = null,
    wildcard: ?u16 = null,
};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Result {
    var scan = Scan{};
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), "accept-encoding")) continue;
        scanFieldValue(&scan, field.value.slice(bytes)) catch return reject();
    }
    return .{ .accepted = preferences(scan) };
}

fn scanFieldValue(scan: *Scan, value: []const u8) ParseError!void {
    if (!syntax.isFieldValue(value)) return error.Invalid;
    var cursor: usize = 0;
    while (true) {
        skipOws(value, &cursor);
        const name_start = cursor;
        while (cursor < value.len and syntax.isTokenByte(value[cursor])) cursor += 1;
        if (cursor == name_start) {
            try recordEmpty(scan);
        } else {
            const name = value[name_start..cursor];
            const weight = try consumeWeight(value, &cursor);
            try recordMember(scan, name, weight);
        }
        skipOws(value, &cursor);
        if (cursor == value.len) return;
        if (value[cursor] != ',') return error.Invalid;
        cursor += 1;
    }
}

fn consumeWeight(value: []const u8, cursor: *usize) ParseError!u16 {
    skipOws(value, cursor);
    if (cursor.* == value.len or value[cursor.*] == ',') return weight_max;
    if (value[cursor.*] != ';') return error.Invalid;
    cursor.* += 1;
    skipOws(value, cursor);
    if (cursor.* == value.len or syntax.asciiLower(value[cursor.*]) != 'q') {
        return error.Invalid;
    }
    cursor.* += 1;
    if (cursor.* == value.len or value[cursor.*] != '=') return error.Invalid;
    cursor.* += 1;
    const weight = try consumeQvalue(value, cursor);
    skipOws(value, cursor);
    if (cursor.* != value.len and value[cursor.*] != ',') return error.Invalid;
    return weight;
}

fn consumeQvalue(value: []const u8, cursor: *usize) ParseError!u16 {
    if (cursor.* == value.len) return error.Invalid;
    const whole = value[cursor.*];
    if (whole != '0' and whole != '1') return error.Invalid;
    cursor.* += 1;
    if (cursor.* == value.len or value[cursor.*] != '.') {
        return if (whole == '1') weight_max else 0;
    }
    cursor.* += 1;

    var weight: u16 = if (whole == '1') weight_max else 0;
    var place: u16 = 100;
    var digits: u8 = 0;
    while (cursor.* < value.len and digits < 3) : (digits += 1) {
        const byte = value[cursor.*];
        if (byte < '0' or byte > '9') break;
        if (whole == '1' and byte != '0') return error.Invalid;
        if (whole == '0') weight += @as(u16, byte - '0') * place;
        place /= 10;
        cursor.* += 1;
    }
    return weight;
}

fn recordEmpty(scan: *Scan) ParseError!void {
    if (scan.empty_members == empty_members_max) return error.Invalid;
    scan.empty_members += 1;
}

fn recordMember(scan: *Scan, name: []const u8, weight: u16) ParseError!void {
    if (scan.members == coding_members_max) return error.Invalid;
    scan.members += 1;
    for (scan.seen[0..scan.unique]) |seen| {
        if (!syntax.eqlIgnoreCase(seen.name, name)) continue;
        if (seen.weight != weight) return error.Invalid;
        return;
    }
    scan.seen[scan.unique] = .{ .name = name, .weight = weight };
    scan.unique += 1;
    if (syntax.eqlIgnoreCase(name, "gzip")) scan.gzip = weight;
    if (syntax.eqlIgnoreCase(name, "identity")) scan.identity = weight;
    if (std.mem.eql(u8, name, "*")) scan.wildcard = weight;
}

fn preferences(scan: Scan) Preferences {
    const gzip: u16 = scan.gzip orelse scan.wildcard orelse 0;
    const identity: u16 = scan.identity orelse if (scan.wildcard == 0) 0 else weight_max;
    return .{ .gzip = gzip, .identity = identity };
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}

fn reject() Result {
    return .{ .rejected = .{ .status = .bad_request } };
}

const Decoder = request_head.Decoder(@import("limits.zig").standard_request_head_limits);
const request_prefix = "GET / HTTP/1.1\r\nHost: example.test\r\n";

test "missing and bounded empty Accept-Encoding lists select identity" {
    try expectAccepted(request_prefix ++ "\r\n", .{});
    try expectAccepted(request_prefix ++ "Accept-Encoding:\r\n\r\n", .{});
    try expectAccepted(request_prefix ++ "Accept-Encoding: , \t,\r\n\r\n", .{});

    const accepted = "," ** (empty_members_max - 1);
    try expectRawAccepted(accepted, .{});
    const rejected_value = "," ** empty_members_max;
    try expectRawRejected(rejected_value);
}

test "maps every representable q weight exactly" {
    var value = "gzip;q=0.000".*;
    for (0..weight_max + 1) |weight| {
        value[7] = if (weight == weight_max) '1' else '0';
        const fraction = if (weight == weight_max) 0 else weight;
        value[9] = '0' + @as(u8, @intCast(fraction / 100));
        value[10] = '0' + @as(u8, @intCast((fraction / 10) % 10));
        value[11] = '0' + @as(u8, @intCast(fraction % 10));
        try expectRawAccepted(&value, .{ .gzip = @intCast(weight) });
    }
}

test "accepts only strict q grammar" {
    const accepted = [_]struct { value: []const u8, weight: u16 }{
        .{ .value = "gzip", .weight = 1000 },
        .{ .value = "gzip;q=0", .weight = 0 },
        .{ .value = "gzip;q=0.", .weight = 0 },
        .{ .value = "gzip;q=0.1", .weight = 100 },
        .{ .value = "gzip;q=0.01", .weight = 10 },
        .{ .value = "gzip;q=0.001", .weight = 1 },
        .{ .value = "gzip;q=1.", .weight = 1000 },
        .{ .value = "gzip ;\tQ=1.000 \t", .weight = 1000 },
    };
    for (accepted) |case| try expectRawAccepted(case.value, .{ .gzip = case.weight });

    const rejected_values = [_][]const u8{
        "gzip;q=",      "gzip;q=.5",    "gzip;q=00",    "gzip;q=0.0000",
        "gzip;q=1.001", "gzip;q=2",     "gzip;q=\"0\"", "gzip;q =0.5",
        "gzip;q= 0.5",  "gzip;level=1", "gzip;q=0;x=1", "gzip;q=0;q=0",
        "gzip;",        "gzip ; q",     "gzip ; =0",    "gzip q=0",
    };
    for (rejected_values) |value| try expectRawRejected(value);
}

test "applies explicit wildcard and identity precedence" {
    const cases = [_]struct { value: []const u8, expected: Preferences }{
        .{ .value = "br", .expected = .{} },
        .{ .value = "*;q=0.5", .expected = .{ .gzip = 500 } },
        .{ .value = "*;q=0", .expected = .{ .identity = 0 } },
        .{ .value = "*;q=0, gzip;q=0.7", .expected = .{ .gzip = 700, .identity = 0 } },
        .{ .value = "*;q=0, identity;q=0.2", .expected = .{ .identity = 200 } },
        .{ .value = "*;q=0.5, gzip;q=0.2", .expected = .{ .gzip = 200 } },
        .{ .value = "*;q=0.5, identity;q=0", .expected = .{ .gzip = 500, .identity = 0 } },
        .{ .value = "gzip;q=0.4, identity;q=0.8", .expected = .{
            .gzip = 400,
            .identity = 800,
        } },
    };
    for (cases) |case| try expectRawAccepted(case.value, case.expected);
}

test "combines fields and rejects conflicting duplicate codings" {
    try expectAccepted(
        request_prefix ++
            "Accept-Encoding: gzip;q=0.6, br\r\n" ++
            "aCcEpT-EnCoDiNg: identity;q=0.2\r\n\r\n",
        .{ .gzip = 600, .identity = 200 },
    );
    try expectAccepted(
        request_prefix ++
            "Accept-Encoding: identity;q=0.2\r\n" ++
            "Accept-Encoding: br, gzip;q=0.6\r\n\r\n",
        .{ .gzip = 600, .identity = 200 },
    );
    try expectRawAccepted("gzip;q=0.5, GZIP;q=0.500", .{ .gzip = 500 });
    try expectRawAccepted("br;q=0.2, BR;q=0.200", .{});
    const conflicts = [_][]const u8{
        "gzip;q=0.5,gzip;q=0.4",
        "identity,IDENTITY;q=0",
        "*;q=0,*;q=1",
        "br;q=0.2,BR;q=0.3",
    };
    for (conflicts) |value| try expectRawRejected(value);
}

test "bounds coding work and rejects malformed or hostile values" {
    const accepted = "br," ** (coding_members_max - 1) ++ "br";
    try expectRawAccepted(accepted, .{});
    const too_many = "br," ** coding_members_max ++ "br";
    try expectRawRejected(too_many);

    const malformed = [_][]const u8{
        ";",           "gzip,,;",    "gzip deflate", "gzip,\x00br",
        "gzip\x1f",    "gzip\x7f",   "gzip\x80",     "gzip,(br)",
        "gzip;\x80=q", "gzip;q=0,;", "\"gzip\"",     "gzip=q",
    };
    for (malformed) |value| try expectRawRejected(value);
}

test "Accept-Encoding parser fuzzes differentially against independent grammar" {
    try std.testing.fuzz({}, fuzzAcceptEncoding, .{ .corpus = &fuzz_corpus });
}

const fuzz_corpus = struct {
    const missing = fuzzCase("", "", 0);
    const gzip = fuzzCase("gzip;q=0.5", "", 1);
    const fields = fuzzCase("gzip;q=0.7", "identity;q=0.2", 3);
    const wildcard = fuzzCase("*;q=0", "gzip;q=1", 4);
    const conflict = fuzzCase("br;q=0.1", "BR;q=0.2", 3);
    const malformed = fuzzCase("gzip;q=1.001", "", 1);
    const control = fuzzCase("gzip\x00", "identity", 3);

    const values = [_][]const u8{
        &missing,
        &gzip,
        &fields,
        &wildcard,
        &conflict,
        &malformed,
        &control,
    };
}.values;

fn fuzzAcceptEncoding(_: void, smith: *std.testing.Smith) !void {
    var first_storage: [256]u8 = undefined;
    const first = first_storage[0..smith.slice(&first_storage)];
    var second_storage: [256]u8 = undefined;
    const second = second_storage[0..smith.slice(&second_storage)];
    const shape = smith.valueRangeAtMost(u8, 0, 5);
    var built = FuzzFields{};
    built.init(first, second, shape);
    const actual = analyze(built.fields, built.bytes);
    const expected = @import("request_accept_encoding_reference.zig").analyze(
        built.fields,
        built.bytes,
    );
    try expectDifferential(actual, expected);
}

const FuzzFields = struct {
    bytes_storage: ["Accept-Encoding".len + 512 + 1]u8 = undefined,
    fields_storage: [3]request_head.Field = undefined,
    bytes: []const u8 = &.{},
    fields: []const request_head.Field = &.{},

    fn init(self: *FuzzFields, first: []const u8, second: []const u8, shape: u8) void {
        const name = "Accept-Encoding";
        @memcpy(self.bytes_storage[0..name.len], name);
        const first_offset = name.len;
        @memcpy(self.bytes_storage[first_offset..][0..first.len], first);
        const second_offset = first_offset + first.len;
        @memcpy(self.bytes_storage[second_offset..][0..second.len], second);
        const other_offset = second_offset + second.len;
        self.bytes_storage[other_offset] = 'x';
        self.bytes = self.bytes_storage[0 .. other_offset + 1];
        self.fields = selectFuzzFields(
            self,
            first_offset,
            first.len,
            second_offset,
            second.len,
            shape,
        );
    }
};

fn selectFuzzFields(
    built: *FuzzFields,
    first_offset: usize,
    first_length: usize,
    second_offset: usize,
    second_length: usize,
    shape: u8,
) []const request_head.Field {
    const name_length = "Accept-Encoding".len;
    const first = makeField(0, name_length, first_offset, first_length);
    const second = makeField(0, name_length, second_offset, second_length);
    const other = makeField(second_offset + second_length, 1, first_offset, first_length);
    built.fields_storage = switch (shape) {
        0 => .{ other, undefined, undefined },
        1 => .{ first, undefined, undefined },
        2 => .{ second, undefined, undefined },
        3 => .{ first, second, undefined },
        4 => .{ first, other, second },
        5 => .{ other, first, undefined },
        else => unreachable,
    };
    const count: usize = switch (shape) {
        0, 1, 2, 5 => 1,
        3 => 2,
        4 => 3,
        else => unreachable,
    };
    return built.fields_storage[0..count];
}

fn makeField(
    name_offset: usize,
    name_length: usize,
    value_offset: usize,
    value_length: usize,
) request_head.Field {
    const value = request_head.Span{
        .offset = @intCast(value_offset),
        .length = @intCast(value_length),
    };
    return .{
        .name = .{ .offset = @intCast(name_offset), .length = @intCast(name_length) },
        .raw_value = value,
        .value = value,
    };
}

fn expectDifferential(actual: Result, expected: anytype) !void {
    switch (actual) {
        .rejected => |rejection| {
            try std.testing.expect(expected == .rejected);
            try std.testing.expectEqual(request_head.Status.bad_request, rejection.status);
            try std.testing.expect(rejection.close);
        },
        .accepted => |accepted| {
            if (expected != .accepted) return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected.accepted.gzip, accepted.gzip);
            try std.testing.expectEqual(expected.accepted.identity, accepted.identity);
        },
    }
}

fn fuzzCase(
    comptime first: []const u8,
    comptime second: []const u8,
    comptime shape: u64,
) [first.len + second.len + 16]u8 {
    const first_input = fuzz_support.smithInput(first);
    const second_input = fuzz_support.smithInput(second);
    var input: [first.len + second.len + 16]u8 = undefined;
    @memcpy(input[0..first_input.len], &first_input);
    @memcpy(input[first_input.len..][0..second_input.len], &second_input);
    std.mem.writeInt(u64, input[input.len - 8 ..], shape, .little);
    return input;
}

fn analyzeRequest(input: []const u8) !Result {
    var decoder = Decoder.init();
    _ = switch (decoder.feed(input).state) {
        .ready => |head| head,
        else => return error.TestUnexpectedResult,
    };
    return analyze(decoder.fields(), decoder.bytes());
}

fn analyzeRawValue(value: []const u8) Result {
    var bytes: [2048]u8 = undefined;
    std.debug.assert(value.len <= bytes.len - "Accept-Encoding".len);
    @memcpy(bytes[0.."Accept-Encoding".len], "Accept-Encoding");
    @memcpy(bytes["Accept-Encoding".len..][0..value.len], value);
    const field = makeField(
        0,
        "Accept-Encoding".len,
        "Accept-Encoding".len,
        value.len,
    );
    return analyze(&.{field}, bytes[0 .. "Accept-Encoding".len + value.len]);
}

fn expectAccepted(input: []const u8, expected: Preferences) !void {
    const accepted = switch (try analyzeRequest(input)) {
        .accepted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualDeep(expected, accepted);
}

fn expectRawAccepted(value: []const u8, expected: Preferences) !void {
    const accepted = switch (analyzeRawValue(value)) {
        .accepted => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualDeep(expected, accepted);
}

fn expectRawRejected(value: []const u8) !void {
    const rejection = switch (analyzeRawValue(value)) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |result| result,
    };
    try std.testing.expectEqual(request_head.Status.bad_request, rejection.status);
    try std.testing.expect(rejection.close);
}
