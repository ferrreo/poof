const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;
pub const segments_standard_max: usize = 1000;
pub const segments_hard_max: usize = 4096;

pub const SegmentLimitIssue = enum(u8) {
    zero,
    above_hard_max,
};

pub const Rejection = struct {
    status: Status = .bad_request,
    close: bool = true,
};

pub const ParseResult = union(enum) {
    ready: Query,
    rejected: Rejection,
};

pub const Query = struct {
    raw: []const u8,
    segments_count: u16,
    fields_count: u16,

    pub fn iterator(self: Query) FieldIterator {
        return .{ .raw = self.raw, .done = self.raw.len == 0 };
    }
};

pub const Pair = struct {
    name: Component,
    value: Component,
};

pub const Component = struct {
    encoded: []const u8,

    pub fn decodedIterator(self: Component) DecodedIterator {
        return .{ .encoded = self.encoded };
    }

    pub fn decodedLength(self: Component) usize {
        var decoded = self.decodedIterator();
        var length: usize = 0;
        while (decoded.next() != null) : (length += 1) {}
        return length;
    }

    pub fn eqlDecoded(self: Component, expected: []const u8) bool {
        var decoded = self.decodedIterator();
        for (expected) |wanted| {
            const actual = decoded.next() orelse return false;
            if (actual != wanted) return false;
        }
        return decoded.next() == null;
    }
};

pub const DecodedIterator = struct {
    encoded: []const u8,
    index: usize = 0,

    pub fn next(self: *DecodedIterator) ?u8 {
        if (self.index == self.encoded.len) return null;
        const byte = self.encoded[self.index];
        self.index += 1;
        if (byte == '+') return ' ';
        if (byte != '%') return byte;

        std.debug.assert(self.encoded.len - self.index >= 2);
        const high = hexValue(self.encoded[self.index]);
        const low = hexValue(self.encoded[self.index + 1]);
        std.debug.assert(high < 16);
        std.debug.assert(low < 16);
        self.index += 2;
        return (high << 4) | low;
    }
};

pub const FieldIterator = struct {
    raw: []const u8,
    index: usize = 0,
    done: bool = false,

    pub fn next(self: *FieldIterator) ?Pair {
        while (!self.done) {
            std.debug.assert(self.index <= self.raw.len);
            const start = self.index;
            var end = start;
            while (end < self.raw.len and self.raw[end] != '&') : (end += 1) {}
            if (end == self.raw.len) {
                self.done = true;
            } else {
                self.index = end + 1;
            }

            const segment = self.raw[start..end];
            if (segment.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, segment, '=');
            const name_end = equals orelse segment.len;
            const value_start = if (equals) |position| position + 1 else segment.len;
            return .{
                .name = .{ .encoded = segment[0..name_end] },
                .value = .{ .encoded = segment[value_start..] },
            };
        }
        return null;
    }
};

pub fn segmentLimitIssue(segments_max: usize) ?SegmentLimitIssue {
    if (segments_max == 0) return .zero;
    if (segments_max > segments_hard_max) return .above_hard_max;
    return null;
}

pub fn parse(comptime segments_max: usize, raw: []const u8) ParseResult {
    comptime validateSegmentLimit(segments_max);
    if (raw.len == 0) return ready(raw, 0, 0);

    var segments: usize = 1;
    var fields: usize = 0;
    var segment_nonempty = false;
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == ';') return reject();
        if (byte == '%') {
            if (raw.len - index < 3) return reject();
            if (hexValue(raw[index + 1]) >= 16 or hexValue(raw[index + 2]) >= 16) {
                return reject();
            }
            segment_nonempty = true;
            index += 3;
            continue;
        }
        if (byte != '/' and byte != '?' and !syntax.isUriPchar(byte)) return reject();
        if (byte == '&') {
            if (segment_nonempty) fields += 1;
            segment_nonempty = false;
            if (segments == segments_max) return reject();
            segments += 1;
        } else {
            segment_nonempty = true;
        }
        index += 1;
    }
    if (segment_nonempty) fields += 1;
    return ready(raw, segments, fields);
}

fn validateSegmentLimit(comptime segments_max: usize) void {
    if (segments_max == 0) @compileError("query segment limit must be nonzero");
    if (segments_max > segments_hard_max) {
        @compileError("query segment limit exceeds 4096");
    }
}

fn ready(raw: []const u8, segments: usize, fields: usize) ParseResult {
    std.debug.assert(segments <= segments_hard_max);
    std.debug.assert(fields <= segments);
    return .{ .ready = .{
        .raw = raw,
        .segments_count = @intCast(segments),
        .fields_count = @intCast(fields),
    } };
}

fn reject() ParseResult {
    return .{ .rejected = .{} };
}

fn hexValue(byte: u8) u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => std.math.maxInt(u8),
    };
}

test "empty and separator-only queries count every segment" {
    try expectCounts(segments_standard_max, "", 0, 0);
    try expectCounts(segments_standard_max, "&", 2, 0);
    try expectCounts(segments_standard_max, "&&", 3, 0);
    try expectCounts(segments_standard_max, "&a&&b&", 5, 2);
    try expectCounts(3, "&&", 3, 0);
    try expectRejected(3, "&&&");
}

test "standard and hard segment ceilings are inclusive" {
    try std.testing.expectEqual(@as(?SegmentLimitIssue, .zero), segmentLimitIssue(0));
    try std.testing.expectEqual(@as(?SegmentLimitIssue, null), segmentLimitIssue(1));
    try std.testing.expectEqual(
        @as(?SegmentLimitIssue, null),
        segmentLimitIssue(segments_hard_max),
    );
    try std.testing.expectEqual(
        @as(?SegmentLimitIssue, .above_hard_max),
        segmentLimitIssue(segments_hard_max + 1),
    );

    var standard_limit = [_]u8{'&'} ** (segments_standard_max - 1);
    try expectCounts(segments_standard_max, &standard_limit, segments_standard_max, 0);
    var standard_over = [_]u8{'&'} ** segments_standard_max;
    try expectRejected(segments_standard_max, &standard_over);
    var hard_limit = [_]u8{'&'} ** (segments_hard_max - 1);
    try expectCounts(segments_hard_max, &hard_limit, segments_hard_max, 0);
    var hard_over = [_]u8{'&'} ** segments_hard_max;
    try expectRejected(segments_hard_max, &hard_over);
}

test "pairs retain first equals empty names repeats and order" {
    const raw = "=x&=&name&name=one&name=two=a&&";
    const query = try expectReady(segments_standard_max, raw);
    try std.testing.expectEqualStrings(raw, query.raw);
    try std.testing.expectEqual(@as(u16, 7), query.segments_count);
    try std.testing.expectEqual(@as(u16, 5), query.fields_count);

    const expected = [_][2][]const u8{
        .{ "", "x" },
        .{ "", "" },
        .{ "name", "" },
        .{ "name", "one" },
        .{ "name", "two=a" },
    };
    var fields = query.iterator();
    for (expected) |wanted| {
        const pair = fields.next().?;
        try std.testing.expectEqualStrings(wanted[0], pair.name.encoded);
        try std.testing.expectEqualStrings(wanted[1], pair.value.encoded);
    }
    try std.testing.expectEqual(@as(?Pair, null), fields.next());
}

test "component decoding handles plus percent case and arbitrary bytes" {
    const query = try expectReady(
        segments_standard_max,
        "na+me=%fF%2b+%00&semi=%3B&lower=%3b",
    );
    var fields = query.iterator();
    const first = fields.next().?;
    try std.testing.expect(first.name.eqlDecoded("na me"));
    try std.testing.expect(first.value.eqlDecoded("\xff+ \x00"));
    try std.testing.expectEqual(@as(usize, 4), first.value.decodedLength());

    const upper = fields.next().?;
    const lower = fields.next().?;
    try std.testing.expect(upper.value.eqlDecoded(";"));
    try std.testing.expect(lower.value.eqlDecoded(";"));
}

test "malformed escapes and non-URI query bytes reject" {
    const malformed = [_][]const u8{
        "%",
        "%0",
        "%GG",
        "a%2x",
        "raw;semi",
        "raw[bracket]",
        "raw|pipe",
        "nul\x00",
        "obs\x80",
    };
    for (malformed) |raw| try expectRejected(segments_standard_max, raw);

    const backing = "%41";
    try expectRejected(segments_standard_max, backing[0..1]);
    const query = try expectReady(segments_standard_max, "a=b=c");
    var fields = query.iterator();
    try std.testing.expectEqualStrings("b=c", fields.next().?.value.encoded);
}

test "query validator and decoded iterators fuzz differentially" {
    try std.testing.fuzz({}, fuzzQuery, .{ .corpus = &query_fuzz_corpus });
}

const query_fuzz_corpus = struct {
    const empty = fuzz_support.smithInput("");
    const empty_segments = fuzz_support.smithInput("&&");
    const repeated = fuzz_support.smithInput("a=b&a=c");
    const encoded = fuzz_support.smithInput("%3B=%ff+%00");
    const bad_escape = fuzz_support.smithInput("%");
    const semicolon = fuzz_support.smithInput("raw;semi");
    const non_uri = fuzz_support.smithInput("raw[bracket]");

    const values = [_][]const u8{
        &empty,
        &empty_segments,
        &repeated,
        &encoded,
        &bad_escape,
        &semicolon,
        &non_uri,
    };
}.values;

fn fuzzQuery(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const raw = storage[0..smith.slice(&storage)];
    const expected = referenceValidate(raw, 16);
    switch (parse(16, raw)) {
        .rejected => |rejection| {
            try std.testing.expect(expected == null);
            try std.testing.expectEqual(Status.bad_request, rejection.status);
            try std.testing.expect(rejection.close);
        },
        .ready => |query| {
            const counts = expected orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(counts.segments, query.segments_count);
            try std.testing.expectEqual(counts.fields, query.fields_count);
            try checkIterators(query);
        },
    }
}

const Counts = struct {
    segments: u16,
    fields: u16,
};

fn referenceValidate(raw: []const u8, segments_max: usize) ?Counts {
    if (raw.len == 0) return .{ .segments = 0, .fields = 0 };
    var segments: usize = 1;
    var fields: usize = 0;
    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == ';') return null;
        if (raw[index] == '%') {
            if (raw.len - index < 3) return null;
            if (!referenceHex(raw[index + 1]) or !referenceHex(raw[index + 2])) return null;
            index += 2;
        } else if (raw[index] != '/' and raw[index] != '?' and
            !syntax.isUriPchar(raw[index]))
        {
            return null;
        } else if (raw[index] == '&') {
            if (index != segment_start) fields += 1;
            segment_start = index + 1;
            segments += 1;
            if (segments > segments_max) return null;
        }
    }
    if (segment_start != raw.len) fields += 1;
    return .{ .segments = @intCast(segments), .fields = @intCast(fields) };
}

fn referenceHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'F') or (byte >= 'a' and byte <= 'f');
}

fn checkIterators(query: Query) !void {
    var fields = query.iterator();
    var fields_count: usize = 0;
    var segment_start: usize = 0;
    while (segment_start <= query.raw.len) {
        const segment_end = std.mem.indexOfScalarPos(
            u8,
            query.raw,
            segment_start,
            '&',
        ) orelse query.raw.len;
        const segment = query.raw[segment_start..segment_end];
        if (segment.len == 0) {
            if (segment_end == query.raw.len) break;
            segment_start = segment_end + 1;
            continue;
        }
        const pair = fields.next() orelse return error.TestUnexpectedResult;
        const equals = std.mem.indexOfScalar(u8, segment, '=');
        const name_end = equals orelse segment.len;
        const value_start = if (equals) |position| position + 1 else segment.len;
        try std.testing.expectEqualStrings(segment[0..name_end], pair.name.encoded);
        try std.testing.expectEqualStrings(segment[value_start..], pair.value.encoded);
        fields_count += 1;
        try checkDecoded(pair.name);
        try checkDecoded(pair.value);
        if (segment_end == query.raw.len) break;
        segment_start = segment_end + 1;
    }
    try std.testing.expect(fields.next() == null);
    try std.testing.expectEqual(query.fields_count, fields_count);
}

fn checkDecoded(component: Component) !void {
    var decoded = component.decodedIterator();
    var encoded_index: usize = 0;
    var decoded_length: usize = 0;
    while (encoded_index < component.encoded.len) : (decoded_length += 1) {
        const byte = component.encoded[encoded_index];
        const expected = if (byte == '+')
            ' '
        else if (byte == '%')
            referenceDecodedEscape(component.encoded, &encoded_index)
        else
            byte;
        encoded_index += 1;
        try std.testing.expectEqual(expected, decoded.next().?);
    }
    try std.testing.expect(decoded.next() == null);
    try std.testing.expectEqual(component.decodedLength(), decoded_length);
}

fn referenceDecodedEscape(encoded: []const u8, index: *usize) u8 {
    std.debug.assert(encoded.len - index.* >= 3);
    const high = referenceHexValue(encoded[index.* + 1]);
    const low = referenceHexValue(encoded[index.* + 2]);
    index.* += 2;
    return (high << 4) | low;
}

fn referenceHexValue(byte: u8) u8 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    std.debug.assert(byte >= 'a');
    std.debug.assert(byte <= 'f');
    return byte - 'a' + 10;
}

fn expectCounts(
    comptime segments_max: usize,
    raw: []const u8,
    segments: usize,
    fields: usize,
) !void {
    const query = try expectReady(segments_max, raw);
    try std.testing.expectEqual(segments, query.segments_count);
    try std.testing.expectEqual(fields, query.fields_count);
}

fn expectReady(comptime segments_max: usize, raw: []const u8) !Query {
    return switch (parse(segments_max, raw)) {
        .ready => |query| query,
        .rejected => error.TestUnexpectedResult,
    };
}

fn expectRejected(comptime segments_max: usize, raw: []const u8) !void {
    const rejection = switch (parse(segments_max, raw)) {
        .rejected => |rejection| rejection,
        .ready => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(Status.bad_request, rejection.status);
    try std.testing.expect(rejection.close);
}
