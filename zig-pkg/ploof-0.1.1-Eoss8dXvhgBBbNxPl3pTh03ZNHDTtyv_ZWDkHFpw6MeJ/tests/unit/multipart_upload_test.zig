const std = @import("std");
const multipart = @import("../../src/multipart.zig");

test "upload decisions preserve exact response values" {
    const Response = struct { status: u16, body: []const u8 };
    const accepted = multipart.commit(Response{ .status = 201, .body = "stored" });
    const rejected = multipart.abort(Response{ .status = 422, .body = "rejected" });

    try std.testing.expect(accepted.commits());
    try std.testing.expect(!rejected.commits());
    try std.testing.expectEqual(@as(u16, 201), accepted.response().status);
    try std.testing.expectEqualStrings("rejected", rejected.response().body);
}

test "StorageKey owns exact nested UTF-8 bytes without normalization" {
    const Key = multipart.StorageKey(32);
    var key = try Key.init("users/.résumé/file.bin");

    try std.testing.expectEqualStrings("users/.résumé/file.bin", key.bytes());
    try std.testing.expectEqualStrings("users/.résumé", key.parent().?);
    try std.testing.expectEqualStrings("file.bin", key.basename());
    try std.testing.expectEqual(@as(u8, 0), key.sentinel()[key.bytes().len]);
    try std.testing.expectEqual(@as(usize, 33), @sizeOf(@FieldType(Key, "storage")));
}

test "StorageKey revalidates public storage and repairs its sentinel" {
    const Key = multipart.StorageKey(16);
    var key = try Key.init("safe/file");
    key.storage[0] = '/';
    try std.testing.expectError(error.AbsolutePath, key.validatedCopy());

    key = try Key.init("safe/file");
    key.storage[key.bytes().len] = 'x';
    const copied = try key.validatedCopy();
    try std.testing.expectEqual(@as(u8, 0), copied.storage[copied.bytes().len]);
    try std.testing.expectEqualStrings("safe/file", copied.bytes());
}

test "StorageKey revalidation rejects forged out-of-range length before slicing" {
    const Key = multipart.StorageKey(4);
    var key = try Key.init("safe");
    key.length = @bitCast(@as(u3, 0b111));

    try std.testing.expectError(error.TooLong, key.validatedCopy());
}

test "StorageKey accepts flat and leading-dot components" {
    const Key = multipart.StorageKey(16);
    var flat = try Key.init(".visible");

    try std.testing.expect(flat.parent() == null);
    try std.testing.expectEqualStrings(".visible", flat.basename());
}

test "StorageKey rejects every forbidden syntax class" {
    const Key = multipart.StorageKey(8);
    const cases = [_]struct {
        input: []const u8,
        expected: multipart.StorageKeyError,
    }{
        .{ .input = "", .expected = error.Empty },
        .{ .input = "123456789", .expected = error.TooLong },
        .{ .input = "/a", .expected = error.AbsolutePath },
        .{ .input = "a\xff", .expected = error.InvalidUtf8 },
        .{ .input = "a\x00b", .expected = error.ControlCharacter },
        .{ .input = "a\xc2\x80", .expected = error.ControlCharacter },
        .{ .input = "a//b", .expected = error.EmptyComponent },
        .{ .input = "a/", .expected = error.EmptyComponent },
        .{ .input = "./a", .expected = error.DotComponent },
        .{ .input = "a/../b", .expected = error.DotComponent },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, Key.init(case.input));
    }
}

test "StorageKey exact maximum remains sentinel terminated" {
    const Key = multipart.StorageKey(4);
    var key = try Key.init("abcd");

    try std.testing.expectEqualStrings("abcd", key.bytes());
    try std.testing.expectEqual(@as(u8, 0), key.sentinel()[4]);
}

test "multipart upload profile validates standard and hard bounds" {
    try std.testing.expectEqual(@as(u8, 4), multipart.standard_upload_profile.window);
    try std.testing.expectEqual(
        @as(u32, 16 * 1024),
        multipart.standard_upload_profile.chunk_bytes,
    );
    try std.testing.expectEqual(
        multipart.UploadProfileIssue.window_zero,
        (multipart.UploadProfile{ .window = 0 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.UploadProfileIssue.window_above_hard_max,
        (multipart.UploadProfile{ .window = 17 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.UploadProfileIssue.chunk_bytes_zero,
        (multipart.UploadProfile{ .chunk_bytes = 0 }).issue().?,
    );
    try std.testing.expectEqual(
        multipart.UploadProfileIssue.chunk_bytes_above_hard_max,
        (multipart.UploadProfile{ .chunk_bytes = 1024 * 1024 + 1 }).issue().?,
    );
}
