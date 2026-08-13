const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");
pub const size_line_bytes_max: usize = 1024;
pub const standard_chunks_max: u32 = 65_536;
pub const Status = status_module.Status;
pub const Rejection = struct {
    status: Status,
    close: bool = true,
};
pub const Event = union(enum) {
    need_more,
    data: []const u8,
    trailers_begin,
    rejected: Rejection,
};
pub const FeedResult = struct {
    consumed: usize,
    event: Event,
};
const Phase = enum(u8) {
    size_line,
    data,
    delimiter,
    trailers,
    rejected,
};
const SizeStep = enum(u8) {
    progress,
    data_ready,
    trailers_begin,
    bad_request,
    payload_too_large,
};
const ChunkLineError = error{
    Invalid,
    Overflow,
};
pub fn Decoder(comptime chunks_max: u32) type {
    if (chunks_max == 0) @compileError("chunk count limit must be nonzero");
    return struct {
        const Self = @This();
        core: Core,
        pub fn init(encoded_wire_bytes_max: u64) Self {
            return .{ .core = Core.init(encoded_wire_bytes_max) };
        }
        pub fn wireBytesConsumed(self: *const Self) u64 {
            return self.core.encoded_wire_bytes;
        }
        pub fn chunksDecoded(self: *const Self) u32 {
            return self.core.chunks_count;
        }
        pub fn feed(self: *Self, input: []const u8) FeedResult {
            return self.core.feed(input, chunks_max, null, 0);
        }
        pub fn feedDecodedBounded(
            self: *Self,
            input: []const u8,
            decoded_bytes_remaining: u64,
            trailer_bytes_min: u64,
        ) FeedResult {
            return self.core.feed(
                input,
                chunks_max,
                decoded_bytes_remaining,
                trailer_bytes_min,
            );
        }
    };
}
const Core = struct {
    size_line: [size_line_bytes_max]u8 = undefined,
    size_line_length: u16 = 0,
    chunk_bytes_remaining: u64 = 0,
    encoded_wire_bytes: u64 = 0,
    encoded_wire_bytes_max: u64,
    chunks_count: u32 = 0,
    delimiter_index: u8 = 0,
    phase: Phase = .size_line,
    rejection_status: Status = .bad_request,
    fn init(encoded_wire_bytes_max: u64) Core {
        return .{ .encoded_wire_bytes_max = encoded_wire_bytes_max };
    }
    fn feed(
        self: *Core,
        input: []const u8,
        comptime chunks_max: u32,
        decoded_bytes_remaining: ?u64,
        trailer_bytes_min: u64,
    ) FeedResult {
        switch (self.phase) {
            .trailers => return trailersResult(0),
            .rejected => return self.rejectedResult(0),
            .size_line => if (!self.sizeLineCompletionFits(trailer_bytes_min)) {
                return self.fail(0, .payload_too_large);
            },
            .data, .delimiter => {},
        }
        var consumed: usize = 0;
        while (consumed < input.len) {
            switch (self.phase) {
                .size_line => {
                    if (!self.wireByteAvailable()) {
                        return self.fail(consumed, .payload_too_large);
                    }
                    self.encoded_wire_bytes += 1;
                    const step = self.consumeSizeByte(
                        input[consumed],
                        chunks_max,
                        decoded_bytes_remaining,
                        trailer_bytes_min,
                    );
                    consumed += 1;
                    switch (step) {
                        .progress => {
                            if (!self.sizeLineCompletionFits(trailer_bytes_min)) {
                                return self.fail(consumed, .payload_too_large);
                            }
                        },
                        .data_ready => {},
                        .trailers_begin => return trailersResult(consumed),
                        .bad_request => return self.fail(consumed, .bad_request),
                        .payload_too_large => {
                            return self.fail(consumed, .payload_too_large);
                        },
                    }
                },
                .data => return self.emitData(input, consumed),
                .delimiter => {
                    if (!self.wireByteAvailable()) {
                        return self.fail(consumed, .payload_too_large);
                    }
                    self.encoded_wire_bytes += 1;
                    const valid = self.consumeDelimiterByte(input[consumed]);
                    consumed += 1;
                    if (!valid) return self.fail(consumed, .bad_request);
                    if (self.phase == .size_line and
                        !self.sizeLineCompletionFits(trailer_bytes_min))
                    {
                        return self.fail(consumed, .payload_too_large);
                    }
                },
                .trailers => return trailersResult(consumed),
                .rejected => return self.rejectedResult(consumed),
            }
        }
        return .{ .consumed = consumed, .event = .need_more };
    }
    fn consumeSizeByte(
        self: *Core,
        byte: u8,
        comptime chunks_max: u32,
        decoded_bytes_remaining: ?u64,
        trailer_bytes_min: u64,
    ) SizeStep {
        const index: usize = self.size_line_length;
        std.debug.assert(index < self.size_line.len);
        self.size_line[index] = byte;
        self.size_line_length += 1;
        const length: usize = self.size_line_length;
        if (byte == '\n') {
            if (length < 2 or self.size_line[length - 2] != '\r') {
                return .bad_request;
            }
            return self.finishSizeLine(
                length - 2,
                chunks_max,
                decoded_bytes_remaining,
                trailer_bytes_min,
            );
        }
        if (length >= 2 and self.size_line[length - 2] == '\r') {
            return .bad_request;
        }
        if (length == self.size_line.len) return .bad_request;
        return .progress;
    }

    fn finishSizeLine(
        self: *Core,
        content_length: usize,
        comptime chunks_max: u32,
        decoded_bytes_remaining: ?u64,
        trailer_bytes_min: u64,
    ) SizeStep {
        const line = self.size_line[0..content_length];
        self.size_line_length = 0;
        const size = parseChunkLine(line) catch return .bad_request;

        if (size == 0) {
            if (!self.suffixFits(0, trailer_bytes_min)) return .payload_too_large;
            self.phase = .trailers;
            return .trailers_begin;
        }
        if (self.chunks_count == chunks_max) return .bad_request;
        if (decoded_bytes_remaining) |remaining| {
            if (size > remaining) return .payload_too_large;
        }
        if (!self.chunkCompletionFits(size, trailer_bytes_min)) {
            return .payload_too_large;
        }
        self.chunks_count += 1;
        self.chunk_bytes_remaining = size;
        self.phase = .data;
        return .data_ready;
    }

    fn emitData(self: *Core, input: []const u8, start: usize) FeedResult {
        const available: u64 = @intCast(input.len - start);
        const length_u64 = @min(available, self.chunk_bytes_remaining);
        const length: usize = @intCast(length_u64);
        std.debug.assert(length != 0);
        std.debug.assert(
            length_u64 <= self.encoded_wire_bytes_max - self.encoded_wire_bytes,
        );
        self.encoded_wire_bytes += length_u64;
        self.chunk_bytes_remaining -= length_u64;
        if (self.chunk_bytes_remaining == 0) {
            self.phase = .delimiter;
            self.delimiter_index = 0;
        }
        return .{
            .consumed = start + length,
            .event = .{ .data = input[start .. start + length] },
        };
    }

    fn consumeDelimiterByte(self: *Core, byte: u8) bool {
        const expected: u8 = if (self.delimiter_index == 0) '\r' else '\n';
        if (byte != expected) return false;
        self.delimiter_index += 1;
        if (self.delimiter_index == 2) {
            self.delimiter_index = 0;
            self.phase = .size_line;
        }
        return true;
    }

    fn suffixFits(self: *const Core, minimum: u64, trailer_bytes_min: u64) bool {
        if (self.encoded_wire_bytes > self.encoded_wire_bytes_max) return false;
        const remaining = self.encoded_wire_bytes_max - self.encoded_wire_bytes;
        if (minimum > remaining) return false;
        return trailer_bytes_min <= remaining - minimum;
    }

    fn sizeLineCompletionFits(self: *const Core, trailer_bytes_min: u64) bool {
        const minimum: u64 = if (self.size_line_length == 0)
            3
        else if (self.size_line[self.size_line_length - 1] == '\r') 1 else 2;
        return self.suffixFits(minimum, trailer_bytes_min);
    }

    fn chunkCompletionFits(self: *const Core, size: u64, trailer_bytes_min: u64) bool {
        if (self.encoded_wire_bytes > self.encoded_wire_bytes_max) return false;
        const remaining = self.encoded_wire_bytes_max - self.encoded_wire_bytes;
        if (size > remaining) return false;
        if (remaining - size < 5) return false;
        return trailer_bytes_min <= remaining - size - 5;
    }

    fn wireByteAvailable(self: *const Core) bool {
        return self.encoded_wire_bytes < self.encoded_wire_bytes_max;
    }

    fn fail(self: *Core, consumed: usize, status: Status) FeedResult {
        self.phase = .rejected;
        self.rejection_status = status;
        return self.rejectedResult(consumed);
    }

    fn rejectedResult(self: *const Core, consumed: usize) FeedResult {
        return .{
            .consumed = consumed,
            .event = .{ .rejected = .{ .status = self.rejection_status } },
        };
    }
};

pub const StandardDecoder = Decoder(standard_chunks_max);

fn trailersResult(consumed: usize) FeedResult {
    return .{ .consumed = consumed, .event = .trailers_begin };
}

fn parseChunkLine(line: []const u8) ChunkLineError!u64 {
    var index: usize = 0;
    while (index < line.len and isHexByte(line[index])) : (index += 1) {}
    if (index == 0) return error.Invalid;

    const size = syntax.parseHex(line[0..index]) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        error.Empty, error.InvalidDigit => return error.Invalid,
    };
    while (index < line.len) {
        skipOws(line, &index);
        if (index == line.len or line[index] != ';') return error.Invalid;
        index += 1;
        skipOws(line, &index);
        if (!consumeToken(line, &index)) return error.Invalid;
        if (!consumeExtensionValue(line, &index)) return error.Invalid;
    }
    return size;
}

fn consumeExtensionValue(line: []const u8, index: *usize) bool {
    const name_end = index.*;
    skipOws(line, index);
    if (index.* == line.len) return index.* == name_end;
    if (line[index.*] == ';') return true;
    if (line[index.*] != '=') return false;

    index.* += 1;
    skipOws(line, index);
    const value_ok = if (index.* < line.len and line[index.*] == '"')
        consumeQuotedString(line, index)
    else
        consumeToken(line, index);
    if (!value_ok) return false;

    const value_end = index.*;
    skipOws(line, index);
    if (index.* == line.len) return index.* == value_end;
    return line[index.*] == ';';
}

fn consumeToken(bytes: []const u8, index: *usize) bool {
    const start = index.*;
    while (index.* < bytes.len and syntax.isTokenByte(bytes[index.*])) {
        index.* += 1;
    }
    return index.* != start;
}

fn consumeQuotedString(bytes: []const u8, index: *usize) bool {
    std.debug.assert(index.* < bytes.len);
    std.debug.assert(bytes[index.*] == '"');
    index.* += 1;

    while (index.* < bytes.len) {
        const byte = bytes[index.*];
        index.* += 1;
        if (byte == '"') return true;
        if (byte == '\\') {
            if (index.* == bytes.len or !validQuotedPairByte(bytes[index.*])) return false;
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

fn isHexByte(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'F') or
        (byte >= 'a' and byte <= 'f');
}

fn skipOws(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and
        (bytes[index.*] == ' ' or bytes[index.*] == '\t'))
    {
        index.* += 1;
    }
}

const wikipedia_wire = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n";

const Capture = struct {
    bytes: [32]u8 = undefined,
    length: usize = 0,

    fn append(self: *Capture, data: []const u8) !void {
        if (data.len > self.bytes.len - self.length) return error.TestUnexpectedResult;
        std.mem.copyForwards(u8, self.bytes[self.length..][0..data.len], data);
        self.length += data.len;
    }

    fn slice(self: *const Capture) []const u8 {
        return self.bytes[0..self.length];
    }
};

const FragmentResult = struct {
    consumed: usize,
    terminal: bool,
};

test "decodes contiguous input and every two-fragment split identically" {
    var split: usize = 0;
    while (split <= wikipedia_wire.len) : (split += 1) {
        var decoder = StandardDecoder.init(wikipedia_wire.len);
        var capture = Capture{};
        var terminal = false;

        if (split != 0) {
            terminal = (try feedFragment(&decoder, wikipedia_wire[0..split], &capture)).terminal;
        }
        if (!terminal and split != wikipedia_wire.len) {
            terminal = (try feedFragment(&decoder, wikipedia_wire[split..], &capture)).terminal;
        }
        try expectWikipedia(&decoder, &capture, terminal);
    }
}

test "decodes one-byte fragments" {
    var decoder = StandardDecoder.init(wikipedia_wire.len);
    var capture = Capture{};
    var terminal = false;
    for (wikipedia_wire, 0..) |_, index| {
        const result = try feedFragment(&decoder, wikipedia_wire[index .. index + 1], &capture);
        terminal = result.terminal;
        if (terminal and index + 1 != wikipedia_wire.len) return error.TestUnexpectedResult;
    }
    try expectWikipedia(&decoder, &capture, terminal);
}

test "accepts and discards valid chunk extensions" {
    const wire = "4 \t;foo; bar = baz; quoted=\"a\\\"b\"\r\n" ++
        "Wiki\r\n0; done=\"yes\"\r\n";
    try expectDecoded(wire, "Wiki", 1);
}

test "preserves trailer and pipeline remainder with sticky terminal" {
    const prefix = "1\r\na\r\n0\r\n";
    const remainder = "Digest: value\r\n\r\nNEXT";
    const input = prefix ++ remainder;
    var decoder = StandardDecoder.init(input.len);
    var capture = Capture{};
    const result = try feedFragment(&decoder, input, &capture);

    try std.testing.expect(result.terminal);
    try std.testing.expectEqual(prefix.len, result.consumed);
    try std.testing.expectEqualStrings(remainder, input[result.consumed..]);
    try std.testing.expectEqualStrings("a", capture.slice());
    try std.testing.expectEqual(@as(u64, prefix.len), decoder.wireBytesConsumed());

    const sticky = decoder.feed(input[result.consumed..]);
    try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
    try std.testing.expect(sticky.event == .trailers_begin);
}

test "rejects invalid sizes extensions and overflow" {
    const cases = [_][]const u8{
        "\r\n",
        "+1\r\n",
        "0x1\r\n",
        "g\r\n",
        " 1\r\n",
        "1;\r\n",
        "1; name=\r\n",
        "1; name=\"open\r\n",
        "1; name=value \r\n",
        "10000000000000000\r\n",
    };
    for (cases) |case| {
        _ = try expectRejected(standard_chunks_max, 4096, case, .bad_request);
    }
}

test "rejects invalid size-line and data CRLF" {
    const cases = [_][]const u8{
        "1\n",
        "1\rx",
        "1\r\naX",
        "1\r\na\rX",
    };
    for (cases) |case| {
        _ = try expectRejected(standard_chunks_max, 4096, case, .bad_request);
    }
}

test "enforces inclusive size-line scratch limit" {
    var valid: [size_line_bytes_max]u8 = undefined;
    valid[0] = '1';
    valid[1] = ';';
    @memset(valid[2 .. valid.len - 2], 'a');
    valid[valid.len - 2] = '\r';
    valid[valid.len - 1] = '\n';

    var decoder = StandardDecoder.init(valid.len + 6);
    const accepted = decoder.feed(&valid);
    try std.testing.expectEqual(valid.len, accepted.consumed);
    try std.testing.expect(accepted.event == .need_more);

    var overlong: [size_line_bytes_max]u8 = undefined;
    @memset(&overlong, '1');
    const consumed = try expectRejected(
        standard_chunks_max,
        4096,
        &overlong,
        .bad_request,
    );
    try std.testing.expectEqual(overlong.len, consumed);
}

test "counts only non-terminal chunks and enforces limit" {
    try expectDecodedWith(1, "1\r\na\r\n0\r\n", "a", 1);
    const consumed = try expectRejected(
        1,
        4096,
        "1\r\na\r\n1\r\nb\r\n0\r\n",
        .bad_request,
    );
    try std.testing.expectEqual(@as(usize, 9), consumed);
}

test "rejects declared chunk before reading data when wire budget cannot fit" {
    const input = "4\r\nWiki\r\n";
    var decoder = StandardDecoder.init(8);
    const result = decoder.feed(input);
    try expectRejection(result, .payload_too_large);
    try std.testing.expectEqual(@as(usize, 3), result.consumed);
    try std.testing.expectEqualStrings("Wiki\r\n", input[result.consumed..]);
    try std.testing.expectEqual(@as(u64, 3), decoder.wireBytesConsumed());
}

test "enforces wire budget while reading a size line" {
    const consumed = try expectRejected(
        standard_chunks_max,
        2,
        "1\r\n",
        .payload_too_large,
    );
    try std.testing.expectEqual(@as(usize, 0), consumed);
}

test "chunk decoder fragmentation differential fuzz" {
    try std.testing.fuzz({}, fuzzChunked, .{ .corpus = &chunked_fuzz_corpus });
}

const chunked_fuzz_corpus = struct {
    const wikipedia = fuzz_support.smithInputThenU64(wikipedia_wire, 600);
    const extension = fuzz_support.smithInputThenU64(
        "1; x=\"y\"\r\na\r\n0\r\n",
        600,
    );
    const bad_terminator = fuzz_support.smithInputThenU64("1\r\naX", 600);
    const overflow = fuzz_support.smithInputThenU64("ffffffffffffffff\r\n", 600);

    const values = [_][]const u8{
        &wikipedia,
        &extension,
        &bad_terminator,
        &overflow,
    };
}.values;

const FuzzTerminal = enum(u8) {
    need_more,
    trailers,
    rejected,
};

const FuzzSnapshot = struct {
    consumed: usize,
    wire_bytes: u64,
    chunks: u32,
    rejection_code: u16,
    terminal: FuzzTerminal,
};

const FuzzCapture = struct {
    bytes: [512]u8 = undefined,
    length: usize = 0,

    fn append(self: *FuzzCapture, data: []const u8) !void {
        if (data.len > self.bytes.len - self.length) return error.TestUnexpectedResult;
        @memcpy(self.bytes[self.length..][0..data.len], data);
        self.length += data.len;
    }

    fn slice(self: *const FuzzCapture) []const u8 {
        return self.bytes[0..self.length];
    }
};

fn fuzzChunked(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [512]u8 = undefined;
    const input_length = smith.slice(&input_storage);
    const input = input_storage[0..input_length];
    const wire_max = smith.valueRangeAtMost(u16, 0, 600);
    const FuzzDecoder = Decoder(8);

    var contiguous_decoder = FuzzDecoder.init(wire_max);
    var contiguous_capture = FuzzCapture{};
    const contiguous = try fuzzDrive(
        &contiguous_decoder,
        input,
        false,
        &contiguous_capture,
    );

    var fragmented_decoder = FuzzDecoder.init(wire_max);
    var fragmented_capture = FuzzCapture{};
    const fragmented = try fuzzDrive(
        &fragmented_decoder,
        input,
        true,
        &fragmented_capture,
    );

    try std.testing.expectEqualDeep(contiguous, fragmented);
    try std.testing.expectEqualSlices(
        u8,
        contiguous_capture.slice(),
        fragmented_capture.slice(),
    );
}

fn fuzzDrive(
    decoder: anytype,
    input: []const u8,
    one_byte: bool,
    capture: *FuzzCapture,
) !FuzzSnapshot {
    var offset: usize = 0;
    while (offset < input.len) {
        const end = if (one_byte) offset + 1 else input.len;
        const result = decoder.feed(input[offset..end]);
        if (result.consumed > end - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .data => |data| try capture.append(data),
            .need_more => {
                if (offset != end) return error.TestUnexpectedResult;
                if (end == input.len) return fuzzSnapshot(decoder, offset, .need_more, 0);
            },
            .trailers_begin => return fuzzSnapshot(decoder, offset, .trailers, 0),
            .rejected => |rejection| return fuzzSnapshot(
                decoder,
                offset,
                .rejected,
                @intFromEnum(rejection.status),
            ),
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return fuzzSnapshot(decoder, offset, .need_more, 0);
}

fn fuzzSnapshot(
    decoder: anytype,
    consumed: usize,
    terminal: FuzzTerminal,
    rejection_code: u16,
) FuzzSnapshot {
    return .{
        .consumed = consumed,
        .wire_bytes = decoder.wireBytesConsumed(),
        .chunks = decoder.chunksDecoded(),
        .rejection_code = rejection_code,
        .terminal = terminal,
    };
}

fn feedFragment(decoder: anytype, input: []const u8, capture: *Capture) !FragmentResult {
    var offset: usize = 0;
    while (offset < input.len) {
        const result = decoder.feed(input[offset..]);
        if (result.consumed > input.len - offset) return error.TestUnexpectedResult;
        offset += result.consumed;
        switch (result.event) {
            .need_more => {
                if (offset != input.len) return error.TestUnexpectedResult;
                return .{ .consumed = offset, .terminal = false };
            },
            .data => |data| try capture.append(data),
            .trailers_begin => return .{ .consumed = offset, .terminal = true },
            .rejected => return error.TestUnexpectedResult,
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return .{ .consumed = offset, .terminal = false };
}

fn expectWikipedia(decoder: anytype, capture: *const Capture, terminal: bool) !void {
    try std.testing.expect(terminal);
    try std.testing.expectEqualStrings("Wikipedia", capture.slice());
    try std.testing.expectEqual(@as(u32, 2), decoder.chunksDecoded());
    try std.testing.expectEqual(@as(u64, wikipedia_wire.len), decoder.wireBytesConsumed());
}

fn expectDecoded(input: []const u8, expected: []const u8, chunks: u32) !void {
    try expectDecodedWith(standard_chunks_max, input, expected, chunks);
}

fn expectDecodedWith(
    comptime chunks_max: u32,
    input: []const u8,
    expected: []const u8,
    chunks: u32,
) !void {
    const ChunkDecoder = Decoder(chunks_max);
    var decoder = ChunkDecoder.init(input.len);
    var capture = Capture{};
    const result = try feedFragment(&decoder, input, &capture);
    try std.testing.expect(result.terminal);
    try std.testing.expectEqualStrings(expected, capture.slice());
    try std.testing.expectEqual(chunks, decoder.chunksDecoded());
    try std.testing.expectEqual(@as(u64, input.len), decoder.wireBytesConsumed());
}

fn expectRejected(
    comptime chunks_max: u32,
    wire_bytes_max: u64,
    input: []const u8,
    status: Status,
) !usize {
    const ChunkDecoder = Decoder(chunks_max);
    var decoder = ChunkDecoder.init(wire_bytes_max);
    var offset: usize = 0;
    while (offset < input.len) {
        const result = decoder.feed(input[offset..]);
        offset += result.consumed;
        switch (result.event) {
            .data => {},
            .rejected => {
                try expectRejection(result, status);
                const sticky = decoder.feed("ignored");
                try expectRejection(sticky, status);
                try std.testing.expectEqual(@as(usize, 0), sticky.consumed);
                return offset;
            },
            .need_more, .trailers_begin => return error.TestUnexpectedResult,
        }
        if (result.consumed == 0) return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn expectRejection(result: FeedResult, status: Status) !void {
    const rejection = switch (result.event) {
        .rejected => |rejection| rejection,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}
