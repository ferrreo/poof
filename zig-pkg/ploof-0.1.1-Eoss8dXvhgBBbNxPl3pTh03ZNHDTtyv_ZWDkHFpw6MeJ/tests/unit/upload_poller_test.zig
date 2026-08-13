const std = @import("std");
const io = @import("../../src/upload_io.zig");
const upload_poller = @import("../../src/internal/upload/poller.zig");

const file = io.FileHandle.init(4);

test "upload poller admits one valid request" {
    var poller = upload_poller.Poller{};
    try poller.submit(.{ .write = .{ .file = file, .bytes = "abc", .offset = 0 } });
    try std.testing.expectEqual(io.IoKind.write, poller.pendingKind().?);
    try std.testing.expectEqualStrings("abc", poller.pendingRequest().?.write.bytes);
    try std.testing.expectError(
        error.RequestAlreadyPending,
        poller.submit(.{ .sync = .{ .file = file } }),
    );
    try std.testing.expectEqual(io.IoKind.write, poller.pendingKind().?);
}

test "upload poller rejects invalid requests without retaining them" {
    var poller = upload_poller.Poller{};
    try std.testing.expectError(
        error.InvalidRequest,
        poller.submit(.{ .write = .{ .file = file, .bytes = "", .offset = 0 } }),
    );
    try std.testing.expectEqual(@as(?io.IoKind, null), poller.pendingKind());
}

test "upload poller abandons one pending request without poisoning ownership" {
    var poller = upload_poller.Poller{};
    try std.testing.expect(!poller.abandonPending());
    try poller.submit(.{ .write = .{ .file = file, .bytes = "abc", .offset = 4 } });
    try std.testing.expect(poller.abandonPending());
    try std.testing.expectEqual(@as(?io.IoRequest, null), poller.pendingRequest());
    try std.testing.expect(poller.ownershipProven());
    try std.testing.expect(!poller.abandonPending());
}

test "upload poller poisons malformed consumed completions" {
    try expectPoison(error.CompletionKindMismatch, .{ .success = .{ .sync = {} } });
    try expectPoison(error.InvalidSuccess, .{ .success = .{ .write = 0 } });
    try expectPoison(error.CompletionOverflow, .{ .success = .{ .write = 4 } });

    var idle = upload_poller.Poller{};
    try std.testing.expectError(
        error.CompletionWithoutRequest,
        idle.complete(.{ .failure = .canceled }),
    );
    try std.testing.expect(idle.isPoisoned());
}

test "upload poller retries every small short-write partition" {
    const bytes = "abcd";
    for (0..8) |mask| {
        var poller = try writePoller(bytes, 17);
        var previous: usize = 0;
        for (1..bytes.len + 1) |end| {
            const bit = @as(usize, 1) << @intCast(end - 1);
            if (end != bytes.len and mask & bit == 0) continue;
            const step = try poller.complete(.{
                .success = .{ .write = @intCast(end - previous) },
            });
            if (end != bytes.len) {
                try std.testing.expectEqualStrings(bytes[end..], step.retry.write.bytes);
                try std.testing.expectEqual(@as(u64, 17 + end), step.retry.write.offset);
            } else {
                try std.testing.expectEqual(@as(u32, bytes.len), step.deliver.success.write);
            }
            previous = end;
        }
        try std.testing.expect(!poller.isPoisoned());
    }
}

test "upload poller clears partial progress on valid failure" {
    var poller = try writePoller("abcd", 9);
    const retry = try poller.complete(.{ .success = .{ .write = 2 } });
    try std.testing.expectEqual(@as(u64, 11), retry.retry.write.offset);
    const delivery = try poller.complete(.{ .failure = .no_space });
    try std.testing.expectEqual(io.IoError.no_space, delivery.deliver.failure);
    try std.testing.expectEqual(@as(?io.IoKind, null), poller.pendingKind());
    try std.testing.expect(poller.ownershipProven());

    try poller.submit(.{ .sync = .{ .file = file } });
    _ = try poller.complete(.{ .success = .{ .sync = {} } });
}

fn writePoller(bytes: []const u8, offset: u64) upload_poller.SubmitError!upload_poller.Poller {
    var poller = upload_poller.Poller{};
    try poller.submit(.{ .write = .{ .file = file, .bytes = bytes, .offset = offset } });
    return poller;
}

fn expectPoison(expected: anyerror, completion: io.IoCompletion) !void {
    var poller = try writePoller("abc", 0);
    try std.testing.expectError(expected, poller.complete(completion));
    try std.testing.expect(poller.isPoisoned());
    try std.testing.expect(!poller.ownershipProven());
    try std.testing.expectEqual(@as(?io.IoRequest, null), poller.pendingRequest());
    try std.testing.expectError(
        error.Poisoned,
        poller.submit(.{ .sync = .{ .file = file } }),
    );
    try std.testing.expectError(error.Poisoned, poller.complete(.{ .failure = .canceled }));
}
