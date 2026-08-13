const std = @import("std");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");

const Accepted = reactor.Accepted;
const BorrowedReceive = reactor.BorrowedReceive;
const BorrowedReceiveIdentity = reactor.BorrowedReceiveIdentity;
const BorrowedReceiveIdentityIssue = reactor.BorrowedReceiveIdentityIssue;
const Completion = reactor.Completion;
const CompletionError = reactor.CompletionError;
const CompletionIssue = reactor.CompletionIssue;
const FileDescriptor = reactor.FileDescriptor;
const OperationKind = reactor.OperationKind;
const OperationToken = reactor.OperationToken;
const SlotIdentity = reactor.SlotIdentity;
const Socket = reactor.Socket;
const Submission = reactor.Submission;
const SubmissionIssue = reactor.SubmissionIssue;
const TokenFields = reactor.TokenFields;
const max_worker_index = reactor.max_worker_index;
const max_sequence = reactor.max_sequence;
const nextGeneration = reactor.nextGeneration;
const nextSequence = reactor.nextSequence;
const stream_wake_control_slot = reactor.stream_wake_control_slot;
const upload_runtime_control_slot = reactor.upload_runtime_control_slot;
const wake_control_slot = reactor.wake_control_slot;

fn testToken(
    kind: OperationKind,
    worker_index: u16,
    slot_index: u16,
    slot_generation: u16,
    sequence: u16,
) OperationToken {
    return OperationToken.init(.{
        .kind = kind,
        .worker_index = worker_index,
        .slot_index = slot_index,
        .slot_generation = slot_generation,
        .sequence = sequence,
    }) catch unreachable;
}

fn testReceive(token: OperationToken, bytes: []const u8) BorrowedReceive {
    return .{
        .identity = .{
            .owner = token.slot() catch unreachable,
            .buffer_index = 9,
            .buffer_generation = 3,
        },
        .bytes = bytes,
    };
}

test "operation token boundaries round trip exactly" {
    const minimum = try OperationToken.init(.{
        .kind = .accept,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try std.testing.expectEqual(@as(u64, 0x0002_0002_0000_0001), minimum.raw());
    try std.testing.expectEqualDeep(TokenFields{
        .kind = .accept,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    }, try minimum.fields());

    const maximum = try OperationToken.init(.{
        .kind = .file_cancel,
        .worker_index = max_worker_index,
        .slot_index = std.math.maxInt(u16),
        .slot_generation = std.math.maxInt(u16),
        .sequence = max_sequence,
    });
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_ffff_fff2), maximum.raw());
    try std.testing.expectEqual(maximum.raw(), (try OperationToken.fromRaw(maximum.raw())).raw());
}

test "operation token tags occupy every assigned nonzero value" {
    const valid_tail: u64 = 0x0002_0002_0000_0000;
    try std.testing.expectError(error.InvalidKind, OperationToken.fromRaw(valid_tail));
    for (1..19) |kind_value| {
        const slot_bits = if (kind_value == @intFromEnum(OperationKind.wake))
            @as(u64, wake_control_slot) << 17
        else
            0;
        const token = try OperationToken.fromRaw(
            valid_tail | slot_bits | @as(u64, @intCast(kind_value)),
        );
        try std.testing.expectEqual(@as(u5, @intCast(kind_value)), @intFromEnum(
            (try token.fields()).kind,
        ));
    }
    try std.testing.expectError(error.ZeroSlotGeneration, OperationToken.fromRaw(0x0001));
    try std.testing.expectError(
        error.ZeroSequence,
        OperationToken.fromRaw(0x0000_0002_0000_0001),
    );
    try std.testing.expectError(error.SequenceOutOfRange, OperationToken.init(.{
        .kind = .receive,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = max_sequence + 1,
    }));
    try std.testing.expectError(error.WorkerIndexOutOfRange, OperationToken.init(.{
        .kind = .receive,
        .worker_index = max_worker_index + 1,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    }));
    const wake = testToken(.wake, 0, wake_control_slot, 1, 1);
    const stream_wake = testToken(.wake, 0, stream_wake_control_slot, 1, 1);
    try std.testing.expectEqual(wake_control_slot, (try wake.fields()).slot_index);
    try std.testing.expectEqual(stream_wake_control_slot, (try stream_wake.fields()).slot_index);
    try std.testing.expect(wake_control_slot != stream_wake_control_slot);
    try std.testing.expect(upload_runtime_control_slot != wake_control_slot);
    try std.testing.expect(upload_runtime_control_slot != stream_wake_control_slot);
    const upload = testToken(.file_open, 0, upload_runtime_control_slot, 1, 1);
    try std.testing.expectEqual(upload_runtime_control_slot, (try upload.fields()).slot_index);
    try std.testing.expectError(error.InvalidWakeSlot, OperationToken.init(.{
        .kind = .wake,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    }));
}

test "slot generation rejects stale operation tokens" {
    const token = testToken(.receive, 7, 11, 19, 23);
    const current = SlotIdentity{ .worker_index = 7, .index = 11, .generation = 19 };
    try std.testing.expect(token.isCurrentFor(current));
    try std.testing.expect(!token.isCurrentFor(.{
        .worker_index = 7,
        .index = 11,
        .generation = 20,
    }));
    try std.testing.expect(!token.isCurrentFor(.{
        .worker_index = 7,
        .index = 12,
        .generation = 19,
    }));
    try std.testing.expect(!token.isCurrentFor(.{
        .worker_index = 8,
        .index = 11,
        .generation = 19,
    }));
    try std.testing.expect(!token.isCurrentFor(.{
        .worker_index = 7,
        .index = 11,
        .generation = 0,
    }));

    const next = testToken(.receive, 7, 11, 19, 24);
    try std.testing.expect(next.isCurrentFor(current));
    try std.testing.expect(!next.eql(token));
}

test "sequence and generation wrap without using reserved zero" {
    try std.testing.expectEqual(@as(u16, 2), nextSequence(1));
    try std.testing.expectEqual(@as(u16, 1), nextSequence(max_sequence));
    try std.testing.expectEqual(@as(u16, 2), nextGeneration(1));
    try std.testing.expectEqual(@as(u16, 1), nextGeneration(std.math.maxInt(u16)));
}

test "borrowed receive identity detects owner and buffer reuse" {
    const owner = SlotIdentity{ .worker_index = 2, .index = 3, .generation = 4 };
    const identity = BorrowedReceiveIdentity{
        .owner = owner,
        .buffer_index = 5,
        .buffer_generation = 6,
    };
    try std.testing.expect(identity.validate() == null);
    try std.testing.expect(identity.isCurrent(owner, 6));
    try std.testing.expect(!identity.isCurrent(owner, 7));
    try std.testing.expect(!identity.isCurrent(.{
        .worker_index = 2,
        .index = 3,
        .generation = 5,
    }, 6));

    var invalid = identity;
    invalid.buffer_generation = 0;
    try std.testing.expectEqual(
        BorrowedReceiveIdentityIssue.zero_buffer_generation,
        invalid.validate().?,
    );
}

test "submission validation covers all operation shapes" {
    const socket = Socket{ .value = 7 };
    const file = FileDescriptor{ .value = 4 };
    const directory = FileDescriptor{ .value = 5 };
    const bytes = "hello";
    var read_buffer: [16]u8 = undefined;
    var statx: std.os.linux.Statx = undefined;
    const receive_token = testToken(.receive, 1, 2, 3, 4);
    const file_write_token = testToken(.file_write, 1, 2, 3, 11);
    const cases = [_]Submission{
        .{ .token = testToken(.accept, 1, 0, 1, 1), .operation = .{
            .accept = .{ .listener = socket },
        } },
        .{ .token = receive_token, .operation = .{ .receive = .{ .socket = socket } } },
        .{ .token = testToken(.send, 1, 2, 3, 5), .operation = .{
            .send = .{ .socket = socket, .bytes = bytes },
        } },
        .{ .token = testToken(.close, 1, 2, 3, 6), .operation = .{
            .close = .{ .socket = socket },
        } },
        .{ .token = testToken(.timeout, 1, 2, 3, 7), .operation = .{
            .timeout = .{ .deadline_ns = 1 },
        } },
        .{ .token = testToken(.cancel, 1, 2, 3, 8), .operation = .{
            .cancel = .{ .target = receive_token },
        } },
        .{ .token = testToken(.wake, 1, wake_control_slot, 3, 9), .operation = .{
            .wake = .{ .source = .{ .value = 9 } },
        } },
        .{ .token = testToken(.file_open, 1, 2, 3, 10), .operation = .{
            .file_open = .{
                .base = .working_directory,
                .path = "/srv/ploof/uploads",
                .access = .read_only,
                .kind = .directory,
            },
        } },
        .{ .token = file_write_token, .operation = .{ .file_write = .{
            .file = file,
            .bytes = bytes,
            .offset = 9,
        } } },
        .{ .token = testToken(.file_close, 1, 2, 3, 12), .operation = .{
            .file_close = .{ .file = file },
        } },
        .{ .token = testToken(.file_link, 1, 2, 3, 13), .operation = .{
            .file_link = .{
                .source = file,
                .target_directory = directory,
                .target_path = "part.bin",
            },
        } },
        .{ .token = testToken(.file_unlink, 1, 2, 3, 14), .operation = .{
            .file_unlink = .{ .directory = directory, .path = "part.bin" },
        } },
        .{ .token = testToken(.file_rename_no_replace, 1, 2, 3, 15), .operation = .{
            .file_rename_no_replace = .{
                .source_directory = directory,
                .source_path = "part.bin",
                .target_directory = directory,
                .target_path = "done.bin",
            },
        } },
        .{ .token = testToken(.file_sync, 1, 2, 3, 16), .operation = .{
            .file_sync = .{ .file = file },
        } },
        .{ .token = testToken(.upload_cancel, 1, 2, 3, 17), .operation = .{
            .upload_cancel = .{ .target = file_write_token },
        } },
        .{ .token = testToken(.file_read, 1, 2, 3, 18), .operation = .{
            .file_read = .{ .file = file, .bytes = &read_buffer, .offset = 0 },
        } },
        .{ .token = testToken(.file_stat, 1, 2, 3, 19), .operation = .{
            .file_stat = .{ .file = file, .output = &statx },
        } },
        .{ .token = testToken(.file_cancel, 1, 2, 3, 20), .operation = .{
            .file_cancel = .{ .target = testToken(.file_read, 1, 2, 3, 18) },
        } },
    };
    for (cases) |case| try std.testing.expect(case.validate() == null);

    var changed = cases[2];
    changed.token = receive_token;
    try std.testing.expectEqual(SubmissionIssue.token_kind_mismatch, changed.validate().?);
    changed = cases[2];
    changed.operation.send.bytes = "";
    try std.testing.expectEqual(SubmissionIssue.empty_send, changed.validate().?);
    changed = cases[4];
    changed.operation.timeout.deadline_ns = 0;
    try std.testing.expectEqual(SubmissionIssue.zero_deadline, changed.validate().?);
}

test "file submission validation rejects unsafe descriptors paths and ranges" {
    const file = FileDescriptor{ .value = 6 };
    const directory = FileDescriptor{ .value = 7 };
    var submission = Submission{
        .token = testToken(.file_open, 1, 2, 3, 4),
        .operation = .{ .file_open = .{
            .base = .{ .directory = directory },
            .path = "part.bin",
            .access = .write_only,
        } },
    };

    submission.operation.file_open.base = .{ .directory = .{ .value = -1 } };
    try std.testing.expectEqual(SubmissionIssue.invalid_file_descriptor, submission.validate().?);
    submission.operation.file_open.base = .working_directory;
    submission.operation.file_open.path = "";
    try std.testing.expectEqual(SubmissionIssue.empty_file_path, submission.validate().?);
    submission.operation.file_open.path = "/tmp/uploads";
    submission.operation.file_open.resolve.beneath = true;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );
    submission.operation.file_open.base = .{ .directory = directory };
    submission.operation.file_open.resolve.beneath = false;
    try std.testing.expectEqual(SubmissionIssue.absolute_file_path, submission.validate().?);
    submission.operation.file_open.path = "bad\x00path";
    try std.testing.expectEqual(SubmissionIssue.file_path_contains_nul, submission.validate().?);
    submission.operation.file_open.path = "part.bin";
    submission.operation.file_open.mode = 0o1000;
    try std.testing.expectEqual(SubmissionIssue.invalid_file_mode, submission.validate().?);
    submission.operation.file_open.mode = 0o600;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );
    submission.operation.file_open.create = .exclusive;
    submission.operation.file_open.mode = 0;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );
    submission.operation.file_open.mode = 0o600;
    submission.operation.file_open.access = .read_only;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );
    submission.operation.file_open.create = .anonymous;
    submission.operation.file_open.access = .write_only;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );
    submission.operation.file_open.create = .exclusive;
    submission.operation.file_open.access = .write_only;
    submission.operation.file_open.kind = .directory;
    try std.testing.expectEqual(
        SubmissionIssue.invalid_file_open_combination,
        submission.validate().?,
    );

    submission = .{
        .token = testToken(.file_write, 1, 2, 3, 5),
        .operation = .{ .file_write = .{ .file = file, .bytes = "x", .offset = 0 } },
    };
    submission.operation.file_write.bytes = "";
    try std.testing.expectEqual(SubmissionIssue.empty_file_write, submission.validate().?);
    const bytes: [*]const u8 = "x";
    const too_large_len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    submission.operation.file_write.bytes = bytes[0..too_large_len];
    try std.testing.expectEqual(SubmissionIssue.file_write_too_large, submission.validate().?);
    submission.operation.file_write.bytes = "x";
    submission.operation.file_write.offset = std.math.maxInt(i64) - 1;
    try std.testing.expect(submission.validate() == null);
    submission.operation.file_write.offset = std.math.maxInt(i64);
    try std.testing.expectEqual(SubmissionIssue.file_write_overflow, submission.validate().?);
    submission.operation.file_write.offset = std.math.maxInt(u64);
    try std.testing.expectEqual(SubmissionIssue.file_write_overflow, submission.validate().?);

    var read_buffer: [1]u8 = undefined;
    submission = .{
        .token = testToken(.file_read, 1, 2, 3, 6),
        .operation = .{ .file_read = .{ .file = file, .bytes = &read_buffer, .offset = 0 } },
    };
    submission.operation.file_read.bytes = read_buffer[0..0];
    try std.testing.expectEqual(SubmissionIssue.empty_file_read, submission.validate().?);
    const read_bytes: [*]u8 = &read_buffer;
    submission.operation.file_read.bytes = read_bytes[0 .. @as(usize, std.math.maxInt(u32)) + 1];
    try std.testing.expectEqual(SubmissionIssue.file_read_too_large, submission.validate().?);
    submission.operation.file_read.bytes = &read_buffer;
    submission.operation.file_read.offset = std.math.maxInt(i64);
    try std.testing.expectEqual(SubmissionIssue.file_read_overflow, submission.validate().?);
}

test "file path operations reject invalid destination paths" {
    const file = FileDescriptor{ .value = 8 };
    const directory = FileDescriptor{ .value = 9 };
    var submission = Submission{
        .token = testToken(.file_link, 1, 2, 3, 4),
        .operation = .{ .file_link = .{
            .source = file,
            .target_directory = directory,
            .target_path = "target",
        } },
    };
    try std.testing.expect(submission.validate() == null);
    submission.operation.file_link.target_path = "/target";
    try std.testing.expectEqual(SubmissionIssue.absolute_file_path, submission.validate().?);

    submission = .{
        .token = testToken(.file_unlink, 1, 2, 3, 5),
        .operation = .{ .file_unlink = .{ .directory = directory, .path = "" } },
    };
    try std.testing.expectEqual(SubmissionIssue.empty_file_path, submission.validate().?);
    submission = .{
        .token = testToken(.file_rename_no_replace, 1, 2, 3, 6),
        .operation = .{ .file_rename_no_replace = .{
            .source_directory = directory,
            .source_path = "source",
            .target_directory = .{ .value = -1 },
            .target_path = "target",
        } },
    };
    try std.testing.expectEqual(SubmissionIssue.invalid_file_descriptor, submission.validate().?);
}

test "cancel validation rejects ambiguous lifetime" {
    const token = testToken(.cancel, 1, 2, 3, 4);
    var submission = Submission{ .token = token, .operation = .{
        .cancel = .{ .target = token },
    } };
    try std.testing.expectEqual(SubmissionIssue.cancel_self, submission.validate().?);

    submission.operation.cancel.target = testToken(.cancel, 1, 2, 3, 5);
    try std.testing.expectEqual(SubmissionIssue.cancel_of_cancel, submission.validate().?);
    submission.operation.cancel.target = testToken(.receive, 2, 2, 3, 5);
    try std.testing.expectEqual(SubmissionIssue.cross_worker_cancel, submission.validate().?);
    submission.operation.cancel.target = testToken(.file_write, 1, 2, 3, 5);
    try std.testing.expectEqual(
        SubmissionIssue.cancel_of_file_operation,
        submission.validate().?,
    );
    submission.operation.cancel.target = testToken(.upload_cancel, 1, 2, 3, 5);
    try std.testing.expectEqual(SubmissionIssue.cancel_of_cancel, submission.validate().?);
    submission.operation.cancel.target = .{ .raw_value = 0 };
    try std.testing.expectEqual(SubmissionIssue.invalid_cancel_target, submission.validate().?);
}

test "upload cancellation is confined to one file operation owner" {
    const kinds = [_]OperationKind{
        .file_open,
        .file_write,
        .file_close,
        .file_link,
        .file_unlink,
        .file_rename_no_replace,
        .file_sync,
    };
    const cancel_token = testToken(.upload_cancel, 1, 2, 3, 20);
    for (kinds, 1..) |kind, sequence| {
        const submission = Submission{ .token = cancel_token, .operation = .{
            .upload_cancel = .{ .target = testToken(kind, 1, 2, 3, @intCast(sequence)) },
        } };
        try std.testing.expect(reactor.isUploadFileOperation(kind));
        try std.testing.expect(submission.validate() == null);
    }
    try std.testing.expect(!reactor.isUploadFileOperation(.receive));
    try std.testing.expect(!reactor.isUploadFileOperation(.upload_cancel));

    var submission = Submission{ .token = cancel_token, .operation = .{
        .upload_cancel = .{ .target = testToken(.receive, 1, 2, 3, 21) },
    } };
    try std.testing.expectEqual(
        SubmissionIssue.upload_cancel_target_not_file,
        submission.validate().?,
    );
    submission.operation.upload_cancel.target = testToken(.file_write, 2, 2, 3, 21);
    try std.testing.expectEqual(
        SubmissionIssue.upload_cancel_owner_mismatch,
        submission.validate().?,
    );
    submission.operation.upload_cancel.target = testToken(.file_write, 1, 4, 3, 21);
    try std.testing.expectEqual(
        SubmissionIssue.upload_cancel_owner_mismatch,
        submission.validate().?,
    );
    submission.operation.upload_cancel.target = testToken(.file_write, 1, 2, 4, 21);
    try std.testing.expectEqual(
        SubmissionIssue.upload_cancel_owner_mismatch,
        submission.validate().?,
    );
    submission.operation.upload_cancel.target = testToken(.cancel, 1, 2, 3, 21);
    try std.testing.expectEqual(SubmissionIssue.cancel_of_cancel, submission.validate().?);
    submission.operation.upload_cancel.target = testToken(.upload_cancel, 1, 2, 3, 21);
    try std.testing.expectEqual(SubmissionIssue.cancel_of_cancel, submission.validate().?);
    submission.operation.upload_cancel.target = cancel_token;
    try std.testing.expectEqual(SubmissionIssue.cancel_self, submission.validate().?);
    submission.operation.upload_cancel.target = .{ .raw_value = 0 };
    try std.testing.expectEqual(SubmissionIssue.invalid_cancel_target, submission.validate().?);

    submission.operation.upload_cancel.target = testToken(.file_sync, 1, 2, 3, 20);
    try std.testing.expect(submission.validate() == null);
}

test "live file cancellation is confined to one file operation owner" {
    const cancel_token = testToken(.file_cancel, 1, 2, 3, 24);
    const kinds = [_]OperationKind{ .file_open, .file_read, .file_stat, .file_close };
    for (kinds, 1..) |kind, sequence| {
        const submission = Submission{ .token = cancel_token, .operation = .{
            .file_cancel = .{ .target = testToken(kind, 1, 2, 3, @intCast(sequence)) },
        } };
        try std.testing.expect(submission.validate() == null);
    }
    var submission = Submission{ .token = cancel_token, .operation = .{
        .file_cancel = .{ .target = testToken(.receive, 1, 2, 3, 25) },
    } };
    try std.testing.expectEqual(
        SubmissionIssue.file_cancel_target_not_file,
        submission.validate().?,
    );
    submission.operation.file_cancel.target = testToken(.file_read, 2, 2, 3, 25);
    try std.testing.expectEqual(
        SubmissionIssue.file_cancel_owner_mismatch,
        submission.validate().?,
    );
    submission.operation.file_cancel.target = testToken(.file_cancel, 1, 2, 3, 25);
    try std.testing.expectEqual(SubmissionIssue.cancel_of_cancel, submission.validate().?);
}

test "completion validation accepts each normalized success and failure" {
    const socket = Socket{ .value = 10 };
    const receive_token = testToken(.receive, 4, 5, 6, 7);
    const cases = [_]Completion{
        .{ .token = testToken(.accept, 4, 0, 1, 1), .result = .{
            .success = .{ .accept = Accepted.loopback(socket) },
        }, .more = false },
        .{ .token = receive_token, .result = .{ .success = .{
            .receive = .{ .bytes = testReceive(receive_token, "abc") },
        } }, .more = true },
        .{ .token = testToken(.send, 4, 5, 6, 8), .result = .{
            .success = .{ .send = 3 },
        }, .more = false },
        .{ .token = testToken(.close, 4, 5, 6, 9), .result = .{
            .success = .{ .close = {} },
        }, .more = false },
        .{ .token = testToken(.timeout, 4, 5, 6, 10), .result = .{
            .success = .{ .timeout = {} },
        }, .more = false },
        .{ .token = testToken(.cancel, 4, 5, 6, 11), .result = .{
            .success = .{ .cancel = .not_found },
        }, .more = false },
        .{ .token = testToken(.wake, 4, wake_control_slot, 6, 12), .result = .{
            .success = .{ .wake = {} },
        }, .more = false },
        .{ .token = testToken(.file_open, 4, 5, 6, 13), .result = .{
            .success = .{ .file_open = .{ .value = 0 } },
        }, .more = false },
        .{ .token = testToken(.file_write, 4, 5, 6, 14), .result = .{
            .success = .{ .file_write = 3 },
        }, .more = false },
        .{ .token = testToken(.file_close, 4, 5, 6, 15), .result = .{
            .success = .{ .file_close = {} },
        }, .more = false },
        .{ .token = testToken(.file_link, 4, 5, 6, 16), .result = .{
            .success = .{ .file_link = {} },
        }, .more = false },
        .{ .token = testToken(.file_unlink, 4, 5, 6, 17), .result = .{
            .success = .{ .file_unlink = {} },
        }, .more = false },
        .{ .token = testToken(.file_rename_no_replace, 4, 5, 6, 18), .result = .{
            .success = .{ .file_rename_no_replace = {} },
        }, .more = false },
        .{ .token = testToken(.file_sync, 4, 5, 6, 19), .result = .{
            .success = .{ .file_sync = {} },
        }, .more = false },
        .{ .token = testToken(.upload_cancel, 4, 5, 6, 20), .result = .{
            .success = .{ .upload_cancel = .canceled },
        }, .more = false },
        .{ .token = testToken(.file_read, 4, 5, 6, 21), .result = .{
            .success = .{ .file_read = 0 },
        }, .more = false },
        .{ .token = testToken(.file_stat, 4, 5, 6, 22), .result = .{
            .success = .{ .file_stat = {} },
        }, .more = false },
        .{ .token = testToken(.file_cancel, 4, 5, 6, 23), .result = .{
            .success = .{ .file_cancel = .canceled },
        }, .more = false },
    };
    for (cases) |case| try std.testing.expect(case.validate() == null);

    inline for (std.meta.fields(CompletionError)) |field| {
        const failure = Completion{
            .token = receive_token,
            .result = .{ .failure = @enumFromInt(field.value) },
            .more = false,
        };
        try std.testing.expect(failure.validate() == null);
    }
}

test "completion more and result tags are constrained" {
    const send_token = testToken(.send, 0, 1, 1, 1);
    var completion = Completion{
        .token = send_token,
        .result = .{ .success = .{ .receive = .end_of_stream } },
        .more = false,
    };
    try std.testing.expectEqual(CompletionIssue.result_kind_mismatch, completion.validate().?);

    completion.result = .{ .success = .{ .send = 1 } };
    completion.more = true;
    try std.testing.expectEqual(CompletionIssue.single_shot_has_more, completion.validate().?);
    completion.token = testToken(.accept, 0, 1, 1, 2);
    completion.result = .{ .success = .{ .accept = Accepted.loopback(.{ .value = 4 }) } };
    try std.testing.expectEqual(CompletionIssue.single_shot_has_more, completion.validate().?);
    completion.result = .{ .failure = .canceled };
    try std.testing.expectEqual(CompletionIssue.failure_has_more, completion.validate().?);

    const receive_token = testToken(.receive, 0, 1, 1, 2);
    completion = .{
        .token = receive_token,
        .result = .{ .success = .{ .receive = .end_of_stream } },
        .more = true,
    };
    try std.testing.expectEqual(
        CompletionIssue.end_of_stream_has_more,
        completion.validate().?,
    );
}

test "receive completion rejects stale or empty borrowed data" {
    const token = testToken(.receive, 3, 4, 5, 6);
    var borrowed = testReceive(token, "x");
    var completion = Completion{
        .token = token,
        .result = .{ .success = .{ .receive = .{ .bytes = borrowed } } },
        .more = false,
    };
    try std.testing.expect(completion.validate() == null);

    borrowed.identity.owner.generation += 1;
    completion.result = .{ .success = .{ .receive = .{ .bytes = borrowed } } };
    try std.testing.expectEqual(CompletionIssue.receive_owner_mismatch, completion.validate().?);
    borrowed = testReceive(token, "");
    completion.result = .{ .success = .{ .receive = .{ .bytes = borrowed } } };
    try std.testing.expectEqual(CompletionIssue.empty_receive, completion.validate().?);
    borrowed = testReceive(token, "x");
    borrowed.identity.buffer_generation = 0;
    completion.result = .{ .success = .{ .receive = .{ .bytes = borrowed } } };
    try std.testing.expectEqual(
        CompletionIssue.invalid_receive_identity,
        completion.validate().?,
    );

    completion.token = .{ .raw_value = 0 };
    try std.testing.expectEqual(CompletionIssue.invalid_token, completion.validate().?);
}

test "zero send completion is rejected" {
    const completion = Completion{
        .token = testToken(.send, 0, 0, 1, 1),
        .result = .{ .success = .{ .send = 0 } },
        .more = false,
    };
    try std.testing.expectEqual(CompletionIssue.zero_send, completion.validate().?);
}

test "file completion rejects negative descriptors and zero writes" {
    var completion = Completion{
        .token = testToken(.file_open, 0, 0, 1, 1),
        .result = .{ .success = .{ .file_open = .{ .value = -1 } } },
        .more = false,
    };
    try std.testing.expectEqual(
        CompletionIssue.invalid_file_descriptor,
        completion.validate().?,
    );
    completion = .{
        .token = testToken(.file_write, 0, 0, 1, 2),
        .result = .{ .success = .{ .file_write = 0 } },
        .more = false,
    };
    try std.testing.expectEqual(CompletionIssue.zero_file_write, completion.validate().?);
    completion.result = .{ .success = .{ .file_write = 1 } };
    completion.more = true;
    try std.testing.expectEqual(CompletionIssue.single_shot_has_more, completion.validate().?);
}

test {
    std.testing.refAllDecls(reactor);
}
