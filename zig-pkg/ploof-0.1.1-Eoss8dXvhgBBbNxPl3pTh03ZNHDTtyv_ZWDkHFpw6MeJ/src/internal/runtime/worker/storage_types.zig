pub const ConnectionPhase = enum(u8) {
    free,
    first_head,
    keepalive_idle,
    reused_head,
    receiving_body,
    responding,
    closing,
};

pub const RequestPhase = enum(u8) {
    free,
    live,
};

pub const AcquireResult = union(enum) {
    acquired: u16,
    request_slots_exhausted,
    body_workspace_exhausted,
    chunked_workspace_exhausted,
};

pub const ChunkedAccessError = error{
    RequestIndexOutOfRange,
    RequestNotLive,
    ChunkedWorkspaceNotLeased,
};

pub const BodyResetIssue = enum(u8) { gzip_decoder_active };

pub fn acquiredIndex(result: AcquireResult) ?u16 {
    return switch (result) {
        .acquired => |index| index,
        .request_slots_exhausted,
        .body_workspace_exhausted,
        .chunked_workspace_exhausted,
        => null,
    };
}
