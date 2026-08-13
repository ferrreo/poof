const std = @import("std");
const fuzz_support = @import("testing/smith.zig");
const limits = @import("limits.zig");
const request_head = @import("request_head.zig");
const request_content_type = @import("request_content_type.zig");
const request_content_reference = @import("request_content_reference.zig");
const status_module = @import("status.zig");
const syntax = @import("syntax.zig");

pub const Status = status_module.Status;
pub const empty_coding_members_max: u8 = 32;

pub const Mode = request_content_type.Mode;

pub const ModeMap = struct {
    pattern_decoder_indices: []const u8,
    decoder_modes: []const Mode,
};

pub const Coding = enum(u8) {
    identity,
    gzip,
};

pub const Charset = request_content_type.Charset;

pub const Reason = enum(u8) {
    missing_content_type,
    duplicate_content_type,
    malformed_content_type,
    unsupported_media_type,
    duplicate_charset,
    unsupported_charset,
    malformed_content_encoding,
    unsupported_content_encoding,
    stacked_content_encoding,
};

pub const Rejection = struct {
    status: Status,
    reason: Reason,
    close: bool = true,
};

pub const Media = request_content_type.Media;

pub const Admission = struct {
    media: Media,
    coding: Coding,
    charset: ?Charset,
    matched_pattern: usize,
};

pub const Result = union(enum) {
    accepted: Admission,
    rejected: Rejection,
};

const HeaderSelection = struct {
    content_type: ?request_head.Span = null,
    content_type_count: usize = 0,
};

const EncodingClass = union(enum) {
    coding: Coding,
    malformed,
    unsupported,
    stacked,
};

const EncodingScan = struct {
    first: []const u8 = "",
    members: u8 = 0,
    empty_members: u8 = 0,
};

pub fn analyze(
    mode: Mode,
    accepted_media: anytype,
    fields: []const request_head.Field,
    bytes: []const u8,
) Result {
    return analyzeWith(.{ .single = mode }, accepted_media, fields, bytes);
}

pub fn analyzeMapped(
    mode_map: ModeMap,
    accepted_media: anytype,
    fields: []const request_head.Field,
    bytes: []const u8,
) Result {
    return analyzeWith(.{ .mapped = mode_map }, accepted_media, fields, bytes);
}

const ModeSelection = union(enum) {
    single: Mode,
    mapped: ModeMap,

    fn forPattern(selection: ModeSelection, pattern: usize) ?Mode {
        return switch (selection) {
            .single => |mode| mode,
            .mapped => |map| mapped: {
                if (pattern >= map.pattern_decoder_indices.len) return null;
                const decoder = map.pattern_decoder_indices[pattern];
                if (decoder >= map.decoder_modes.len) return null;
                break :mapped map.decoder_modes[decoder];
            },
        };
    }
};

fn analyzeWith(
    mode_selection: ModeSelection,
    accepted_media: anytype,
    fields: []const request_head.Field,
    bytes: []const u8,
) Result {
    const headers = selectHeaders(fields, bytes);
    if (headers.content_type_count == 0) return reject(.missing_content_type);
    if (headers.content_type_count != 1) return reject(.duplicate_content_type);

    const content_type = headers.content_type.?.slice(bytes);
    const parsed = request_content_type.parse(content_type) catch {
        return reject(.malformed_content_type);
    };
    const pattern = selectPattern(accepted_media, parsed.media) orelse {
        return reject(.unsupported_media_type);
    };
    const mode = mode_selection.forPattern(pattern) orelse {
        return reject(.unsupported_media_type);
    };
    const charset = request_content_type.validateCharset(mode, parsed) catch |problem| {
        return reject(switch (problem) {
            error.DuplicateCharset => .duplicate_charset,
            error.UnsupportedCharset => .unsupported_charset,
        });
    };

    const coding = switch (classifyContentEncodings(fields, bytes)) {
        .coding => |value| value,
        .malformed => return reject(.malformed_content_encoding),
        .unsupported => return reject(.unsupported_content_encoding),
        .stacked => return reject(.stacked_content_encoding),
    };

    return .{ .accepted = .{
        .media = parsed.media,
        .coding = coding,
        .charset = charset,
        .matched_pattern = pattern,
    } };
}

fn selectHeaders(fields: []const request_head.Field, bytes: []const u8) HeaderSelection {
    var selected = HeaderSelection{};
    for (fields) |field| {
        const name = field.name.slice(bytes);
        if (syntax.eqlIgnoreCase(name, "content-type")) {
            selected.content_type_count += 1;
            if (selected.content_type == null) selected.content_type = field.value;
        }
    }
    return selected;
}

fn selectPattern(patterns: anytype, media: Media) ?usize {
    for (patterns, 0..) |pattern, index| {
        const matches = switch (pattern) {
            .exact => |value| matchesExact(value, media),
            .type_wildcard => |value| syntax.eqlIgnoreCase(value, media.type),
            .subtype_suffix => |value| matchesSubtypeSuffix(value, media),
            .global_wildcard => true,
        };
        if (matches) return index;
    }
    return null;
}

fn matchesSubtypeSuffix(pattern: anytype, media: Media) bool {
    if (!syntax.eqlIgnoreCase(pattern.type, media.type)) return false;
    if (media.subtype.len <= pattern.suffix.len + 1) return false;
    const suffix_start = media.subtype.len - pattern.suffix.len;
    if (media.subtype[suffix_start - 1] != '+') return false;
    return syntax.eqlIgnoreCase(pattern.suffix, media.subtype[suffix_start..]);
}

fn matchesExact(pattern: []const u8, media: Media) bool {
    const slash = std.mem.indexOfScalar(u8, pattern, '/') orelse return false;
    const pattern_type = pattern[0..slash];
    const pattern_subtype = pattern[slash + 1 ..];
    if (!syntax.eqlIgnoreCase(pattern_type, media.type)) return false;
    return syntax.eqlIgnoreCase(pattern_subtype, media.subtype);
}

fn classifyContentEncoding(value_raw: []const u8) EncodingClass {
    var scan = EncodingScan{};
    scanEncodingValue(&scan, value_raw) catch return .malformed;
    return finishEncodingScan(scan);
}

fn classifyContentEncodings(
    fields: []const request_head.Field,
    bytes: []const u8,
) EncodingClass {
    var scan = EncodingScan{};
    for (fields) |field| {
        if (!syntax.eqlIgnoreCase(field.name.slice(bytes), "content-encoding")) continue;
        scanEncodingValue(&scan, field.value.slice(bytes)) catch return .malformed;
    }
    return finishEncodingScan(scan);
}

fn scanEncodingValue(
    scan: *EncodingScan,
    value: []const u8,
) error{MalformedContentEncoding}!void {
    var cursor: usize = 0;
    while (true) {
        skipOws(value, &cursor);
        const start = cursor;
        while (cursor < value.len and syntax.isTokenByte(value[cursor])) cursor += 1;
        if (cursor != start) {
            scan.members = std.math.add(u8, scan.members, 1) catch {
                return error.MalformedContentEncoding;
            };
            if (scan.members == 1) scan.first = value[start..cursor];
        } else {
            scan.empty_members = std.math.add(u8, scan.empty_members, 1) catch {
                return error.MalformedContentEncoding;
            };
            if (scan.empty_members > empty_coding_members_max) {
                return error.MalformedContentEncoding;
            }
        }
        skipOws(value, &cursor);
        if (cursor == value.len) break;
        if (value[cursor] != ',') return error.MalformedContentEncoding;
        cursor += 1;
    }
}

fn finishEncodingScan(scan: EncodingScan) EncodingClass {
    if (scan.members == 0) return .{ .coding = .identity };
    if (scan.members != 1) return .stacked;
    if (syntax.eqlIgnoreCase(scan.first, "identity")) return .{ .coding = .identity };
    if (syntax.eqlIgnoreCase(scan.first, "gzip")) return .{ .coding = .gzip };
    return .unsupported;
}

fn skipOws(value: []const u8, cursor: *usize) void {
    while (cursor.* < value.len and
        (value[cursor.*] == ' ' or value[cursor.*] == '\t'))
    {
        cursor.* += 1;
    }
}

fn reject(reason: Reason) Result {
    const status: Status = switch (reason) {
        .duplicate_content_type,
        .malformed_content_type,
        .duplicate_charset,
        .malformed_content_encoding,
        => .bad_request,
        .missing_content_type,
        .unsupported_media_type,
        .unsupported_charset,
        .unsupported_content_encoding,
        .stacked_content_encoding,
        => .unsupported_media_type,
    };
    return .{ .rejected = .{ .status = status, .reason = reason } };
}

const Pattern = union(enum) {
    exact: []const u8,
    type_wildcard: []const u8,
    subtype_suffix: struct {
        type: []const u8,
        suffix: []const u8,
    },
    global_wildcard,
};

const octet_patterns = [_]Pattern{.{ .exact = "application/octet-stream" }};
const text_patterns = [_]Pattern{.{ .exact = "text/plain" }};
const TestDecoder = request_head.Decoder(limits.standard_request_head_limits);
const request_prefix = "POST / HTTP/1.1\r\nHost: example.test\r\n";

fn requestResult(
    mode: Mode,
    patterns: anytype,
    request: []const u8,
    decoder: *TestDecoder,
) !Result {
    decoder.* = TestDecoder.init();
    const decoded = decoder.feed(request);
    switch (decoded.state) {
        .ready => {},
        else => return error.TestUnexpectedResult,
    }
    return analyze(mode, patterns, decoder.fields(), decoder.bytes());
}

fn expectAccepted(
    request: []const u8,
    mode: Mode,
    patterns: anytype,
    coding: Coding,
    charset: ?Charset,
    pattern: usize,
) !void {
    var decoder = TestDecoder.init();
    const result = try requestResult(mode, patterns, request, &decoder);
    const accepted = switch (result) {
        .accepted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(coding, accepted.coding);
    try std.testing.expectEqual(charset, accepted.charset);
    try std.testing.expectEqual(pattern, accepted.matched_pattern);
}

fn expectRejected(
    request: []const u8,
    mode: Mode,
    patterns: anytype,
    reason: Reason,
    status: Status,
) !void {
    var decoder = TestDecoder.init();
    const result = try requestResult(mode, patterns, request, &decoder);
    const rejection = switch (result) {
        .accepted => return error.TestUnexpectedResult,
        .rejected => |value| value,
    };
    try std.testing.expectEqual(reason, rejection.reason);
    try std.testing.expectEqual(status, rejection.status);
    try std.testing.expect(rejection.close);
}

test "admits exact media with identity or gzip without allocation" {
    try expectAccepted(
        request_prefix ++ "Content-Type: application/octet-stream\r\n\r\n",
        .bytes,
        &octet_patterns,
        .identity,
        null,
        0,
    );
    try expectAccepted(
        request_prefix ++
            "cOnTeNt-TyPe: Application/Octet-Stream; version=1\r\n" ++
            "CoNtEnT-EnCoDiNg:\t GZiP \t\r\n\r\n",
        .bytes,
        &octet_patterns,
        .gzip,
        null,
        0,
    );
}

test "structured suffix pattern requires a nonempty subtype prefix" {
    const patterns = [_]Pattern{.{ .subtype_suffix = .{
        .type = "application",
        .suffix = "json",
    } }};
    try expectAccepted(
        request_prefix ++ "Content-Type: Application/Vnd.Example+Json\r\n\r\n",
        .bytes,
        &patterns,
        .identity,
        null,
        0,
    );
    try expectRejected(
        request_prefix ++ "Content-Type: application/json\r\n\r\n",
        .bytes,
        &patterns,
        .unsupported_media_type,
        .unsupported_media_type,
    );
}

test "selects exact type and global wildcard patterns in declaration order" {
    const patterns = [_]Pattern{
        .{ .exact = "application/json" },
        .{ .type_wildcard = "text" },
        .global_wildcard,
    };
    try expectAccepted(
        request_prefix ++ "Content-Type: Application/Json\r\n\r\n",
        .bytes,
        &patterns,
        .identity,
        null,
        0,
    );
    try expectAccepted(
        request_prefix ++ "Content-Type: TEXT/CSS\r\n\r\n",
        .bytes,
        &patterns,
        .identity,
        null,
        1,
    );
    try expectAccepted(
        request_prefix ++ "Content-Type: image/png\r\n\r\n",
        .bytes,
        &patterns,
        .identity,
        null,
        2,
    );
}

test "mapped media applies the selected decoder charset policy once" {
    const patterns = [_]Pattern{
        .{ .exact = "application/octet-stream" },
        .{ .exact = "text/plain" },
    };
    const indices = [_]u8{ 0, 1 };
    const modes = [_]Mode{ .bytes, .text };
    var decoder = TestDecoder.init();
    const request = request_prefix ++
        "Content-Type: application/octet-stream; charset=shift_jis\r\n\r\n";
    _ = switch (decoder.feed(request).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    const accepted = analyzeMapped(
        .{ .pattern_decoder_indices = &indices, .decoder_modes = &modes },
        &patterns,
        decoder.fields(),
        decoder.bytes(),
    );
    try std.testing.expect(accepted == .accepted);

    decoder = TestDecoder.init();
    const text_request = request_prefix ++
        "Content-Type: text/plain; charset=shift_jis\r\n\r\n";
    _ = switch (decoder.feed(text_request).state) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };
    const rejected = analyzeMapped(
        .{ .pattern_decoder_indices = &indices, .decoder_modes = &modes },
        &patterns,
        decoder.fields(),
        decoder.bytes(),
    );
    const rejection = switch (rejected) {
        .rejected => |value| value,
        .accepted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        Reason.unsupported_charset,
        rejection.reason,
    );
}

test "distinguishes missing duplicate malformed and unsupported media" {
    try expectRejected(
        request_prefix ++ "\r\n",
        .bytes,
        &octet_patterns,
        .missing_content_type,
        .unsupported_media_type,
    );
    try expectRejected(
        request_prefix ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Type: application/octet-stream\r\n\r\n",
        .bytes,
        &octet_patterns,
        .duplicate_content_type,
        .bad_request,
    );
    try expectRejected(
        request_prefix ++ "Content-Type: text/plain; charset=\r\n\r\n",
        .bytes,
        &octet_patterns,
        .malformed_content_type,
        .bad_request,
    );
    try expectRejected(
        request_prefix ++ "Content-Type: text/plain\r\n\r\n",
        .bytes,
        &octet_patterns,
        .unsupported_media_type,
        .unsupported_media_type,
    );
}

test "text accepts only implicit or explicit UTF-8 after media selection" {
    try expectAccepted(
        request_prefix ++ "Content-Type: text/plain\r\n\r\n",
        .text,
        &text_patterns,
        .identity,
        .implicit_utf8,
        0,
    );
    try expectAccepted(
        request_prefix ++
            "Content-Type: TEXT/PLAIN ; note=\"a,b;\\\"safe\"; charset=\"UtF\\-8\"\r\n\r\n",
        .text,
        &text_patterns,
        .identity,
        .explicit_utf8,
        0,
    );
    try expectAccepted(
        request_prefix ++ "Content-Type: text/plain;;; charset=utf-8;\r\n\r\n",
        .text,
        &text_patterns,
        .identity,
        .explicit_utf8,
        0,
    );
    try expectRejected(
        request_prefix ++ "Content-Type: text/plain; charset=latin1\r\n\r\n",
        .text,
        &text_patterns,
        .unsupported_charset,
        .unsupported_media_type,
    );
    try expectRejected(
        request_prefix ++
            "Content-Type: text/plain; charset=utf-8; CHARSET=\"utf-8\"\r\n\r\n",
        .text,
        &text_patterns,
        .duplicate_charset,
        .bad_request,
    );
}

test "byte media validates but does not interpret charset parameters" {
    try expectAccepted(
        request_prefix ++
            "Content-Type: application/octet-stream; charset=latin1; charset=x\r\n\r\n",
        .bytes,
        &octet_patterns,
        .identity,
        null,
        0,
    );
}

test "content encoding distinguishes malformed unsupported and stacked values" {
    const malformed = [_][]const u8{ "gzip;level=1", "gzip identity" };
    for (malformed) |value| {
        var request_storage: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&request_storage);
        try writer.writeAll(request_prefix ++ "Content-Type: application/octet-stream\r\n");
        try writer.print("Content-Encoding: {s}\r\n\r\n", .{value});
        try expectRejected(
            writer.buffered(),
            .bytes,
            &octet_patterns,
            .malformed_content_encoding,
            .bad_request,
        );
    }
    const accepted = [_][]const u8{ "", "gzip,", ",gzip", ",, gzip, ," };
    for (accepted) |value| {
        var request_storage: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&request_storage);
        try writer.writeAll(request_prefix ++ "Content-Type: application/octet-stream\r\n");
        try writer.print("Content-Encoding: {s}\r\n\r\n", .{value});
        try expectAccepted(
            writer.buffered(),
            .bytes,
            &octet_patterns,
            if (std.mem.indexOf(u8, value, "gzip") == null) .identity else .gzip,
            null,
            0,
        );
    }
    try expectRejected(
        request_prefix ++
            "Content-Type: application/octet-stream\r\nContent-Encoding: br,\r\n\r\n",
        .bytes,
        &octet_patterns,
        .unsupported_content_encoding,
        .unsupported_media_type,
    );
    try expectRejected(
        request_prefix ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Encoding: gzip, identity\r\n\r\n",
        .bytes,
        &octet_patterns,
        .stacked_content_encoding,
        .unsupported_media_type,
    );
}

test "physical content encoding lines combine with empty members ignored" {
    try expectAccepted(
        request_prefix ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Encoding: gzip\r\nContent-Encoding:\r\n\r\n",
        .bytes,
        &octet_patterns,
        .gzip,
        null,
        0,
    );
    try expectRejected(
        request_prefix ++
            "Content-Type: application/octet-stream\r\n" ++
            "Content-Encoding: gzip\r\nContent-Encoding: identity\r\n\r\n",
        .bytes,
        &octet_patterns,
        .stacked_content_encoding,
        .unsupported_media_type,
    );
}

test "content encoding bounds ignored empty members" {
    const accepted = "," ** (empty_coding_members_max - 1);
    try std.testing.expectEqualDeep(
        EncodingClass{ .coding = .identity },
        classifyContentEncoding(accepted),
    );
    const rejected = "," ** empty_coding_members_max;
    try std.testing.expectEqualDeep(
        EncodingClass.malformed,
        classifyContentEncoding(rejected),
    );
}

test "quoted-string injection and truncation stay malformed" {
    const invalid = [_][]const u8{
        "text/plain; note=\"unterminated",
        "text/plain; note=\"bad\rvalue\"",
        "text/plain; note=\"bad\\\nvalue\"",
        "text/plain, application/json",
        "text/plain\x00",
        "text/plain\x7f",
    };
    for (invalid) |value| {
        try std.testing.expectError(error.MalformedContentType, request_content_type.parse(value));
    }
}

test "content value parsers have bounded deterministic fuzz invariants" {
    try std.testing.fuzz({}, fuzzContentValues, .{ .corpus = &content_fuzz_corpus });
}

const content_fuzz_corpus = struct {
    const json = fuzz_support.smithInput("application/json; charset=utf-8");
    const quoted = fuzz_support.smithInput("text/plain; p=\"a,b;\\\"c\"");
    const malformed = fuzz_support.smithInput("text/plain; charset=\"unterminated");
    const gzip = fuzz_support.smithInput("gzip");
    const stacked = fuzz_support.smithInput("gzip, identity");
    const empties = fuzz_support.smithInput(",, gzip, ,");
    const values = [_][]const u8{ &json, &quoted, &malformed, &gzip, &stacked, &empties };
}.values;

fn fuzzContentValues(_: void, smith: *std.testing.Smith) !void {
    var storage: [512]u8 = undefined;
    const value = storage[0..smith.slice(&storage)];
    try std.testing.expectEqualDeep(
        referenceContentEncodings(&.{value}),
        classifyContentEncoding(value),
    );

    const split_u16 = smith.valueRangeAtMost(u16, 0, @intCast(value.len));
    const split: usize = split_u16;
    const physical = [_][]const u8{ value[0..split], value[split..] };
    try std.testing.expectEqualDeep(
        referenceContentEncodings(&physical),
        classifyContentEncodingPair(physical[0], physical[1]),
    );

    const expected_media = request_content_reference.mediaTypeValid(value);
    const parsed = request_content_type.parse(value) catch {
        try std.testing.expect(!expected_media);
        return;
    };
    try std.testing.expect(expected_media);
    try std.testing.expect(syntax.isToken(parsed.media.type));
    try std.testing.expect(syntax.isToken(parsed.media.subtype));
    const patterns = [_]Pattern{.global_wildcard};
    const selected = selectPattern(&patterns, parsed.media);
    try std.testing.expectEqual(@as(?usize, 0), selected);
}

fn classifyContentEncodingPair(first: []const u8, second: []const u8) EncodingClass {
    var scan = EncodingScan{};
    scanEncodingValue(&scan, first) catch return .malformed;
    scanEncodingValue(&scan, second) catch return .malformed;
    return finishEncodingScan(scan);
}

fn referenceContentEncodings(values: []const []const u8) EncodingClass {
    var members: u16 = 0;
    var empty_members: u16 = 0;
    var first: []const u8 = "";
    for (values) |value| {
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |raw| {
            const part = syntax.trimOws(raw);
            if (part.len == 0) {
                empty_members += 1;
                if (empty_members > empty_coding_members_max) return .malformed;
            } else {
                if (!syntax.isToken(part)) return .malformed;
                members += 1;
                if (members == 1) first = part;
            }
        }
    }
    if (members == 0) return .{ .coding = .identity };
    if (members != 1) return .stacked;
    if (syntax.eqlIgnoreCase(first, "identity")) return .{ .coding = .identity };
    if (syntax.eqlIgnoreCase(first, "gzip")) return .{ .coding = .gzip };
    return .unsupported;
}

test {
    std.testing.refAllDecls(@This());
}
