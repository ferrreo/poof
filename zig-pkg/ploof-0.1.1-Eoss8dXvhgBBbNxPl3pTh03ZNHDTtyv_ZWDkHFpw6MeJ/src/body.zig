const std = @import("std");
const fuzz_support = @import("internal/http1/testing/smith.zig");
const syntax = @import("internal/http1/syntax.zig");
const input_body = @import("input_body.zig");

pub const standard_bytes_max: u64 = 1024 * 1024;
pub const DecoderKind = input_body.DecoderKind;
pub const oneOf = input_body.oneOf;

pub const Kind = enum(u8) {
    none,
    bytes,
    text,
};

pub const None = struct {};

pub const Decoded = union(enum) {
    none,
    bytes: Bytes,
    text: Text,
};

pub const MediaPattern = union(enum) {
    exact: []const u8,
    type_wildcard: []const u8,
    subtype_suffix: struct {
        type: []const u8,
        suffix: []const u8,
    },
    global_wildcard,
};

const bytes_default_media = [_]MediaPattern{
    .{ .exact = "application/octet-stream" },
};
const text_default_media = [_]MediaPattern{
    .{ .exact = "text/plain" },
};

pub const Options = struct {
    encoded_wire_bytes_max: u64 = standard_bytes_max,
    decoded_bytes_max: u64 = standard_bytes_max,
    /// `null` selects the decoder kind's standard media pattern.
    accepted_media: ?[]const MediaPattern = null,
};

pub const Chunk = struct {
    bytes: []const u8,

    pub fn init(value: []const u8) Chunk {
        return .{ .bytes = value };
    }
};

pub const Iterator = struct {
    chunks: []const Chunk,
    index: usize = 0,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.index < self.chunks.len) {
            const value = self.chunks[self.index].bytes;
            self.index += 1;
            if (value.len != 0) return value;
        }
        return null;
    }
};

pub const BytesError = error{LengthOverflow};

pub const Bytes = struct {
    chunk_storage: []const Chunk,
    length: usize,

    pub fn init(chunks: []const Chunk) BytesError!Bytes {
        var length: usize = 0;
        for (chunks) |chunk| {
            length = std.math.add(usize, length, chunk.bytes.len) catch {
                return error.LengthOverflow;
            };
        }
        return .{ .chunk_storage = chunks, .length = length };
    }

    pub fn len(self: Bytes) usize {
        return self.length;
    }

    pub fn iterator(self: Bytes) Iterator {
        return .{ .chunks = self.chunk_storage };
    }

    pub fn single(self: Bytes) ?[]const u8 {
        var chunks = self.iterator();
        const first = chunks.next() orelse return "";
        if (chunks.next() != null) return null;
        return first;
    }

    pub fn eql(self: Bytes, expected: []const u8) bool {
        if (self.length != expected.len) return false;
        var offset: usize = 0;
        var chunks = self.iterator();
        while (chunks.next()) |chunk| {
            const end = offset + chunk.len;
            if (!std.mem.eql(u8, chunk, expected[offset..end])) return false;
            offset = end;
        }
        return offset == expected.len;
    }

    pub fn writeTo(
        self: Bytes,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        var chunks = self.iterator();
        while (chunks.next()) |chunk| try writer.writeAll(chunk);
    }
};

pub const TextError = BytesError || error{InvalidUtf8};

pub const Text = struct {
    bytes_view: Bytes,

    pub fn init(chunks: []const Chunk) TextError!Text {
        return fromBytes(try Bytes.init(chunks));
    }

    pub fn fromBytes(value: Bytes) error{InvalidUtf8}!Text {
        if (!validateUtf8(value)) return error.InvalidUtf8;
        return .{ .bytes_view = value };
    }

    pub fn len(self: Text) usize {
        return self.bytes_view.len();
    }

    pub fn iterator(self: Text) Iterator {
        return self.bytes_view.iterator();
    }

    pub fn single(self: Text) ?[]const u8 {
        return self.bytes_view.single();
    }

    pub fn eql(self: Text, expected: []const u8) bool {
        return self.bytes_view.eql(expected);
    }

    pub fn writeTo(
        self: Text,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        return self.bytes_view.writeTo(writer);
    }

    pub fn asBytes(self: Text) Bytes {
        return self.bytes_view;
    }
};

pub fn bytes(
    comptime requested: Options,
    comptime handler: anytype,
) Endpoint(.bytes, resolveOptions(.bytes, requested), handler) {
    return .{};
}

pub fn text(
    comptime requested: Options,
    comptime handler: anytype,
) Endpoint(.text, resolveOptions(.text, requested), handler) {
    return .{};
}

pub fn raw(comptime requested: Options) Decoder(.bytes, requested) {
    return .{};
}

pub fn utf8(comptime requested: Options) Decoder(.text, requested) {
    return .{};
}

fn Decoder(comptime selected_kind: Kind, comptime requested: Options) type {
    const options = resolveOptions(selected_kind, requested);
    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const kind = selected_kind;
        pub const decoder_kind: input_body.DecoderKind = switch (kind) {
            .none => unreachable,
            .bytes => .bytes,
            .text => .text,
        };
        pub const Target = switch (kind) {
            .none => unreachable,
            .bytes => Bytes,
            .text => Text,
        };
        pub const resolved_options = options;
        pub const encoded_wire_bytes_max = options.encoded_wire_bytes_max;
        pub const decoded_bytes_max = options.decoded_bytes_max;
        pub const accepted_media = options.accepted_media.?;
    };
}

fn Endpoint(
    comptime endpoint_kind: Kind,
    comptime endpoint_options: Options,
    comptime handler: anytype,
) type {
    return struct {
        pub const ploof_body_endpoint = true;
        pub const handler_fn = handler;
        pub const kind = endpoint_kind;
        pub const options = endpoint_options;
        pub const Input = switch (endpoint_kind) {
            .none => unreachable,
            .bytes => Bytes,
            .text => Text,
        };

        pub fn invoke(
            _: @This(),
            context: anytype,
            input: Input,
        ) @TypeOf(handler(context, input)) {
            return handler(context, input);
        }
    };
}

const OptionsIssue = enum(u8) {
    encoded_wire_bytes_zero,
    decoded_bytes_zero,
    media_count,
    invalid_exact_media,
    invalid_type_wildcard,
    invalid_subtype_suffix,
};

fn resolveOptions(comptime kind: Kind, comptime requested: Options) Options {
    const accepted_media = requested.accepted_media orelse defaultMedia(kind);
    const resolved = Options{
        .encoded_wire_bytes_max = requested.encoded_wire_bytes_max,
        .decoded_bytes_max = requested.decoded_bytes_max,
        .accepted_media = accepted_media,
    };
    if (optionsIssue(kind, resolved)) |issue| {
        @compileError(optionsIssueDiagnostic(issue));
    }
    return resolved;
}

fn optionsIssue(kind: Kind, requested: Options) ?OptionsIssue {
    if (requested.encoded_wire_bytes_max == 0) return .encoded_wire_bytes_zero;
    if (requested.decoded_bytes_max == 0) return .decoded_bytes_zero;
    const patterns = requested.accepted_media orelse defaultMedia(kind);
    if (patterns.len == 0 or patterns.len > 4) return .media_count;
    for (patterns) |pattern| switch (pattern) {
        .exact => |value| if (!validExactPattern(value)) {
            return .invalid_exact_media;
        },
        .type_wildcard => |value| if (!validTypeWildcard(value)) {
            return .invalid_type_wildcard;
        },
        .subtype_suffix => |value| if (!validTypeWildcard(value.type) or
            !validTypeWildcard(value.suffix))
        {
            return .invalid_subtype_suffix;
        },
        .global_wildcard => {},
    };
    return null;
}

fn optionsIssueDiagnostic(issue: OptionsIssue) []const u8 {
    return switch (issue) {
        .encoded_wire_bytes_zero => "PLOOF-E3077 encoded-wire body byte limit must be nonzero",
        .decoded_bytes_zero => "PLOOF-E3078 decoded body byte limit must be nonzero",
        .media_count => "PLOOF-E3079 body decoder must accept one to four media patterns",
        .invalid_exact_media => "PLOOF-E3080 invalid exact body media pattern",
        .invalid_type_wildcard => "PLOOF-E3081 invalid body media type wildcard",
        .invalid_subtype_suffix => "PLOOF-E3238 invalid body media subtype suffix",
    };
}

fn defaultMedia(kind: Kind) []const MediaPattern {
    return switch (kind) {
        .none => unreachable,
        .bytes => &bytes_default_media,
        .text => &text_default_media,
    };
}

fn validExactPattern(value: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    if (slash == 0 or slash + 1 == value.len) return false;
    if (std.mem.indexOfScalar(u8, value[slash + 1 ..], '/') != null) return false;
    return validPatternToken(value[0..slash]) and
        validPatternToken(value[slash + 1 ..]);
}

fn validTypeWildcard(value: []const u8) bool {
    return validPatternToken(value);
}

fn validPatternToken(value: []const u8) bool {
    return syntax.isToken(value) and std.mem.indexOfScalar(u8, value, '*') == null;
}

fn validateUtf8(value: Bytes) bool {
    var sequence: [4]u8 = undefined;
    var sequence_length: u3 = 0;
    var sequence_used: u3 = 0;
    var chunks = value.iterator();
    while (chunks.next()) |chunk| {
        for (chunk) |byte| {
            if (sequence_used == 0) {
                sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch return false;
                if (sequence_length == 1) continue;
            }
            sequence[sequence_used] = byte;
            sequence_used += 1;
            if (sequence_used == sequence_length) {
                if (!std.unicode.utf8ValidateSlice(sequence[0..sequence_used])) return false;
                sequence_used = 0;
            }
        }
    }
    return sequence_used == 0;
}

fn endpointLength(base: *usize, input: Bytes) usize {
    return base.* + input.len();
}

fn textEndpointLength(base: *usize, input: Text) usize {
    return base.* + input.len();
}

test "body endpoints resolve defaults and invoke typed handlers" {
    const bytes_endpoint = bytes(.{}, endpointLength);
    const text_endpoint = text(.{}, textEndpointLength);
    try std.testing.expectEqual(Kind.bytes, @TypeOf(bytes_endpoint).kind);
    try std.testing.expectEqual(Kind.text, @TypeOf(text_endpoint).kind);
    try std.testing.expect(@TypeOf(bytes_endpoint).Input == Bytes);
    try std.testing.expect(@TypeOf(text_endpoint).Input == Text);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(@TypeOf(bytes_endpoint)));
    try std.testing.expectEqual(
        standard_bytes_max,
        @TypeOf(bytes_endpoint).options.decoded_bytes_max,
    );
    try expectExactMedia(@TypeOf(bytes_endpoint).options, "application/octet-stream");
    try expectExactMedia(@TypeOf(text_endpoint).options, "text/plain");

    const chunks = [_]Chunk{Chunk.init("abc")};
    const bytes_value = try Bytes.init(&chunks);
    const text_value = try Text.fromBytes(bytes_value);
    var base: usize = 4;
    try std.testing.expectEqual(@as(usize, 7), bytes_endpoint.invoke(&base, bytes_value));
    try std.testing.expectEqual(@as(usize, 7), text_endpoint.invoke(&base, text_value));
}

test "raw and UTF-8 declarations expose reusable body decoders" {
    const Raw = @TypeOf(raw(.{}));
    const Utf8 = @TypeOf(utf8(.{}));
    try std.testing.expect(input_body.isDecoder(Raw));
    try std.testing.expect(input_body.isDecoder(Utf8));
    try std.testing.expect(Raw.Target == Bytes);
    try std.testing.expect(Utf8.Target == Text);
    try std.testing.expectEqual(input_body.DecoderKind.bytes, Raw.decoder_kind);
    try std.testing.expectEqual(input_body.DecoderKind.text, Utf8.decoder_kind);
}

fn expectExactMedia(options: Options, expected: []const u8) !void {
    const patterns = options.accepted_media.?;
    try std.testing.expectEqual(@as(usize, 1), patterns.len);
    const actual = switch (patterns[0]) {
        .exact => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(expected, actual);
}

test "custom media patterns and option failures are exact" {
    const patterns = [_]MediaPattern{
        .{ .exact = "application/vnd.example" },
        .{ .type_wildcard = "image" },
        .global_wildcard,
    };
    const endpoint = bytes(.{
        .encoded_wire_bytes_max = 7,
        .decoded_bytes_max = 5,
        .accepted_media = &patterns,
    }, endpointLength);
    try std.testing.expectEqual(
        @as(u64, 7),
        @TypeOf(endpoint).options.encoded_wire_bytes_max,
    );
    try std.testing.expectEqual(@as(u64, 5), @TypeOf(endpoint).options.decoded_bytes_max);
    try std.testing.expectEqual(
        @as(usize, 3),
        @TypeOf(endpoint).options.accepted_media.?.len,
    );

    try expectOptionsIssue(.encoded_wire_bytes_zero, .bytes, .{
        .encoded_wire_bytes_max = 0,
    }, "PLOOF-E3077");
    try expectOptionsIssue(.decoded_bytes_zero, .bytes, .{
        .decoded_bytes_max = 0,
    }, "PLOOF-E3078");
    try expectOptionsIssue(.media_count, .bytes, .{
        .accepted_media = &.{},
    }, "PLOOF-E3079");
    try expectOptionsIssue(.invalid_exact_media, .bytes, .{
        .accepted_media = &.{.{ .exact = "text" }},
    }, "PLOOF-E3080");
    try expectOptionsIssue(.invalid_type_wildcard, .text, .{
        .accepted_media = &.{.{ .type_wildcard = "text/plain" }},
    }, "PLOOF-E3081");
}

fn expectOptionsIssue(
    expected: OptionsIssue,
    kind: Kind,
    options: Options,
    diagnostic_prefix: []const u8,
) !void {
    const actual = optionsIssue(kind, options) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, actual);
    try std.testing.expect(std.mem.startsWith(
        u8,
        optionsIssueDiagnostic(actual),
        diagnostic_prefix,
    ));
}

test "media pattern grammar admits only exact typed forms" {
    const exact_valid = [_][]const u8{
        "application/json",
        "Application/Vnd.Example+Json",
        "x-custom/x.value",
    };
    for (exact_valid) |value| try std.testing.expect(validExactPattern(value));
    const exact_invalid = [_][]const u8{
        "",
        "text",
        "/plain",
        "text/",
        "text/plain/extra",
        "text/*",
        "*/plain",
        "text/plain; charset=utf-8",
        "text/pl ain",
    };
    for (exact_invalid) |value| try std.testing.expect(!validExactPattern(value));
    try std.testing.expect(validTypeWildcard("text"));
    try std.testing.expect(validTypeWildcard("x-custom"));
    try std.testing.expect(!validTypeWildcard("*"));
    try std.testing.expect(!validTypeWildcard("text/*"));
    try std.testing.expect(!validTypeWildcard("text plain"));
}

test "byte views iterate meaningful chunks and expose single fast path" {
    const empty_chunks = [_]Chunk{ Chunk.init(""), Chunk.init("") };
    const empty = try Bytes.init(&empty_chunks);
    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqualStrings("", empty.single().?);
    var empty_iterator = empty.iterator();
    try std.testing.expect(empty_iterator.next() == null);

    const single_chunks = [_]Chunk{ Chunk.init(""), Chunk.init("one"), Chunk.init("") };
    const single = try Bytes.init(&single_chunks);
    try std.testing.expectEqualStrings("one", single.single().?);

    const many_chunks = [_]Chunk{ Chunk.init("ab"), Chunk.init(""), Chunk.init("cd") };
    const many = try Bytes.init(&many_chunks);
    try std.testing.expectEqual(@as(usize, 4), many.len());
    try std.testing.expect(many.single() == null);
    var iterator = many.iterator();
    try std.testing.expectEqualStrings("ab", iterator.next().?);
    try std.testing.expectEqualStrings("cd", iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "byte equality and writer copy cross every chunk boundary" {
    const chunks = [_]Chunk{
        Chunk.init("a"),
        Chunk.init("bc"),
        Chunk.init(""),
        Chunk.init("def"),
    };
    const value = try Bytes.init(&chunks);
    try std.testing.expect(value.eql("abcdef"));
    try std.testing.expect(!value.eql("abcdeg"));
    try std.testing.expect(!value.eql("abcde"));
    try std.testing.expect(!value.eql("abcdefg"));

    var output: [6]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try value.writeTo(&writer);
    try std.testing.expectEqualStrings("abcdef", writer.buffered());

    var short_output: [5]u8 = undefined;
    var short_writer = std.Io.Writer.fixed(&short_output);
    try std.testing.expectError(error.WriteFailed, value.writeTo(&short_writer));
}

test "text accepts Unicode sequences split across byte-sized chunks" {
    const value = "A\xe2\x82\xac\xf0\x90\x8d\x88Z";
    var chunks: [value.len]Chunk = undefined;
    for (&chunks, 0..) |*chunk, index| chunk.* = Chunk.init(value[index .. index + 1]);
    const text_value = try Text.init(&chunks);
    try std.testing.expectEqual(value.len, text_value.len());
    try std.testing.expect(text_value.eql(value));
    try std.testing.expect(text_value.single() == null);
    try std.testing.expect(text_value.asBytes().eql(value));

    var output: [value.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try text_value.writeTo(&writer);
    try std.testing.expectEqualStrings(value, writer.buffered());
}

test "text rejects invalid and truncated encodings across chunks" {
    const invalid = [_][]const u8{
        "\x80",
        "\xc0\x80",
        "\xed\xa0\x80",
        "\xf4\x90\x80\x80",
        "\xf8\x88\x80\x80\x80",
        "\xe2\x82",
    };
    for (invalid) |value| {
        const chunks = [_]Chunk{Chunk.init(value)};
        try std.testing.expectError(error.InvalidUtf8, Text.init(&chunks));
    }

    const split_invalid = [_]Chunk{
        Chunk.init("valid \xe2"),
        Chunk.init("x"),
    };
    try std.testing.expectError(error.InvalidUtf8, Text.init(&split_invalid));
    const split_truncated = [_]Chunk{ Chunk.init("\xf0"), Chunk.init("\x90\x8d") };
    try std.testing.expectError(error.InvalidUtf8, Text.init(&split_truncated));
}

test "empty text is valid" {
    const chunks = [_]Chunk{};
    const value = try Text.init(&chunks);
    try std.testing.expectEqual(@as(usize, 0), value.len());
    try std.testing.expectEqualStrings("", value.single().?);
    try std.testing.expect(value.eql(""));
}

test "body text fragmentation differential fuzz" {
    try std.testing.fuzz({}, fuzzText, .{ .corpus = &text_fuzz_corpus });
}

const text_fuzz_corpus = struct {
    const ascii = fuzz_support.smithInput("plain ASCII");
    const unicode = fuzz_support.smithInput("A\xe2\x82\xac\xf0\x90\x8d\x88Z");
    const truncated = fuzz_support.smithInput("bad \xe2\x82");
    const overlong = fuzz_support.smithInput("\xc0\x80");
    const values = [_][]const u8{ &ascii, &unicode, &truncated, &overlong };
}.values;

fn fuzzText(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const input = storage[0..smith.slice(&storage)];
    const expected = std.unicode.utf8ValidateSlice(input);

    const single = [_]Chunk{Chunk.init(input)};
    try std.testing.expectEqual(expected, textAccepts(&single));

    var fragmented: [storage.len]Chunk = undefined;
    for (input, 0..) |_, index| {
        fragmented[index] = Chunk.init(input[index .. index + 1]);
    }
    try std.testing.expectEqual(expected, textAccepts(fragmented[0..input.len]));
}

fn textAccepts(chunks: []const Chunk) bool {
    _ = Text.init(chunks) catch return false;
    return true;
}

test {
    std.testing.refAllDecls(@This());
}
