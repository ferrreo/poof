const std = @import("std");

const multipart = @import("../../src/multipart.zig");

const anonymous_buffered = multipart.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .buffered,
};
const anonymous_durable = multipart.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .crash_durable,
};
const named_buffered = multipart.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .buffered,
    .staging = .{ .named_staging = ".stage" },
};
const named_durable = multipart.FileSinkConfig{
    .root = "/srv/uploads",
    .durability = .crash_durable,
    .staging = .{ .named_staging = ".stage" },
};

test "public FileSink satisfies the multipart sink contract in all four modes" {
    inline for (.{
        anonymous_buffered,
        anonymous_durable,
        named_buffered,
        named_durable,
    }) |supplied| {
        const Sink = multipart.FileSink(supplied);
        comptime multipart.validateSink(Sink);
        try std.testing.expect(Sink.ploof_multipart_sink);
        try std.testing.expectEqual(@as(u8, 2), Sink.request_handles_max);
        try std.testing.expectEqual(
            @as(u8, if (supplied.staging == .named_staging) 3 else 2),
            Sink.runtime_handles_max,
        );
        try std.testing.expectEqual(
            if (supplied.staging == .named_staging)
                multipart.FileStagingKind.named_staging
            else
                multipart.FileStagingKind.anonymous_required,
            Sink.startup_report.staging,
        );
        try std.testing.expectEqual(supplied.durability.?, Sink.startup_report.durability);
        try std.testing.expectEqual(@as(u32, 0), Sink.startup_report.live_anonymous);
        try std.testing.expectEqual(@as(u32, 0), Sink.startup_report.live_named);
        try std.testing.expect(Sink.startupFailure(&Sink.initial_startup_state) == null);
    }
}

test "public FileSink report is fixed-size and contains no configured paths" {
    const fields = @typeInfo(multipart.FileSinkReport).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(multipart.FileSinkReport));
    try std.testing.expect(fields[0].type == multipart.FileStagingKind);
    try std.testing.expect(fields[1].type == multipart.FileDurability);
    try std.testing.expect(fields[2].type == u32);
    try std.testing.expect(fields[3].type == u32);

    const Sink = multipart.FileSink(named_durable);
    var runtime: Sink.Runtime = undefined;
    runtime.live_anonymous = 0;
    runtime.live_named = 3;
    const report = Sink.report(&runtime);
    try std.testing.expectEqual(multipart.FileStagingKind.named_staging, report.staging);
    try std.testing.expectEqual(multipart.FileDurability.crash_durable, report.durability);
    try std.testing.expectEqual(@as(u32, 0), report.live_anonymous);
    try std.testing.expectEqual(@as(u32, 3), report.live_named);
}

test "public FileSink exposes exact capabilities and bounded server keys" {
    const Anonymous = multipart.FileSink(anonymous_durable);
    try std.testing.expect(Anonymous.io_requirements.open);
    try std.testing.expect(Anonymous.io_requirements.write);
    try std.testing.expect(Anonymous.io_requirements.close);
    try std.testing.expect(Anonymous.io_requirements.link);
    try std.testing.expect(Anonymous.io_requirements.unlink);
    try std.testing.expect(Anonymous.io_requirements.sync);
    try std.testing.expect(!Anonymous.io_requirements.rename_no_replace);

    const Named = multipart.FileSink(named_buffered);
    try std.testing.expect(Named.io_requirements.open);
    try std.testing.expect(Named.io_requirements.write);
    try std.testing.expect(Named.io_requirements.close);
    try std.testing.expect(!Named.io_requirements.link);
    try std.testing.expect(Named.io_requirements.unlink);
    try std.testing.expect(!Named.io_requirements.sync);
    try std.testing.expect(Named.io_requirements.rename_no_replace);

    const key = try Named.Key.init("avatars/account.bin");
    try std.testing.expectEqualStrings("avatars/account.bin", key.bytes());
    try std.testing.expectEqual(@as(usize, 4095), multipart.storage_key_bytes_hard_max);
}
