const std = @import("std");
const syntax = @import("../http1/syntax.zig");

pub const segments_standard_max: usize = 1000;
pub const segments_hard_max: usize = 4096;

pub const SegmentLimitIssue = enum(u8) {
    zero,
    above_hard_max,
};

pub const Source = enum(u8) {
    query,
    form,
};

pub const Fragment = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) Fragment {
        return .{ .bytes = bytes };
    }
};

pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Table = struct {
    source: Source,
    segments_count: u16,
    /// Pairs and their bytes borrow the two caller-provided storage slices.
    pairs: []const Pair,
};

pub const ParseError = error{
    MalformedEncoding,
    InvalidCharacter,
    TooManySegments,
    InsufficientPairStorage,
    InsufficientByteStorage,
    InvalidUtf8,
};

pub fn segmentLimitIssue(segments_max: usize) ?SegmentLimitIssue {
    if (segments_max == 0) return .zero;
    if (segments_max > segments_hard_max) return .above_hard_max;
    return null;
}

/// Storage contents are unspecified on error and may be reused immediately.
pub fn parse(
    comptime segments_max: usize,
    source: Source,
    fragments: []const Fragment,
    pair_storage: []Pair,
    byte_storage: []u8,
) ParseError!Table {
    comptime validateSegmentLimit(segments_max);
    var parser = Parser{
        .source = source,
        .segments_max = segments_max,
        .pairs = pair_storage,
        .bytes = byte_storage,
    };
    for (fragments) |fragment| try parser.feed(fragment.bytes);
    return parser.finish();
}

const Parser = struct {
    source: Source,
    segments_max: usize,
    pairs: []Pair,
    bytes: []u8,
    bytes_used: usize = 0,
    pairs_used: usize = 0,
    segments: usize = 0,
    segment_start: usize = 0,
    name_end: ?usize = null,
    segment_nonempty: bool = false,
    escape_digits: u2 = 0,
    escape_high: u8 = 0,

    // Keep the hot parser loop independent of unrelated comptime code layout.
    fn feed(self: *Parser, input: []const u8) align(64) ParseError!void {
        for (input) |byte| try self.feedByte(byte);
    }

    fn feedByte(self: *Parser, byte: u8) ParseError!void {
        if (self.escape_digits != 0) return self.feedEscape(byte);
        if (self.segments == 0) self.segments = 1;
        if (byte == ';') return error.InvalidCharacter;
        if (byte == '%') {
            self.segment_nonempty = true;
            self.escape_digits = 1;
            return;
        }
        if (self.source == .query and !isQueryByte(byte)) {
            return error.InvalidCharacter;
        }
        if (byte == '&') {
            try self.finishSegment();
            if (self.segments == self.segments_max) return error.TooManySegments;
            self.segments += 1;
            return;
        }
        self.segment_nonempty = true;
        if (byte == '=' and self.name_end == null) {
            self.name_end = self.bytes_used;
            return;
        }
        try self.append(if (byte == '+') ' ' else byte);
    }

    fn feedEscape(self: *Parser, byte: u8) ParseError!void {
        const digit = hexValue(byte) orelse return error.MalformedEncoding;
        if (self.escape_digits == 1) {
            self.escape_high = digit;
            self.escape_digits = 2;
            return;
        }
        try self.append((self.escape_high << 4) | digit);
        self.escape_digits = 0;
    }

    fn append(self: *Parser, byte: u8) ParseError!void {
        if (self.bytes_used == self.bytes.len) return error.InsufficientByteStorage;
        self.bytes[self.bytes_used] = byte;
        self.bytes_used += 1;
    }

    fn finishSegment(self: *Parser) ParseError!void {
        if (self.segment_nonempty) {
            if (self.pairs_used == self.pairs.len) {
                return error.InsufficientPairStorage;
            }
            const value_start = self.name_end orelse self.bytes_used;
            self.pairs[self.pairs_used] = .{
                .name = self.bytes[self.segment_start..value_start],
                .value = self.bytes[value_start..self.bytes_used],
            };
            self.pairs_used += 1;
        }
        self.segment_start = self.bytes_used;
        self.name_end = null;
        self.segment_nonempty = false;
    }

    fn finish(self: *Parser) ParseError!Table {
        if (self.escape_digits != 0) return error.MalformedEncoding;
        try self.finishSegment();
        const table = Table{
            .source = self.source,
            .segments_count = @intCast(self.segments),
            .pairs = self.pairs[0..self.pairs_used],
        };
        if (self.source == .form) try validateFormUtf8(table.pairs);
        return table;
    }
};

fn validateSegmentLimit(comptime segments_max: usize) void {
    if (segmentLimitIssue(segments_max)) |issue| switch (issue) {
        .zero => @compileError("flat segment limit must be nonzero"),
        .above_hard_max => @compileError("flat segment limit exceeds 4096"),
    };
}

fn validateFormUtf8(pairs: []const Pair) ParseError!void {
    for (pairs) |pair| {
        if (!std.unicode.utf8ValidateSlice(pair.name)) return error.InvalidUtf8;
        if (!std.unicode.utf8ValidateSlice(pair.value)) return error.InvalidUtf8;
    }
}

fn isQueryByte(byte: u8) bool {
    return byte == '/' or byte == '?' or syntax.isUriPchar(byte);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'F' => byte - 'A' + 10,
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}
