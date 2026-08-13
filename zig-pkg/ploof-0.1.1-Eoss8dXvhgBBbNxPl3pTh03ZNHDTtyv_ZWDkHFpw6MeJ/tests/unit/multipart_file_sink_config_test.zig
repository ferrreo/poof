const std = @import("std");
const config = @import("../../src/multipart/file_sink_config.zig");
const upload_io = @import("../../src/upload_io.zig");

const standard = config.FileSinkConfig{
    .root = "/var/lib/ploof/uploads",
    .durability = .buffered,
};

test "FileSink config validation has stable diagnostics" {
    const cases = [_]struct {
        supplied: config.FileSinkConfig,
        issue: config.ConfigIssue,
    }{
        .{ .supplied = .{ .root = "", .durability = .buffered }, .issue = .root_empty },
        .{
            .supplied = .{ .root = "\xff", .durability = .buffered },
            .issue = .root_invalid_utf8,
        },
        .{
            .supplied = .{ .root = "bad\x00root", .durability = .buffered },
            .issue = .root_control_character,
        },
        .{
            .supplied = .{
                .root = &([_]u8{'a'} ** (config.root_bytes_hard_max + 1)),
                .durability = .buffered,
            },
            .issue = .root_above_hard_max,
        },
        .{
            .supplied = .{
                .root = "uploads",
                .storage_key_bytes_max = 0,
                .durability = .buffered,
            },
            .issue = .storage_key_max_zero,
        },
        .{
            .supplied = .{
                .root = "uploads",
                .storage_key_bytes_max = std.math.maxInt(usize),
                .durability = .buffered,
            },
            .issue = .storage_key_max_address_space,
        },
        .{
            .supplied = .{
                .root = "uploads",
                .storage_key_bytes_max = config.storage_key_bytes_hard_max + 1,
                .durability = .buffered,
            },
            .issue = .storage_key_max_hard_limit,
        },
        .{ .supplied = .{ .root = "uploads" }, .issue = .durability_required },
        .{
            .supplied = .{
                .root = "uploads",
                .durability = .buffered,
                .staging = .{ .named_staging = "../escape" },
            },
            .issue = .named_staging_invalid,
        },
        .{
            .supplied = .{ .root = "uploads", .durability = .buffered, .mode = 0 },
            .issue = .mode_invalid,
        },
        .{
            .supplied = .{ .root = "uploads", .durability = .buffered, .mode = 0o1000 },
            .issue = .mode_invalid,
        },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.issue, config.configIssue(case.supplied).?);
        try std.testing.expect(std.mem.startsWith(u8, case.issue.diagnostic(), "PLOOF-E35"));
    }
    try std.testing.expectEqual(@as(?config.ConfigIssue, null), config.configIssue(standard));
}

test "root accepts relative or absolute UTF-8 without rewriting" {
    for ([_][]const u8{ "uploads", "/srv/uploads", "保管/受信" }) |root| {
        const supplied = config.FileSinkConfig{ .root = root, .durability = .buffered };
        try std.testing.expectEqual(@as(?config.ConfigIssue, null), config.configIssue(supplied));
    }
    for ([_][]const u8{ "bad\x1fpath", "bad\xc2\x80path" }) |root| {
        const supplied = config.FileSinkConfig{ .root = root, .durability = .buffered };
        try std.testing.expectEqual(
            config.ConfigIssue.root_control_character,
            config.configIssue(supplied).?,
        );
    }

    const maximum = [_]u8{'a'} ** config.root_bytes_hard_max;
    const supplied = config.FileSinkConfig{ .root = &maximum, .durability = .buffered };
    try std.testing.expectEqual(@as(?config.ConfigIssue, null), config.configIssue(supplied));
}

test "named staging uses exact StorageKey syntax" {
    for ([_][]const u8{ ".ploof-staging", "private/uploads", "受信/.stage" }) |path| {
        const supplied = config.FileSinkConfig{
            .root = "uploads",
            .durability = .buffered,
            .staging = .{ .named_staging = path },
        };
        try std.testing.expectEqual(@as(?config.ConfigIssue, null), config.configIssue(supplied));
    }
    for ([_][]const u8{ "", "/absolute", "a//b", "a/", ".", "a/../b", "a\x00b" }) |path| {
        const supplied = config.FileSinkConfig{
            .root = "uploads",
            .durability = .buffered,
            .staging = .{ .named_staging = path },
        };
        try std.testing.expectEqual(
            config.ConfigIssue.named_staging_invalid,
            config.configIssue(supplied).?,
        );
    }

    const too_long = [_]u8{'a'} ** (config.storage_key_bytes_hard_max + 1);
    const supplied = config.FileSinkConfig{
        .root = "uploads",
        .durability = .buffered,
        .staging = .{ .named_staging = &too_long },
    };
    try std.testing.expectEqual(
        config.ConfigIssue.named_staging_invalid,
        config.configIssue(supplied).?,
    );
}

test "Resolved materializes sentinel paths and exact types" {
    const Anonymous = config.Resolved(standard);
    try std.testing.expectEqualStrings(standard.root, Anonymous.root_z);
    try std.testing.expectEqual(@as(u8, 0), Anonymous.root_z.ptr[Anonymous.root_z.len]);
    try std.testing.expectEqual(@as(?[:0]const u8, null), Anonymous.staging_z);
    try std.testing.expect(!Anonymous.named);
    try std.testing.expect(!Anonymous.durable);
    try std.testing.expectEqual(@as(usize, 256), Anonymous.Key.bytes_maximum);

    const Named = config.Resolved(.{
        .root = "uploads",
        .storage_key_bytes_max = 1024,
        .durability = .crash_durable,
        .staging = .{ .named_staging = ".private/stage" },
        .mode = 0o640,
    });
    try std.testing.expectEqualStrings("uploads", Named.root_z);
    try std.testing.expectEqualStrings(".private/stage", Named.staging_z.?);
    try std.testing.expectEqual(@as(u8, 0), Named.staging_z.?.ptr[Named.staging_z.?.len]);
    try std.testing.expect(Named.named);
    try std.testing.expect(Named.durable);
    try std.testing.expectEqual(@as(usize, 1024), Named.Key.bytes_maximum);
    try std.testing.expectEqual(@as(u16, 0o640), Named.config.mode);
}

test "I/O requirements and handle maxima are exact for every mode" {
    const expected = [_]struct {
        named: bool,
        durable: bool,
        bits: u8,
        runtime_handles: u8,
    }{
        .{ .named = false, .durable = false, .bits = 0b0001_1111, .runtime_handles = 2 },
        .{ .named = false, .durable = true, .bits = 0b0101_1111, .runtime_handles = 2 },
        .{ .named = true, .durable = false, .bits = 0b0011_0111, .runtime_handles = 3 },
        .{ .named = true, .durable = true, .bits = 0b0111_0111, .runtime_handles = 3 },
    };
    for (expected) |case| {
        const requirements = config.requirementsFor(case.named, case.durable);
        try std.testing.expectEqual(case.bits, @as(u8, @bitCast(requirements)));
        try std.testing.expect(requirements.valid());
    }

    const Anonymous = config.Resolved(standard);
    const Named = config.Resolved(.{
        .root = "uploads",
        .durability = .buffered,
        .staging = .{ .named_staging = ".stage" },
    });
    try std.testing.expectEqual(@as(u8, 2), Anonymous.request_handles_max);
    try std.testing.expectEqual(@as(u8, 2), Anonymous.runtime_handles_max);
    try std.testing.expectEqual(@as(u8, 2), Named.request_handles_max);
    try std.testing.expectEqual(@as(u8, 3), Named.runtime_handles_max);
}

test "File I/O errors map exhaustively and one-to-one" {
    const failures = std.enums.values(upload_io.IoError);
    for (failures, 0..) |failure, index| {
        const mapped = config.mapIoError(failure);
        for (failures[0..index]) |previous| {
            try std.testing.expect(mapped != config.mapIoError(previous));
        }
    }
    try std.testing.expectEqual(error.Canceled, config.mapIoError(.canceled));
    try std.testing.expectEqual(error.AlreadyExists, config.mapIoError(.already_exists));
    try std.testing.expectEqual(error.IoFailure, config.mapIoError(.io_failure));
}

test "name generation is deterministic, unique, and correctly formatted" {
    const Resolved = config.Resolved(standard);
    const entropy = [_]u8{0x5a} ** 32;
    var first = Resolved.NameGenerator.init(&entropy, 7);
    defer first.deinit();
    var second = Resolved.NameGenerator.init(&entropy, 7);
    defer second.deinit();
    var observed: [64]config.Name = undefined;
    for (&observed, 0..) |*slot, index| {
        const kind: config.NameKind = switch (index % 3) {
            0 => .stage,
            1 => .probe_stage,
            else => .probe_final,
        };
        slot.* = try first.next(kind);
        const duplicate = try second.next(kind);
        try std.testing.expectEqualStrings(slot.bytes(), duplicate.bytes());
        try expectNameFormat(slot, kind);
        for (observed[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, slot.bytes(), previous.bytes()));
        }
    }
}

test "name key derivation separates entropy worker and canonical config" {
    const Base = config.Resolved(standard);
    const OtherRoot = config.Resolved(.{
        .root = "/var/lib/ploof/upload",
        .durability = .buffered,
    });
    const Named = config.Resolved(.{
        .root = "/var/lib/ploof/uploads",
        .durability = .buffered,
        .staging = .{ .named_staging = ".stage" },
    });
    var base = Base.NameGenerator.init(&([_]u8{1} ** 32), 3);
    defer base.deinit();
    var entropy = Base.NameGenerator.init(&([_]u8{2} ** 32), 3);
    defer entropy.deinit();
    var worker = Base.NameGenerator.init(&([_]u8{1} ** 32), 4);
    defer worker.deinit();
    var root = OtherRoot.NameGenerator.init(&([_]u8{1} ** 32), 3);
    defer root.deinit();
    var named = Named.NameGenerator.init(&([_]u8{1} ** 32), 3);
    defer named.deinit();
    const baseline = try base.next(.stage);
    const entropy_name = try entropy.next(.stage);
    const worker_name = try worker.next(.stage);
    const root_name = try root.next(.stage);
    const named_name = try named.next(.stage);
    try expectDifferentName(&baseline, &entropy_name);
    try expectDifferentName(&baseline, &worker_name);
    try expectDifferentName(&baseline, &root_name);
    try expectDifferentName(&baseline, &named_name);
}

test "name kind separates both namespace and pseudorandom suffix" {
    const Resolved = config.Resolved(standard);
    const entropy = [_]u8{0xa5} ** 32;
    var stage = Resolved.NameGenerator.init(&entropy, 0);
    defer stage.deinit();
    var probe = Resolved.NameGenerator.init(&entropy, 0);
    defer probe.deinit();
    const stage_name = try stage.next(.stage);
    const probe_name = try probe.next(.probe_stage);
    try expectDifferentName(&stage_name, &probe_name);
    try std.testing.expect(!std.mem.eql(
        u8,
        stage_name.bytes()[config.stage_name_prefix.len..],
        probe_name.bytes()[config.probe_stage_name_prefix.len..],
    ));
}

test "name generator deinit clears key and counter" {
    const Resolved = config.Resolved(standard);
    var generator = Resolved.NameGenerator.init(&([_]u8{0x3c} ** 32), 19);
    _ = try generator.next(.stage);
    generator.deinit();
    for (std.mem.asBytes(&generator)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Resolved.NameGenerator));
    try std.testing.expectEqualStrings("", config.Name.empty.sentinel());
}

test "name sequence fails before its counter can wrap" {
    const Resolved = config.Resolved(standard);
    var generator = Resolved.NameGenerator.init(&([_]u8{0x7e} ** 32), 5);
    defer generator.deinit();
    generator.counter = std.math.maxInt(u64) - 1;
    _ = try generator.next(.stage);
    try std.testing.expectEqual(std.math.maxInt(u64), generator.counter);
    try std.testing.expectError(error.NameSequenceExhausted, generator.next(.stage));
    try std.testing.expectEqual(std.math.maxInt(u64), generator.counter);
}

fn expectNameFormat(name: *const config.Name, kind: config.NameKind) !void {
    const prefix = kind.prefix();
    try std.testing.expectEqual(prefix.len + config.random_name_hex_bytes, name.bytes().len);
    try std.testing.expect(std.mem.startsWith(u8, name.bytes(), prefix));
    try std.testing.expectEqual(@as(u8, 0), name.sentinel().ptr[name.sentinel().len]);
    for (name.bytes()[prefix.len..]) |byte| {
        try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
    }
}

fn expectDifferentName(left: *const config.Name, right: *const config.Name) !void {
    try std.testing.expect(!std.mem.eql(u8, left.bytes(), right.bytes()));
}
