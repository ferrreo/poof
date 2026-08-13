const application = @import("../../../application.zig");
const reactor = @import("../reactor.zig");
const worker_response_staging = @import("response_staging.zig");

pub fn fileHead(
    comptime App: type,
    driver: anytype,
    request_index: u16,
    prepared: application.Prepared,
) !void {
    const file = prepared.source.live_static_file;
    if (!driver.storage.commitResponse(request_index, file.head)) return error.StateInvariant;
    worker_response_staging.scrub(
        App,
        &driver.storage.requests[request_index].workspace,
        prepared,
    );
}

pub fn normal(
    comptime App: type,
    comptime BodyTransport: type,
    driver: anytype,
    connection_index: u16,
    request_index: u16,
    prepared: application.Prepared,
    now_ns: u64,
) !void {
    var release_chain = prepared.source == .finite_chain;
    defer if (release_chain) switch (prepared.source) {
        .finite_chain => |finite| driver.storage.discardResponseChunks(finite.body),
        else => {},
    };
    const committed = switch (prepared.source) {
        .finite_chain => |finite| driver.storage.commitResponseChunks(
            request_index,
            finite.head,
            finite.body,
        ),
        .contiguous_wire => |wire| driver.storage.commitResponse(request_index, wire) or
            driver.storage.commitExternalResponse(request_index, wire),
        .borrowed_static => |borrowed| if (borrowed.body.len == 0)
            driver.storage.commitResponse(request_index, borrowed.head)
        else
            driver.storage.commitStaticResponse(request_index, borrowed.head, borrowed.body),
        .live_static, .live_static_file => false,
    };
    if (!committed) return error.StateInvariant;
    release_chain = false;
    worker_response_staging.scrub(
        App,
        &driver.storage.requests[request_index].workspace,
        prepared,
    );
    try BodyTransport.beginFinal(
        driver,
        connection_index,
        prepared.close_connection,
        now_ns,
    );
}

pub fn discardPrepared(storage: anytype, slot: anytype) void {
    if (!slot.prepared_valid) return;
    switch (slot.prepared.source) {
        .finite_chain => |finite| storage.discardResponseChunks(finite.body),
        else => {},
    }
    slot.prepared_valid = false;
}

pub fn validateClose(completion: reactor.Completion) !void {
    return switch (completion.result) {
        .success => |success| if (success == .file_close) {} else error.InvalidCompletion,
        .failure => error.BackendFailure,
    };
}

pub fn validateCancel(completion: reactor.Completion) !void {
    return switch (completion.result) {
        .success => |success| if (success == .file_cancel) {} else error.InvalidCompletion,
        .failure => |problem| if (problem == .canceled) {} else error.BackendFailure,
    };
}

pub fn resolutionForOpenFailure(
    problem: reactor.CompletionError,
) application.LiveStaticResolution {
    return switch (problem) {
        .not_found,
        .invalid_path,
        .cross_device,
        .permission_denied,
        .invalid_resource,
        => .not_found,
        .resource_exhausted, .buffer_exhausted => .unavailable,
        else => .internal_error,
    };
}
