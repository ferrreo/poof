pub const std = @import("std");
pub const address = @import("../../../../src/address.zig");
pub const body = @import("../../../../src/body.zig");
pub const forwarding = @import("../../../../src/forwarding.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_send = @import("../../../../src/internal/runtime/connection/send.zig");
pub const connection_chunked_body = @import(
    "../../../../src/internal/runtime/connection/chunked_body.zig",
);
pub const event_counter = @import("../../../../src/internal/runtime/event_counter.zig");
pub const memory_budget = @import("../../../../src/internal/runtime/memory_budget.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_emergency = @import("../../../../src/internal/runtime/worker/emergency.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");

pub const BodyResetIssue = worker_storage.BodyResetIssue;
pub const ConnectionPhase = worker_storage.ConnectionPhase;
pub const ConnectionReleaseIssue = worker_storage.ConnectionReleaseIssue;
pub const RequestReleaseIssue = worker_storage.RequestReleaseIssue;

pub const TestApp = struct {
    pub const Workspace = struct {
        marker: u64 = 7,
        alignment_anchor: u8 align(64) = 0,
    };
};

pub const test_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub const BodyTestApp = struct {
    pub const Workspace = TestApp.Workspace;
    pub const body_workspace_bytes_max: u64 = 8;

    pub fn abort(_: *Workspace) error{}!void {}
};

pub const ResponseOnlyTestApp = struct {
    pub const Workspace = TestApp.Workspace;
    pub const body_workspace_bytes_max: u64 = 8;
    pub const request_body_decoding_enabled = false;
};

pub const body_test_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .body_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub const ExternalTestApp = struct {
    pub const Workspace = TestApp.Workspace;
    pub const body_workspace_bytes_max: u64 = 48;
};

pub const external_test_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub const chunked_one_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub const chunked_two_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .chunked_workspace_slots = 2,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
});

pub const gzip_two_limits = config.Limits.validate(.{
    .connection_slots = 3,
    .request_slots = 2,
    .body_workspace_slots = 2,
    .chunked_workspace_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 8,
    .pipeline_bytes_per_connection = 16,
    .response_bytes_per_request = 32,
    .submission_entries = 8,
    .completion_entries = 16,
    .gzip = .{
        .decoder_slots = 2,
        .input_chunks_per_slot = 3,
        .members_max = 2,
        .thread_stack_bytes = 128 * 1024,
    },
});

pub const LayoutTestApp = struct {
    pub const Workspace = struct { marker: u64 = 0 };
    pub const body_workspace_bytes_max: u64 = 8;
};

pub const StreamTestApp = struct {
    pub const stream_enabled = true;
    pub const Workspace = TestApp.Workspace;
};

pub fn acquired(result: worker_storage.AcquireResult) !u16 {
    return switch (result) {
        .acquired => |index| index,
        else => error.TestUnexpectedResult,
    };
}

pub fn sendToken(storage: anytype, connection: u16, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = .send,
        .worker_index = 0,
        .slot_index = connection,
        .slot_generation = storage.connections[connection].generation,
        .sequence = sequence,
    });
}

pub fn expectAcquireIssue(
    expected: std.meta.Tag(worker_storage.AcquireResult),
    result: worker_storage.AcquireResult,
) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(result));
}

test {
    _ = @import("worker_storage_test_part_1.zig");
    _ = @import("worker_storage_test_part_2.zig");
}
