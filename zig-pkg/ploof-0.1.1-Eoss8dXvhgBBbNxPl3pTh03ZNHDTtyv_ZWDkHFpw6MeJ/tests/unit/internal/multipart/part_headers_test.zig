const std = @import("std");
const headers = @import("../../../../src/internal/multipart/part_headers.zig");

test "minimal form-data metadata borrows the caller buffer" {
    var section = "Content-Disposition: form-data; name=token\r\n\r\n".*;
    const parsed = try headers.parse(.{}, &section);
    try std.testing.expectEqualStrings("token", parsed.name);
    try std.testing.expect(parsed.filename == null);
    try std.testing.expect(parsed.content_type == null);
    try expectWithin(&section, parsed.name);
    try headers.validateText(parsed);
    try std.testing.expect(headers.claimedMediaAccepted(parsed, &.{}, .allow));
    try std.testing.expect(!headers.claimedMediaAccepted(parsed, &.{}, .reject));
}

test "quoted name and filename decode without path rewriting or percent decoding" {
    var section = ("Content-Disposition: form-data; name=\"na\\\"me\"; " ++
        "filename=\"..\\\\folder/%2F.txt\"\r\n\r\n").*;
    const parsed = try headers.parse(.{}, &section);
    try std.testing.expectEqualStrings("na\"me", parsed.name);
    const client = parsed.filename.?;
    try std.testing.expectEqual(headers.FilenameSource.filename, client.source);
    try std.testing.expectEqualStrings("..\\folder/%2F.txt", client.bytes);
    try expectWithin(&section, parsed.name);
    try expectWithin(&section, client.bytes);
}

test "absent and explicitly empty filenames remain distinct" {
    var absent_section = "Content-Disposition: form-data; name=file\r\n\r\n".*;
    const absent = try headers.parse(.{}, &absent_section);
    try std.testing.expect(absent.filename == null);

    var empty_section =
        "Content-Disposition: form-data; name=file; filename=\"\"\r\n\r\n".*;
    const empty = try headers.parse(.{ .filename_bytes_max = 0 }, &empty_section);
    try std.testing.expectEqual(headers.FilenameSource.filename, empty.filename.?.source);
    try std.testing.expectEqualStrings("", empty.filename.?.bytes);
}

test "filename star decodes strict UTF-8 extended values and provenance" {
    var section = ("Content-Disposition: form-data; name=file; " ++
        "filename*=UTF-8'zh-Hant'%E2%82%AC%2Freport.txt\r\n\r\n").*;
    const parsed = try headers.parse(.{}, &section);
    try std.testing.expectEqual(headers.FilenameSource.filename_star, parsed.filename.?.source);
    try std.testing.expectEqualStrings("€/report.txt", parsed.filename.?.bytes);
    try expectWithin(&section, parsed.filename.?.bytes);

    var empty_section =
        "Content-Disposition: form-data; name=file; filename*=utf-8''\r\n\r\n".*;
    const empty = try headers.parse(.{ .filename_bytes_max = 0 }, &empty_section);
    try std.testing.expectEqualStrings("", empty.filename.?.bytes);
    try std.testing.expectEqual(headers.FilenameSource.filename_star, empty.filename.?.source);
}

test "content type retains parsed spans and text semantics" {
    var section = ("Content-Disposition: form-data; name=value\r\n" ++
        "Content-Type: Text/Plain; charset=\"UT\\F-8\"; note=opaque\r\n\r\n").*;
    const parsed = try headers.parse(.{}, &section);
    const media = parsed.content_type.?;
    try std.testing.expectEqualStrings("Text", media.type);
    try std.testing.expectEqualStrings("Plain", media.subtype);
    try std.testing.expectEqualStrings(
        "Text/Plain; charset=\"UT\\F-8\"; note=opaque",
        media.raw,
    );
    try std.testing.expectEqualStrings("UT\\F-8", media.charset.?.bytes);
    try std.testing.expect(media.charset.?.quoted);
    try expectWithin(&section, media.raw);
    try expectWithin(&section, media.type);
    try expectWithin(&section, media.subtype);
    try expectWithin(&section, media.charset.?.bytes);
    try headers.validateText(parsed);
}

test "text validation rejects non-text nested and non-UTF-8 claims" {
    const values = [_][]const u8{
        "application/octet-stream",
        "multipart/mixed; boundary=inner",
        "text/plain; charset=iso-8859-1",
        "text/html; charset=utf-8",
    };
    for (values) |value| {
        var storage: [512]u8 = undefined;
        const section = try makeSection(&storage, value);
        const parsed = try headers.parse(.{}, section);
        try std.testing.expectError(error.UnsupportedMedia, headers.validateText(parsed));
    }
}

test "file media claims compare only exact normalized type and subtype" {
    const claims = [_]headers.MediaClaim{
        .{ .type = "image", .subtype = "png" },
        .{ .type = "image", .subtype = "jpeg" },
    };
    var section = ("Content-Disposition: form-data; name=file\r\n" ++
        "Content-Type: IMAGE/PNG; profile=untrusted\r\n\r\n").*;
    const parsed = try headers.parse(.{}, &section);
    try std.testing.expect(headers.claimedMediaAccepted(parsed, &claims, .reject));
    try std.testing.expect(!headers.isMultipart(parsed));

    var nested_section = ("Content-Disposition: form-data; name=file\r\n" ++
        "Content-Type: Multipart/Mixed; boundary=inner\r\n\r\n").*;
    const nested = try headers.parse(.{}, &nested_section);
    try std.testing.expect(headers.isMultipart(nested));
    try std.testing.expect(!headers.claimedMediaAccepted(nested, &claims, .allow));
}

test "unsupported valid headers are counted then discarded" {
    var section = ("X-Trace: one\r\n" ++
        "Content-Disposition: form-data; name=value\r\n" ++
        "Content-ID: <part@example.test>\r\n\r\n").*;
    const parsed = try headers.parse(.{ .header_fields_max = 3 }, &section);
    try std.testing.expectEqualStrings("value", parsed.name);
    try expectParseError(error.LimitExceeded, .{ .header_fields_max = 2 }, &section);
}

test "header section rejects bare lines folding controls and trailing data" {
    const invalid = [_][]const u8{
        "Content-Disposition: form-data; name=x\n\n",
        "Content-Disposition: form-data; name=x\r\r\n",
        "Content-Disposition: form-data; name=x\r\n",
        "Content-Disposition: form-data; name=x\r\n\r\nextra",
        " Content-Disposition: form-data; name=x\r\n\r\n",
        "\tcontinued: value\r\n\r\n",
        "Bad Name: value\r\nContent-Disposition: form-data; name=x\r\n\r\n",
        "Bad : value\r\nContent-Disposition: form-data; name=x\r\n\r\n",
        "X-Test: nul\x00value\r\nContent-Disposition: form-data; name=x\r\n\r\n",
        "X-Test: delete\x7fvalue\r\nContent-Disposition: form-data; name=x\r\n\r\n",
    };
    for (invalid) |value| try expectMalformed(value);
}

test "content disposition is required singleton form-data with one name" {
    const invalid = [_][]const u8{
        "X-Test: value\r\n\r\n",
        "Content-Disposition: attachment; name=x\r\n\r\n",
        "Content-Disposition: form-data\r\n\r\n",
        "Content-Disposition: form-data; filename=x\r\n\r\n",
        "Content-Disposition: form-data; name=\"\"\r\n\r\n",
        "Content-Disposition: form-data; name=x\r\n" ++
            "Content-Disposition: form-data; name=y\r\n\r\n",
        "Content-Disposition: form-data; name=x;\r\n\r\n",
        "Content-Disposition: form-data;; name=x\r\n\r\n",
        "Content-Disposition: form-data; name =x\r\n\r\n",
        "Content-Disposition: form-data; name= x\r\n\r\n",
        "Content-Disposition: form-data; name=\"unterminated\r\n\r\n",
        "Content-Disposition: form-data; name=\"bad\\\tvalue\"\r\n\r\n",
        "Content-Disposition: form-data; name=\"bad\xffvalue\"\r\n\r\n",
    };
    for (invalid) |value| try expectMalformed(value);
}

test "every disposition parameter is duplicate checked without case" {
    const invalid = [_][]const u8{
        "Content-Disposition: form-data; name=x; NAME=y\r\n\r\n",
        "Content-Disposition: form-data; name=x; note=a; NoTe=b\r\n\r\n",
        "Content-Disposition: form-data; name=x; filename=a; FILENAME=b\r\n\r\n",
        "Content-Disposition: form-data; name=x; filename*=UTF-8''a; " ++
            "FILENAME*=UTF-8''b\r\n\r\n",
    };
    for (invalid) |value| try expectMalformed(value);

    var section =
        "Content-Disposition: form-data; z=1; name=x; a=2; y=3; b=4\r\n\r\n".*;
    const parsed = try headers.parse(.{ .disposition_parameters_max = 5 }, &section);
    try std.testing.expectEqualStrings("x", parsed.name);
}

test "filename forms are exclusive and regular filename must be UTF-8 without controls" {
    const invalid = [_][]const u8{
        "Content-Disposition: form-data; name=x; filename=a; " ++
            "filename*=UTF-8''b\r\n\r\n",
        "Content-Disposition: form-data; name=x; filename=\"bad\xff\"\r\n\r\n",
        "Content-Disposition: form-data; name=x; filename=\"bad\tname\"\r\n\r\n",
        "Content-Disposition: form-data; name=x; filename=\"bad\x7fname\"\r\n\r\n",
    };
    for (invalid) |value| try expectMalformed(value);
}

test "filename star rejects malformed charset language encoding and UTF-8" {
    const invalid = [_][]const u8{
        "ISO-8859-1''name",
        "UTF-8name",
        "UTF-8'enname",
        "UTF-8'en_US'name",
        "UTF-8'en--US'name",
        "UTF-8'language9'name",
        "UTF-8'a'name",
        "UTF-8'x'name",
        "UTF-8'en-a'name",
        "UTF-8'en-12'name",
        "UTF-8'en-US-US'name",
        "UTF-8'en-1901-1901'name",
        "UTF-8'en-a-foo-A-bar'name",
        "UTF-8'en-a-b'name",
        "UTF-8'en-x'name",
        "UTF-8'en-abc-def-ghi-jkl'name",
        "UTF-8'x-privateuse9'name",
        "UTF-8''has space",
        "UTF-8''has*star",
        "UTF-8''has'quote",
        "UTF-8''bad%",
        "UTF-8''bad%2",
        "UTF-8''bad%XZ",
        "UTF-8''bad%ff",
        "UTF-8''bad%00",
    };
    for (invalid) |value| {
        var storage: [512]u8 = undefined;
        const section = try makeFilenameStarSection(&storage, value, false);
        try std.testing.expectError(error.Malformed, headers.parse(.{}, section));
    }
    var storage: [512]u8 = undefined;
    const quoted = try makeFilenameStarSection(&storage, "UTF-8''name", true);
    try std.testing.expectError(error.Malformed, headers.parse(.{}, quoted));
}

test "filename star accepts structured and grandfathered RFC 5646 languages" {
    const valid = [_][]const u8{
        "UTF-8'en'name",
        "UTF-8'zh-Hant'name",
        "UTF-8'en-Latn-US-1901-a-extend1-x-private'name",
        "UTF-8'x-private'name",
        "UTF-8'i-klingon'name",
        "UTF-8'en-GB-oed'name",
        "UTF-8'zh-min-nan'name",
        "UTF-8'sgn-BE-FR'name",
    };
    for (valid) |value| {
        var storage: [512]u8 = undefined;
        const section = try makeFilenameStarSection(&storage, value, false);
        const parsed = try headers.parse(.{}, section);
        try std.testing.expectEqualStrings("name", parsed.filename.?.bytes);
    }
}

test "content type is a strict singleton and rejects duplicate charset" {
    const invalid = [_][]const u8{
        "Content-Type: text\r\n",
        "Content-Type: /plain\r\n",
        "Content-Type: text/\r\n",
        "Content-Type: text/plain;\r\n",
        "Content-Type: text/plain;; charset=utf-8\r\n",
        "Content-Type: text/plain; charset =utf-8\r\n",
        "Content-Type: text/plain; charset= utf-8\r\n",
        "Content-Type: text/plain; charset=\"unterminated\r\n",
        "Content-Type: text/plain; charset=utf-8; CHARSET=utf-8\r\n",
    };
    for (invalid) |field| {
        var storage: [1024]u8 = undefined;
        const section = try sectionWithField(&storage, field);
        try std.testing.expectError(error.Malformed, headers.parse(.{}, section));
    }

    const duplicate =
        "Content-Disposition: form-data; name=x\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "content-type: text/plain\r\n\r\n";
    try expectMalformed(duplicate);
}

test "content transfer encoding is always rejected" {
    const values = [_][]const u8{
        "Content-Transfer-Encoding: base64\r\n",
        "content-transfer-encoding: binary\r\n",
        "CONTENT-TRANSFER-ENCODING:\r\n",
    };
    for (values) |field| {
        var storage: [512]u8 = undefined;
        const section = try sectionWithField(&storage, field);
        try std.testing.expectError(error.Malformed, headers.parse(.{}, section));
    }
}

test "configured byte name filename and parameter limits are inclusive" {
    const base = "Content-Disposition: form-data; name=abc\r\n\r\n";
    var base_storage = base.*;
    _ = try headers.parse(.{
        .header_bytes_max = base.len,
        .name_bytes_max = 3,
    }, &base_storage);
    try expectParseError(error.LimitExceeded, .{
        .header_bytes_max = base.len - 1,
    }, base);
    try expectParseError(error.LimitExceeded, .{ .name_bytes_max = 2 }, base);

    const escaped_name = "Content-Disposition: form-data; name=\"a\\b\\c\"\r\n\r\n";
    var escaped_name_storage = escaped_name.*;
    _ = try headers.parse(.{ .name_bytes_max = 3 }, &escaped_name_storage);
    try expectParseError(error.LimitExceeded, .{ .name_bytes_max = 2 }, escaped_name);

    const filename =
        "Content-Disposition: form-data; name=x; filename=abc\r\n\r\n";
    var filename_storage = filename.*;
    _ = try headers.parse(.{ .filename_bytes_max = 3 }, &filename_storage);
    try expectParseError(error.LimitExceeded, .{ .filename_bytes_max = 2 }, filename);

    const extended =
        "Content-Disposition: form-data; name=x; filename*=UTF-8''%61%62%63\r\n\r\n";
    var extended_storage = extended.*;
    _ = try headers.parse(.{ .filename_bytes_max = 3 }, &extended_storage);
    try expectParseError(error.LimitExceeded, .{ .filename_bytes_max = 2 }, extended);

    const parameters =
        "Content-Disposition: form-data; name=x; a=1\r\n\r\n";
    var parameter_storage = parameters.*;
    _ = try headers.parse(.{ .disposition_parameters_max = 2 }, &parameter_storage);
    try expectParseError(error.LimitExceeded, .{
        .disposition_parameters_max = 1,
    }, parameters);
}

test "maximum standard disposition parameter set is bounded and deterministic" {
    const section =
        "Content-Disposition: form-data; p15=x; p14=x; p13=x; p12=x; p11=x; " ++
        "p10=x; p09=x; p08=x; name=value; p07=x; p06=x; p05=x; p04=x; " ++
        "p03=x; p02=x; p01=x\r\n\r\n";
    var storage = section.*;
    const parsed = try headers.parse(.{ .disposition_parameters_max = 16 }, &storage);
    try std.testing.expectEqualStrings("value", parsed.name);
    try expectParseError(error.LimitExceeded, .{
        .disposition_parameters_max = 15,
    }, section);
}

fn expectMalformed(value: []const u8) !void {
    return expectParseError(error.Malformed, .{}, value);
}

fn expectParseError(
    expected: anyerror,
    comptime limits: headers.Limits,
    value: []const u8,
) !void {
    var storage: [16 * 1024]u8 = undefined;
    if (value.len > storage.len) return error.TestUnexpectedResult;
    @memcpy(storage[0..value.len], value);
    try std.testing.expectError(expected, headers.parse(limits, storage[0..value.len]));
}

fn makeSection(storage: []u8, content_type: []const u8) ![]u8 {
    const prefix = "Content-Disposition: form-data; name=value\r\nContent-Type: ";
    const suffix = "\r\n\r\n";
    return joinThree(storage, prefix, content_type, suffix);
}

fn makeFilenameStarSection(storage: []u8, value: []const u8, quoted: bool) ![]u8 {
    const prefix = "Content-Disposition: form-data; name=file; filename*=";
    const quote: []const u8 = if (quoted) "\"" else "";
    const suffix: []const u8 = if (quoted) "\"\r\n\r\n" else "\r\n\r\n";
    var used: usize = 0;
    for ([_][]const u8{ prefix, quote, value, suffix }) |part| {
        if (part.len > storage.len - used) return error.NoSpaceLeft;
        @memcpy(storage[used..][0..part.len], part);
        used += part.len;
    }
    return storage[0..used];
}

fn sectionWithField(storage: []u8, field: []const u8) ![]u8 {
    return joinThree(
        storage,
        "Content-Disposition: form-data; name=x\r\n",
        field,
        "\r\n",
    );
}

fn joinThree(
    storage: []u8,
    first: []const u8,
    second: []const u8,
    third: []const u8,
) ![]u8 {
    const length = first.len + second.len + third.len;
    if (length > storage.len) return error.NoSpaceLeft;
    @memcpy(storage[0..first.len], first);
    @memcpy(storage[first.len..][0..second.len], second);
    @memcpy(storage[first.len + second.len ..][0..third.len], third);
    return storage[0..length];
}

fn expectWithin(storage: []const u8, value: []const u8) !void {
    const start = @intFromPtr(value.ptr) - @intFromPtr(storage.ptr);
    try std.testing.expect(start <= storage.len);
    try std.testing.expect(value.len <= storage.len - start);
}
