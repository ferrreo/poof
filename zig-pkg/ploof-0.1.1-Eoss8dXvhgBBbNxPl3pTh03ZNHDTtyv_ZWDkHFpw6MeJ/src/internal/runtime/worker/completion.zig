const reactor = @import("../reactor.zig");

pub fn acceptedSocket(completion: reactor.Completion) ?reactor.Socket {
    return switch (completion.result) {
        .failure => null,
        .success => |success| switch (success) {
            .accept => |accepted| accepted.socket,
            else => null,
        },
    };
}

pub fn claimsAcceptedSocket(
    completion: reactor.Completion,
    fields: reactor.TokenFields,
    listener_slot: u16,
    generation: u16,
    accept_token: ?reactor.OperationToken,
) bool {
    if (completion.validate() != null or fields.kind != .accept or
        fields.slot_index != listener_slot or fields.slot_generation != generation)
    {
        return false;
    }
    const current = accept_token orelse return false;
    return current.eql(completion.token);
}

pub fn hasBorrowedReceive(completion: reactor.Completion) bool {
    return switch (completion.result) {
        .failure => false,
        .success => |success| switch (success) {
            .receive => |received| received == .bytes,
            else => false,
        },
    };
}

pub fn record(
    metrics: anytype,
    kind: reactor.OperationKind,
    result: reactor.CompletionResult,
) void {
    metrics.recordValidCompletion();
    if (kind == .timeout) metrics.recordTimeoutCompletion();
    switch (result) {
        .failure => |problem| if (kind == .receive and problem == .buffer_exhausted)
            metrics.recordReceiveBufferExhaustion(),
        .success => {},
    }
}
