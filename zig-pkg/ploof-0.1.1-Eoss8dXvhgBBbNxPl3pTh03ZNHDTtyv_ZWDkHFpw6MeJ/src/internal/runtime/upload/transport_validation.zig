const upload_file_table = @import("file_table.zig");
const upload_io = @import("../../../upload_io.zig");
const reactor = @import("../reactor.zig");

pub const Error = error{
    InvalidOwner,
    InvalidToken,
    TokenKindMismatch,
    TokenOwnerMismatch,
};

pub fn validateTargetToken(
    owner: upload_file_table.Owner,
    token: reactor.OperationToken,
    kind: upload_io.IoKind,
) Error!void {
    if (owner.slot.validate() != null) return error.InvalidOwner;
    const fields = token.fields() catch return error.InvalidToken;
    if (fields.kind != expectedKind(kind)) return error.TokenKindMismatch;
    if (fields.worker_index != owner.slot.worker_index or
        fields.slot_index != owner.slot.index or
        fields.slot_generation != owner.slot.generation)
    {
        return error.TokenOwnerMismatch;
    }
}

pub fn expectedKind(kind: upload_io.IoKind) reactor.OperationKind {
    return switch (kind) {
        .open => .file_open,
        .write => .file_write,
        .close => .file_close,
        .link => .file_link,
        .unlink => .file_unlink,
        .rename_no_replace => .file_rename_no_replace,
        .sync => .file_sync,
    };
}

pub fn descriptor(value: upload_file_table.Descriptor) reactor.FileDescriptor {
    return .{ .value = value.raw_fd };
}
