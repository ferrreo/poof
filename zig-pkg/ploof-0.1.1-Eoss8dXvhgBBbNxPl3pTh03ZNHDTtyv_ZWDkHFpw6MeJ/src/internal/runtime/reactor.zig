const std = @import("std");
const address = @import("../../address.zig");
const reactor_file = @import("reactor/file.zig");

pub const max_worker_index: u16 = 0x0fff;
pub const max_sequence: u16 = 0x7fff;
pub const wake_control_slot: u16 = std.math.maxInt(u16) - 1;
pub const stream_wake_control_slot: u16 = std.math.maxInt(u16) - 2;
pub const upload_runtime_control_slot: u16 = std.math.maxInt(u16) - 3;
pub const lifecycle_wake_control_slot: u16 = std.math.maxInt(u16) - 4;
pub const live_static_slots_hard_max: u16 = 64;
pub const live_static_request_slot_base: u16 =
    std.math.maxInt(u16) - 4 - live_static_slots_hard_max * 2;
pub const live_static_root_slot_base: u16 =
    live_static_request_slot_base + live_static_slots_hard_max;
pub const connection_operation_capacity: u32 = 12;
pub const worker_control_operation_capacity: u32 = 10;

pub const AbortStatus = struct {
    ownership_proven: bool,
    accepted_sockets_discarded: u32,
};

pub const OperationKind = enum(u5) {
    accept = 1,
    receive = 2,
    send = 3,
    close = 4,
    timeout = 5,
    cancel = 6,
    wake = 7,
    file_open = 8,
    file_write = 9,
    file_close = 10,
    file_link = 11,
    file_unlink = 12,
    file_rename_no_replace = 13,
    file_sync = 14,
    upload_cancel = 15,
    file_read = 16,
    file_stat = 17,
    file_cancel = 18,
};

pub const TokenFields = struct {
    kind: OperationKind,
    worker_index: u16,
    slot_index: u16,
    slot_generation: u16,
    sequence: u16,
};

pub const TokenIssue = enum(u8) {
    invalid_kind,
    invalid_wake_slot,
    worker_index_out_of_range,
    zero_slot_generation,
    zero_sequence,
    sequence_out_of_range,
};

pub const TokenError = error{
    InvalidKind,
    InvalidWakeSlot,
    WorkerIndexOutOfRange,
    ZeroSlotGeneration,
    ZeroSequence,
    SequenceOutOfRange,
};

pub const SlotIdentityIssue = enum(u8) {
    worker_index_out_of_range,
    zero_generation,
};

pub const SlotIdentity = struct {
    worker_index: u16,
    index: u16,
    generation: u16,

    pub fn validate(identity: SlotIdentity) ?SlotIdentityIssue {
        if (identity.worker_index > max_worker_index) return .worker_index_out_of_range;
        if (identity.generation == 0) return .zero_generation;
        return null;
    }

    pub fn eql(a: SlotIdentity, b: SlotIdentity) bool {
        return a.worker_index == b.worker_index and
            a.index == b.index and
            a.generation == b.generation;
    }
};

/// Stable identity carried through a backend's 64-bit completion token.
pub const OperationToken = struct {
    raw_value: u64,

    const kind_shift = 0;
    const worker_shift = 5;
    const slot_shift = 17;
    const generation_shift = 33;
    const sequence_shift = 49;
    const kind_mask: u64 = 0x0000_0000_0000_001f;
    const worker_mask: u64 = 0x0000_0000_0001_ffe0;

    pub fn init(token_fields: TokenFields) TokenError!OperationToken {
        if (validateFields(token_fields)) |issue| return tokenError(issue);
        return .{ .raw_value = encode(token_fields) };
    }

    pub fn fromRaw(raw_value: u64) TokenError!OperationToken {
        const decoded = try decodeRaw(raw_value);
        return .{ .raw_value = encode(decoded) };
    }

    pub fn raw(token: OperationToken) u64 {
        return token.raw_value;
    }

    pub fn fields(token: OperationToken) TokenError!TokenFields {
        return decodeRaw(token.raw_value);
    }

    pub fn validate(token: OperationToken) ?TokenIssue {
        const decoded = decodeRaw(token.raw_value) catch |err| {
            return tokenIssue(err);
        };
        return validateFields(decoded);
    }

    pub fn slot(token: OperationToken) TokenError!SlotIdentity {
        const decoded = try token.fields();
        return .{
            .worker_index = decoded.worker_index,
            .index = decoded.slot_index,
            .generation = decoded.slot_generation,
        };
    }

    /// Sequence is deliberately ignored: it distinguishes operations within one live slot.
    pub fn isCurrentFor(token: OperationToken, current: SlotIdentity) bool {
        if (current.validate() != null) return false;
        const identity = token.slot() catch return false;
        return identity.eql(current);
    }

    pub fn eql(a: OperationToken, b: OperationToken) bool {
        return a.raw_value == b.raw_value;
    }

    fn encode(fields_value: TokenFields) u64 {
        return @as(u64, @intFromEnum(fields_value.kind)) << kind_shift |
            @as(u64, fields_value.worker_index) << worker_shift |
            @as(u64, fields_value.slot_index) << slot_shift |
            @as(u64, fields_value.slot_generation) << generation_shift |
            @as(u64, fields_value.sequence) << sequence_shift;
    }

    fn decodeRaw(raw_value: u64) TokenError!TokenFields {
        const kind_value: u5 = @truncate((raw_value & kind_mask) >> kind_shift);
        const fields_value = TokenFields{
            .kind = try decodeKind(kind_value),
            .worker_index = @truncate((raw_value & worker_mask) >> worker_shift),
            .slot_index = @truncate(raw_value >> slot_shift),
            .slot_generation = @truncate(raw_value >> generation_shift),
            .sequence = @truncate(raw_value >> sequence_shift),
        };
        if (validateFields(fields_value)) |issue| return tokenError(issue);
        return fields_value;
    }
};

pub fn nextSequence(sequence: u16) u16 {
    std.debug.assert(sequence > 0 and sequence <= max_sequence);
    return if (sequence == max_sequence) 1 else sequence + 1;
}

/// Advance only after the old slot or buffer generation is fully quiescent.
pub fn nextGeneration(generation: u16) u16 {
    std.debug.assert(generation != 0);
    return nextNonZero(generation);
}

fn nextNonZero(value: u16) u16 {
    return if (value == std.math.maxInt(u16)) 1 else value + 1;
}

fn decodeKind(value: u5) TokenError!OperationKind {
    return switch (value) {
        1 => .accept,
        2 => .receive,
        3 => .send,
        4 => .close,
        5 => .timeout,
        6 => .cancel,
        7 => .wake,
        8 => .file_open,
        9 => .file_write,
        10 => .file_close,
        11 => .file_link,
        12 => .file_unlink,
        13 => .file_rename_no_replace,
        14 => .file_sync,
        15 => .upload_cancel,
        16 => .file_read,
        17 => .file_stat,
        18 => .file_cancel,
        else => error.InvalidKind,
    };
}

fn validateFields(fields: TokenFields) ?TokenIssue {
    if (fields.worker_index > max_worker_index) return .worker_index_out_of_range;
    if (fields.kind == .wake and !isWakeControlSlot(fields.slot_index)) {
        return .invalid_wake_slot;
    }
    if (fields.slot_generation == 0) return .zero_slot_generation;
    if (fields.sequence == 0) return .zero_sequence;
    if (fields.sequence > max_sequence) return .sequence_out_of_range;
    return null;
}

pub fn isWakeControlSlot(index: u16) bool {
    return index == wake_control_slot or index == stream_wake_control_slot or
        index == lifecycle_wake_control_slot;
}

pub fn liveStaticRequestIndex(index: u16) ?u16 {
    if (index < live_static_request_slot_base or
        index >= live_static_request_slot_base + live_static_slots_hard_max) return null;
    return index - live_static_request_slot_base;
}

pub fn liveStaticRootIndex(index: u16) ?u16 {
    if (index < live_static_root_slot_base or
        index >= live_static_root_slot_base + live_static_slots_hard_max) return null;
    return index - live_static_root_slot_base;
}

fn tokenError(issue: TokenIssue) TokenError {
    return switch (issue) {
        .invalid_kind => error.InvalidKind,
        .invalid_wake_slot => error.InvalidWakeSlot,
        .worker_index_out_of_range => error.WorkerIndexOutOfRange,
        .zero_slot_generation => error.ZeroSlotGeneration,
        .zero_sequence => error.ZeroSequence,
        .sequence_out_of_range => error.SequenceOutOfRange,
    };
}

fn tokenIssue(err: TokenError) TokenIssue {
    return switch (err) {
        error.InvalidKind => .invalid_kind,
        error.InvalidWakeSlot => .invalid_wake_slot,
        error.WorkerIndexOutOfRange => .worker_index_out_of_range,
        error.ZeroSlotGeneration => .zero_slot_generation,
        error.ZeroSequence => .zero_sequence,
        error.SequenceOutOfRange => .sequence_out_of_range,
    };
}

pub const Socket = struct {
    value: u64,
};

pub const Accepted = struct {
    socket: Socket,
    peer: address.Endpoint,

    pub fn loopback(socket: Socket) Accepted {
        return .{
            .socket = socket,
            .peer = address.Endpoint.initIpv4(.{ 127, 0, 0, 1 }, 0),
        };
    }
};

pub const Accept = struct {
    /// Accept is single-shot so admission capacity bounds accepted descriptors.
    listener: Socket,
};

pub const Receive = struct {
    socket: Socket,
    /// Completions continue while `more` is true when enabled.
    multishot: bool = true,
};

pub const Send = struct {
    socket: Socket,
    /// The owner must retain these bytes until the matching completion is consumed.
    bytes: []const u8,
};

pub const Close = struct {
    socket: Socket,
};

pub const Timeout = struct {
    /// Absolute time on the reactor's monotonic clock.
    deadline_ns: u64,
};

pub const Cancel = struct {
    target: OperationToken,
};

pub const WakeSource = struct {
    value: u64,
};

pub const Wake = struct {
    source: WakeSource,
};

const FileTypes = reactor_file.Types(OperationToken);
pub const FileDescriptor = FileTypes.Descriptor;
pub const FileOpenBase = FileTypes.OpenBase;
pub const FileOpen = FileTypes.Open;
pub const FileWrite = FileTypes.Write;
pub const FileRead = FileTypes.Read;
pub const FileStat = FileTypes.Stat;
pub const FileClose = FileTypes.Close;
pub const FileLink = FileTypes.Link;
pub const FileUnlink = FileTypes.Unlink;
pub const FileRenameNoReplace = FileTypes.RenameNoReplace;
pub const FileSync = FileTypes.Sync;
pub const UploadCancel = FileTypes.UploadCancel;
pub const FileCancel = FileTypes.Cancel;

pub const Operation = union(OperationKind) {
    accept: Accept,
    receive: Receive,
    send: Send,
    close: Close,
    timeout: Timeout,
    cancel: Cancel,
    wake: Wake,
    file_open: FileOpen,
    file_write: FileWrite,
    file_close: FileClose,
    file_link: FileLink,
    file_unlink: FileUnlink,
    file_rename_no_replace: FileRenameNoReplace,
    file_sync: FileSync,
    upload_cancel: UploadCancel,
    file_read: FileRead,
    file_stat: FileStat,
    file_cancel: FileCancel,
};

pub const SubmissionIssue = enum(u8) {
    invalid_token,
    token_kind_mismatch,
    empty_send,
    zero_deadline,
    invalid_cancel_target,
    cancel_self,
    cancel_of_cancel,
    cross_worker_cancel,
    cancel_of_file_operation,
    upload_cancel_target_not_file,
    upload_cancel_owner_mismatch,
    file_cancel_target_not_file,
    file_cancel_owner_mismatch,
    invalid_file_descriptor,
    empty_file_path,
    absolute_file_path,
    file_path_contains_nul,
    invalid_file_mode,
    invalid_file_open_combination,
    empty_file_write,
    file_write_too_large,
    file_write_overflow,
    empty_file_read,
    file_read_too_large,
    file_read_overflow,
};

pub const Submission = struct {
    token: OperationToken,
    operation: Operation,

    pub fn validate(submission: Submission) ?SubmissionIssue {
        if (submission.token.validate() != null) return .invalid_token;
        const fields_value = submission.token.fields() catch return .invalid_token;
        if (fields_value.kind != std.meta.activeTag(submission.operation)) {
            return .token_kind_mismatch;
        }

        return switch (submission.operation) {
            .send => |send| if (send.bytes.len == 0) .empty_send else null,
            .timeout => |timeout| if (timeout.deadline_ns == 0) .zero_deadline else null,
            .cancel => |cancel| validateCancel(submission.token, fields_value, cancel.target),
            .upload_cancel => |cancel| validateUploadCancel(
                submission.token,
                fields_value,
                cancel.target,
            ),
            .file_cancel => |cancel| validateFileCancel(
                submission.token,
                fields_value,
                cancel.target,
            ),
            .file_open => |operation| validateFileOpen(operation),
            .file_write => |operation| validateFileWrite(operation),
            .file_read => |operation| validateFileRead(operation),
            .file_stat => |operation| validateFileDescriptor(operation.file),
            .file_close => |operation| validateFileDescriptor(operation.file),
            .file_link => |operation| validateFileLink(operation),
            .file_unlink => |operation| validateFileUnlink(operation),
            .file_rename_no_replace => |operation| validateFileRename(operation),
            .file_sync => |operation| validateFileDescriptor(operation.file),
            .accept, .receive, .close, .wake => null,
        };
    }
};

fn validateCancel(
    token: OperationToken,
    fields: TokenFields,
    target: OperationToken,
) ?SubmissionIssue {
    if (target.validate() != null) return .invalid_cancel_target;
    if (target.eql(token)) return .cancel_self;
    const target_fields = target.fields() catch return .invalid_cancel_target;
    if (isCancellation(target_fields.kind)) return .cancel_of_cancel;
    if (isFileOperation(target_fields.kind)) return .cancel_of_file_operation;
    if (target_fields.worker_index != fields.worker_index) return .cross_worker_cancel;
    return null;
}

fn validateUploadCancel(
    token: OperationToken,
    fields: TokenFields,
    target: OperationToken,
) ?SubmissionIssue {
    if (target.validate() != null) return .invalid_cancel_target;
    if (target.eql(token)) return .cancel_self;
    const target_fields = target.fields() catch return .invalid_cancel_target;
    if (isCancellation(target_fields.kind)) return .cancel_of_cancel;
    if (!isUploadFileOperation(target_fields.kind)) {
        return .upload_cancel_target_not_file;
    }
    if (target_fields.worker_index != fields.worker_index or
        target_fields.slot_index != fields.slot_index or
        target_fields.slot_generation != fields.slot_generation)
    {
        return .upload_cancel_owner_mismatch;
    }
    return null;
}

fn validateFileCancel(
    token: OperationToken,
    fields: TokenFields,
    target: OperationToken,
) ?SubmissionIssue {
    if (target.validate() != null) return .invalid_cancel_target;
    if (target.eql(token)) return .cancel_self;
    const target_fields = target.fields() catch return .invalid_cancel_target;
    if (isCancellation(target_fields.kind)) return .cancel_of_cancel;
    if (!isFileOperation(target_fields.kind)) return .file_cancel_target_not_file;
    if (target_fields.worker_index != fields.worker_index or
        target_fields.slot_index != fields.slot_index or
        target_fields.slot_generation != fields.slot_generation)
    {
        return .file_cancel_owner_mismatch;
    }
    return null;
}

pub fn isUploadFileOperation(kind: OperationKind) bool {
    return switch (kind) {
        .file_open, .file_write, .file_close, .file_link => true,
        .file_unlink, .file_rename_no_replace, .file_sync => true,
        else => false,
    };
}

pub fn isFileOperation(kind: OperationKind) bool {
    return isUploadFileOperation(kind) or kind == .file_read or kind == .file_stat;
}

fn isCancellation(kind: OperationKind) bool {
    return kind == .cancel or kind == .upload_cancel or kind == .file_cancel;
}

fn validateFileOpen(operation: FileOpen) ?SubmissionIssue {
    switch (operation.base) {
        .working_directory => {
            if (validateFilePath(operation.path, false, true)) |issue| return issue;
            if (operation.path[0] == '/' and operation.resolve.beneath) {
                return .invalid_file_open_combination;
            }
        },
        .directory => |directory| {
            if (validateFileDescriptor(directory)) |issue| return issue;
            if (validateFilePath(operation.path, false, false)) |issue| return issue;
        },
    }
    if (operation.mode > 0o777) return .invalid_file_mode;
    switch (operation.create) {
        .none => if (operation.mode != 0) return .invalid_file_open_combination,
        .exclusive => if (operation.mode == 0 or operation.access == .read_only) {
            return .invalid_file_open_combination;
        },
        .anonymous => if (operation.mode == 0 or
            operation.access != .read_write or operation.kind != .file)
        {
            return .invalid_file_open_combination;
        },
    }
    if (operation.kind == .directory and operation.create != .none) {
        return .invalid_file_open_combination;
    }
    return null;
}

fn validateFileWrite(operation: FileWrite) ?SubmissionIssue {
    if (validateFileDescriptor(operation.file)) |issue| return issue;
    if (operation.bytes.len == 0) return .empty_file_write;
    if (operation.bytes.len > std.math.maxInt(u32)) return .file_write_too_large;
    const end = std.math.add(u64, operation.offset, operation.bytes.len) catch {
        return .file_write_overflow;
    };
    if (end > std.math.maxInt(i64)) return .file_write_overflow;
    return null;
}

fn validateFileRead(operation: FileRead) ?SubmissionIssue {
    if (validateFileDescriptor(operation.file)) |issue| return issue;
    if (operation.bytes.len == 0) return .empty_file_read;
    if (operation.bytes.len > std.math.maxInt(u32)) return .file_read_too_large;
    const end = std.math.add(u64, operation.offset, operation.bytes.len) catch {
        return .file_read_overflow;
    };
    if (end > std.math.maxInt(i64)) return .file_read_overflow;
    return null;
}

fn validateFileLink(operation: FileLink) ?SubmissionIssue {
    if (validateFileDescriptor(operation.source)) |issue| return issue;
    if (validateFileDescriptor(operation.target_directory)) |issue| return issue;
    return validateFilePath(operation.target_path, false, false);
}

fn validateFileUnlink(operation: FileUnlink) ?SubmissionIssue {
    if (validateFileDescriptor(operation.directory)) |issue| return issue;
    return validateFilePath(operation.path, false, false);
}

fn validateFileRename(operation: FileRenameNoReplace) ?SubmissionIssue {
    if (validateFileDescriptor(operation.source_directory)) |issue| return issue;
    if (validateFileDescriptor(operation.target_directory)) |issue| return issue;
    if (validateFilePath(operation.source_path, false, false)) |issue| return issue;
    return validateFilePath(operation.target_path, false, false);
}

fn validateFileDescriptor(descriptor: FileDescriptor) ?SubmissionIssue {
    return if (descriptor.valid()) null else .invalid_file_descriptor;
}

fn validateFilePath(
    path: [:0]const u8,
    allow_empty: bool,
    allow_absolute: bool,
) ?SubmissionIssue {
    if (path.len == 0 and !allow_empty) return .empty_file_path;
    if (path.len != 0 and path[0] == '/' and !allow_absolute) {
        return .absolute_file_path;
    }
    if (std.mem.indexOfScalar(u8, path, 0) != null) return .file_path_contains_nul;
    return null;
}

pub const BorrowedReceiveIdentityIssue = enum(u8) {
    invalid_owner,
    zero_buffer_generation,
};

pub const BorrowedReceiveIdentity = struct {
    owner: SlotIdentity,
    buffer_index: u16,
    buffer_generation: u16,

    pub fn validate(identity: BorrowedReceiveIdentity) ?BorrowedReceiveIdentityIssue {
        if (identity.owner.validate() != null) return .invalid_owner;
        if (identity.buffer_generation == 0) return .zero_buffer_generation;
        return null;
    }

    pub fn isCurrent(
        identity: BorrowedReceiveIdentity,
        owner: SlotIdentity,
        buffer_generation: u16,
    ) bool {
        if (identity.validate() != null or owner.validate() != null) return false;
        return identity.owner.eql(owner) and
            identity.buffer_generation == buffer_generation;
    }
};

pub const BorrowedReceive = struct {
    identity: BorrowedReceiveIdentity,
    bytes: []const u8,
};

pub const ReceiveResult = union(enum) {
    bytes: BorrowedReceive,
    end_of_stream,
};

/// Neither result retires the target; its terminal completion must still be consumed.
pub const CancelResult = enum(u8) {
    /// Cancellation was accepted or was already in progress.
    canceled,
    /// Target was no longer cancellable.
    not_found,
};

pub const Success = union(OperationKind) {
    accept: Accepted,
    receive: ReceiveResult,
    send: u32,
    close: void,
    timeout: void,
    cancel: CancelResult,
    wake: void,
    file_open: FileDescriptor,
    file_write: u32,
    file_close: void,
    file_link: void,
    file_unlink: void,
    file_rename_no_replace: void,
    file_sync: void,
    upload_cancel: CancelResult,
    file_read: u32,
    file_stat: void,
    file_cancel: CancelResult,
};

pub const CompletionError = enum(u8) {
    canceled,
    already_exists,
    not_found,
    invalid_path,
    cross_device,
    read_only,
    quota_exceeded,
    file_too_large,
    no_space,
    unsupported,
    io_failure,
    transient_accept,
    connection_aborted,
    connection_reset,
    broken_pipe,
    not_connected,
    permission_denied,
    resource_exhausted,
    buffer_exhausted,
    invalid_resource,
    backend_failure,
};

pub const CompletionResult = union(enum) {
    success: Success,
    failure: CompletionError,
};

pub const CompletionIssue = enum(u8) {
    invalid_token,
    result_kind_mismatch,
    failure_has_more,
    single_shot_has_more,
    end_of_stream_has_more,
    invalid_receive_identity,
    receive_owner_mismatch,
    empty_receive,
    zero_send,
    invalid_file_descriptor,
    zero_file_write,
};

pub const Completion = struct {
    token: OperationToken,
    result: CompletionResult,
    /// True means this token remains active and can produce another completion.
    more: bool,

    pub fn validate(completion: Completion) ?CompletionIssue {
        if (completion.token.validate() != null) return .invalid_token;
        const fields_value = completion.token.fields() catch return .invalid_token;

        const success = switch (completion.result) {
            .failure => {
                if (completion.more) return .failure_has_more;
                return null;
            },
            .success => |success| success,
        };
        if (fields_value.kind != std.meta.activeTag(success)) {
            return .result_kind_mismatch;
        }
        if (completion.more and fields_value.kind != .receive) {
            return .single_shot_has_more;
        }

        switch (success) {
            .receive => |receive| switch (receive) {
                .end_of_stream => if (completion.more) return .end_of_stream_has_more,
                .bytes => |borrowed| {
                    if (borrowed.identity.validate() != null) {
                        return .invalid_receive_identity;
                    }
                    if (!completion.token.isCurrentFor(borrowed.identity.owner)) {
                        return .receive_owner_mismatch;
                    }
                    if (borrowed.bytes.len == 0) return .empty_receive;
                },
            },
            .send => |sent| if (sent == 0) return .zero_send,
            .file_open => |descriptor| {
                if (!descriptor.valid()) return .invalid_file_descriptor;
            },
            .file_write => |written| if (written == 0) return .zero_file_write,
            .accept,
            .close,
            .timeout,
            .cancel,
            .wake,
            .file_close,
            .file_link,
            .file_unlink,
            .file_rename_no_replace,
            .file_sync,
            .upload_cancel,
            .file_read,
            .file_stat,
            .file_cancel,
            => {},
        }
        return null;
    }
};
