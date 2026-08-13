pub const AcquireResult = enum(u8) {
    acquired,
    body_workspace_exhausted,
    chunked_workspace_exhausted,
    invalid_request,
};

pub fn acquire(
    storage: anytype,
    request_index: u16,
    workspace_class: u16,
    requires_chunked: bool,
) AcquireResult {
    if (request_index >= storage.requests.len) return .invalid_request;
    const body_enabled = @hasField(
        @TypeOf(storage.requests[request_index].body),
        "workspace_index",
    );
    const workspace_class_count: u16 = if (body_enabled) 2 else 1;
    if (workspace_class >= workspace_class_count) return .invalid_request;
    const request = &storage.requests[request_index];
    if (request.phase != .live or request.chunked_workspace_index != null) {
        return .invalid_request;
    }
    if (comptime body_enabled) {
        if (request.body.workspace_index != null or
            request.body.used != 0 or
            request.body.dirty_full or
            request.body.tainted_full)
        {
            return .invalid_request;
        }
        var body_index: ?u16 = null;
        if (workspace_class == 1) {
            body_index = storage.body_workspaces.pool.acquire() orelse {
                return .body_workspace_exhausted;
            };
        }
        var chunked_index: ?u16 = null;
        if (requires_chunked) {
            chunked_index = storage.chunked_workspaces.pool.acquire() orelse {
                if (body_index) |leased| storage.body_workspaces.pool.release(leased);
                return .chunked_workspace_exhausted;
            };
        }
        request.body.workspace_index = body_index;
        request.chunked_workspace_index = chunked_index;
        return .acquired;
    }
    if (workspace_class != 0 or requires_chunked) return .invalid_request;
    return .acquired;
}

pub fn acquireChunked(storage: anytype, request_index: u16) AcquireResult {
    if (request_index >= storage.requests.len) return .invalid_request;
    const body_enabled = @hasField(
        @TypeOf(storage.requests[request_index].body),
        "workspace_index",
    );
    if (comptime !body_enabled) return .invalid_request;
    const request = &storage.requests[request_index];
    if (request.phase != .live or request.chunked_workspace_index != null) {
        return .invalid_request;
    }
    const body_index = request.body.workspace_index orelse return .invalid_request;
    if (body_index >= storage.body_workspaces.free_indices.len or request.body.used != 0) {
        return .invalid_request;
    }
    const chunked_index = storage.chunked_workspaces.pool.acquire() orelse {
        return .chunked_workspace_exhausted;
    };
    request.chunked_workspace_index = chunked_index;
    return .acquired;
}
