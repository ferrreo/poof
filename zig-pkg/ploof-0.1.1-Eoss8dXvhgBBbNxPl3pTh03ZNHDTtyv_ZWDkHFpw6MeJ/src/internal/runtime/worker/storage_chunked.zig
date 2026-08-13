const worker_storage_types = @import("storage_types.zig");

pub fn state(
    storage: anytype,
    request_index: u16,
    comptime body_enabled: bool,
    comptime workspace_slots: u16,
    comptime ChunkedState: type,
) worker_storage_types.ChunkedAccessError!*ChunkedState {
    if (request_index >= storage.requests.len) return error.RequestIndexOutOfRange;
    const request = &storage.requests[request_index];
    if (request.phase != .live) return error.RequestNotLive;
    if (comptime body_enabled) {
        const state_index = request.chunked_workspace_index orelse {
            return error.ChunkedWorkspaceNotLeased;
        };
        if (state_index >= workspace_slots) return error.ChunkedWorkspaceNotLeased;
        return &storage.chunked_workspaces.states[state_index];
    }
    return error.ChunkedWorkspaceNotLeased;
}
