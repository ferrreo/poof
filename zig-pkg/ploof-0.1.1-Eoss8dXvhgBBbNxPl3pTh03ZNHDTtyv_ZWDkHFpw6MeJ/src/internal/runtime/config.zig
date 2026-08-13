const std = @import("std");
const connection_chunked_body = @import("connection/chunked_body.zig");
const runtime_time = @import("time.zig");

pub const ChunkedProfile = connection_chunked_body.Profile;
pub const gzip_decoder_slots_hard_max: u16 = 64;
pub const gzip_input_chunks_hard_max: u16 = 64;
pub const gzip_members_hard_max: u16 = 64;
pub const gzip_thread_stack_bytes_min: u32 = 128 * 1024;
pub const gzip_thread_stack_bytes_max: u32 = 8 * 1024 * 1024;
pub const gzip_thread_stack_alignment: u32 = 4096;

pub const GzipProfileIssue = enum(u8) {
    decoder_slots_zero,
    decoder_slots_above_hard_max,
    input_chunks_below_two,
    input_chunks_above_hard_max,
    members_zero,
    members_above_hard_max,
    thread_stack_below_min,
    thread_stack_above_max,
    thread_stack_unaligned,
};

pub const GzipProfile = struct {
    decoder_slots: u16 = 1,
    input_chunks_per_slot: u16 = 4,
    members_max: u16 = 8,
    thread_stack_bytes: u32 = 256 * 1024,

    pub fn issue(profile: GzipProfile) ?GzipProfileIssue {
        if (profile.decoder_slots == 0) return .decoder_slots_zero;
        if (profile.decoder_slots > gzip_decoder_slots_hard_max) {
            return .decoder_slots_above_hard_max;
        }
        if (profile.input_chunks_per_slot < 2) return .input_chunks_below_two;
        if (profile.input_chunks_per_slot > gzip_input_chunks_hard_max) {
            return .input_chunks_above_hard_max;
        }
        if (profile.members_max == 0) return .members_zero;
        if (profile.members_max > gzip_members_hard_max) return .members_above_hard_max;
        if (profile.thread_stack_bytes < gzip_thread_stack_bytes_min) {
            return .thread_stack_below_min;
        }
        if (profile.thread_stack_bytes > gzip_thread_stack_bytes_max) {
            return .thread_stack_above_max;
        }
        if (profile.thread_stack_bytes % gzip_thread_stack_alignment != 0) {
            return .thread_stack_unaligned;
        }
        return null;
    }

    pub fn validate(comptime profile: GzipProfile) GzipProfile {
        if (profile.issue()) |problem| @compileError(gzipProfileIssueMessage(problem));
        return profile;
    }

    pub fn inputBytesPerSlot(profile: GzipProfile, receive_buffer_bytes: u32) u64 {
        return @as(u64, profile.input_chunks_per_slot) * receive_buffer_bytes;
    }
};

pub const connections_hard_max: u16 = 8192;
pub const requests_hard_max: u16 = 8192;
pub const body_workspaces_hard_max: u16 = 8192;
pub const chunked_workspaces_hard_max: u16 = 8192;
pub const receive_buffers_hard_max: u16 = 4096;
pub const buffer_bytes_hard_max: u32 = 1024 * 1024;
pub const response_bytes_hard_max: u32 = 16 * 1024 * 1024;
pub const response_chunk_bytes: u16 = 4096;
pub const response_chunk_count_hard_max: u16 = std.math.maxInt(u16) - 1;
pub const response_chunk_storage_bytes_hard_max: u32 =
    @as(u32, response_chunk_count_hard_max) * response_chunk_bytes;

pub const Issue = enum(u8) {
    connection_slots_zero,
    connection_slots_above_hard_max,
    request_slots_zero,
    request_slots_above_hard_max,
    request_slots_above_connections,
    body_workspace_slots_zero,
    body_workspace_slots_above_hard_max,
    body_workspace_slots_above_requests,
    chunked_workspace_slots_zero,
    chunked_workspace_slots_above_hard_max,
    chunked_workspace_slots_above_body_workspaces,
    chunked_workspace_slots_above_requests,
    gzip_decoder_slots_above_body_workspaces,
    receive_buffers_below_two,
    receive_buffers_not_power_of_two,
    receive_buffers_above_hard_max,
    receive_buffer_bytes_zero,
    receive_buffer_bytes_above_hard_max,
    pipeline_bytes_below_receive_buffer,
    pipeline_bytes_above_hard_max,
    response_bytes_zero,
    response_bytes_above_hard_max,
    response_chunk_count_zero,
    response_chunk_count_reaches_sentinel,
    submission_entries_below_eight,
    submission_entries_above_hard_max,
    submission_entries_not_power_of_two,
    completion_entries_above_hard_max,
    completion_entries_not_power_of_two,
    completion_entries_below_double_submission,
    chunked_profile_invalid,
    gzip_profile_invalid,
    timeout_profile_invalid,
};

pub const Limits = struct {
    connection_slots: u16 = 128,
    request_slots: u16 = 64,
    body_workspace_slots: u16 = 1,
    chunked_workspace_slots: u16 = 1,
    receive_buffers: u16 = 64,
    receive_buffer_bytes: u32 = 16 * 1024,
    pipeline_bytes_per_connection: u32 = 16 * 1024,
    response_bytes_per_request: u32 = 72 * 1024,
    response_chunk_count: u16 = 576,
    submission_entries: u16 = 256,
    completion_entries: u32 = 512,
    chunked: ChunkedProfile = .{},
    gzip: GzipProfile = .{},
    timeouts: runtime_time.TimeoutProfile = .{},

    pub fn issue(limits: Limits) ?Issue {
        if (limits.connection_slots == 0) return .connection_slots_zero;
        if (limits.connection_slots > connections_hard_max) {
            return .connection_slots_above_hard_max;
        }
        if (limits.request_slots == 0) return .request_slots_zero;
        if (limits.request_slots > requests_hard_max) return .request_slots_above_hard_max;
        if (limits.request_slots > limits.connection_slots) {
            return .request_slots_above_connections;
        }
        if (limits.body_workspace_slots == 0) return .body_workspace_slots_zero;
        if (limits.body_workspace_slots > body_workspaces_hard_max) {
            return .body_workspace_slots_above_hard_max;
        }
        if (limits.chunked_workspace_slots == 0) {
            return .chunked_workspace_slots_zero;
        }
        if (limits.chunked_workspace_slots > chunked_workspaces_hard_max) {
            return .chunked_workspace_slots_above_hard_max;
        }
        if (limits.chunked_workspace_slots > limits.body_workspace_slots) {
            return .chunked_workspace_slots_above_body_workspaces;
        }
        if (limits.chunked_workspace_slots > limits.request_slots) {
            return .chunked_workspace_slots_above_requests;
        }
        if (limits.body_workspace_slots > limits.request_slots) {
            return .body_workspace_slots_above_requests;
        }
        if (limits.gzip.decoder_slots > limits.body_workspace_slots) {
            return .gzip_decoder_slots_above_body_workspaces;
        }
        if (limits.receive_buffers < 2) return .receive_buffers_below_two;
        if (!std.math.isPowerOfTwo(limits.receive_buffers)) {
            return .receive_buffers_not_power_of_two;
        }
        if (limits.receive_buffers > receive_buffers_hard_max) {
            return .receive_buffers_above_hard_max;
        }
        if (limits.receive_buffer_bytes == 0) return .receive_buffer_bytes_zero;
        if (limits.receive_buffer_bytes > buffer_bytes_hard_max) {
            return .receive_buffer_bytes_above_hard_max;
        }
        if (limits.pipeline_bytes_per_connection < limits.receive_buffer_bytes) {
            return .pipeline_bytes_below_receive_buffer;
        }
        if (limits.pipeline_bytes_per_connection > buffer_bytes_hard_max) {
            return .pipeline_bytes_above_hard_max;
        }
        if (limits.response_bytes_per_request == 0) return .response_bytes_zero;
        if (limits.response_bytes_per_request > response_bytes_hard_max) {
            return .response_bytes_above_hard_max;
        }
        if (limits.response_chunk_count == 0) return .response_chunk_count_zero;
        if (limits.response_chunk_count > response_chunk_count_hard_max) {
            return .response_chunk_count_reaches_sentinel;
        }
        if (limits.submission_entries < 8) return .submission_entries_below_eight;
        if (limits.submission_entries > 32768) return .submission_entries_above_hard_max;
        if (!std.math.isPowerOfTwo(limits.submission_entries)) {
            return .submission_entries_not_power_of_two;
        }
        if (limits.completion_entries > 65536) return .completion_entries_above_hard_max;
        if (!std.math.isPowerOfTwo(limits.completion_entries)) {
            return .completion_entries_not_power_of_two;
        }
        if (limits.completion_entries < @as(u32, limits.submission_entries) * 2) {
            return .completion_entries_below_double_submission;
        }
        if (limits.chunked.issue() != null) return .chunked_profile_invalid;
        if (limits.gzip.issue() != null) return .gzip_profile_invalid;
        if (limits.timeouts.issue() != null) return .timeout_profile_invalid;
        return null;
    }

    pub fn validate(comptime limits: Limits) Limits {
        _ = ChunkedProfile.validate(limits.chunked);
        _ = GzipProfile.validate(limits.gzip);
        _ = runtime_time.TimeoutProfile.validate(limits.timeouts);
        if (limits.issue()) |problem| @compileError(issueMessage(problem));
        return limits;
    }
};

pub const standard_limits = Limits.validate(.{});

fn issueMessage(problem: Issue) []const u8 {
    return switch (problem) {
        .connection_slots_zero => "connection slot count must be nonzero",
        .connection_slots_above_hard_max => "connection slot count exceeds 8192",
        .request_slots_zero => "request slot count must be nonzero",
        .request_slots_above_hard_max => "request slot count exceeds 8192",
        .request_slots_above_connections => "request slots exceed connection slots",
        .body_workspace_slots_zero => "body workspace slot count must be nonzero",
        .body_workspace_slots_above_hard_max => "body workspace slot count exceeds 8192",
        .body_workspace_slots_above_requests => "body workspace slots exceed request slots",
        .chunked_workspace_slots_zero => "chunked workspace slot count must be nonzero",
        .chunked_workspace_slots_above_hard_max => {
            return "chunked workspace slot count exceeds 8192";
        },
        .chunked_workspace_slots_above_body_workspaces => {
            return "chunked workspace slots exceed body workspace slots";
        },
        .chunked_workspace_slots_above_requests => {
            return "chunked workspace slots exceed request slots";
        },
        .gzip_decoder_slots_above_body_workspaces => {
            return "gzip decoder slots exceed body workspace slots";
        },
        .receive_buffers_below_two => "receive buffer count must be at least two",
        .receive_buffers_not_power_of_two => "receive buffer count must be a power of two",
        .receive_buffers_above_hard_max => "receive buffer count exceeds 4096",
        .receive_buffer_bytes_zero => "receive buffer byte size must be nonzero",
        .receive_buffer_bytes_above_hard_max => "receive buffer size exceeds 1 MiB",
        .pipeline_bytes_below_receive_buffer => "pipeline storage is smaller than receive buffer",
        .pipeline_bytes_above_hard_max => "pipeline storage exceeds 1 MiB per connection",
        .response_bytes_zero => "response staging byte size must be nonzero",
        .response_bytes_above_hard_max => "response staging exceeds 16 MiB per request",
        .response_chunk_count_zero => "response chunk count must be nonzero",
        .response_chunk_count_reaches_sentinel => "response chunk count reaches u16 sentinel",
        .submission_entries_below_eight => "submission queue depth must be at least eight",
        .submission_entries_above_hard_max => "submission queue depth exceeds 32768",
        .submission_entries_not_power_of_two => "submission queue depth must be a power of two",
        .completion_entries_above_hard_max => "completion queue depth exceeds 65536",
        .completion_entries_not_power_of_two => "completion queue depth must be a power of two",
        .completion_entries_below_double_submission => {
            return "completion queue depth must be at least twice submission depth";
        },
        .chunked_profile_invalid => "chunked request profile is invalid",
        .gzip_profile_invalid => "gzip request profile is invalid",
        .timeout_profile_invalid => "runtime timeout profile is invalid",
    };
}

fn gzipProfileIssueMessage(problem: GzipProfileIssue) []const u8 {
    return switch (problem) {
        .decoder_slots_zero => "gzip decoder slot count must be nonzero",
        .decoder_slots_above_hard_max => "gzip decoder slot count exceeds 64",
        .input_chunks_below_two => "gzip input chunks per slot must be at least two",
        .input_chunks_above_hard_max => "gzip input chunks per slot exceeds 64",
        .members_zero => "gzip member count must be nonzero",
        .members_above_hard_max => "gzip member count exceeds 64",
        .thread_stack_below_min => "gzip decoder thread stack is below 128 KiB",
        .thread_stack_above_max => "gzip decoder thread stack exceeds 8 MiB",
        .thread_stack_unaligned => "gzip decoder thread stack is not 4096-byte aligned",
    };
}

test "standard limits are finite and internally consistent" {
    const limits = standard_limits;
    try std.testing.expectEqual(@as(?Issue, null), limits.issue());
    try std.testing.expect(limits.request_slots <= limits.connection_slots);
    try std.testing.expect(limits.body_workspace_slots <= limits.request_slots);
    try std.testing.expect(limits.chunked_workspace_slots <= limits.body_workspace_slots);
    try std.testing.expect(limits.chunked_workspace_slots <= limits.request_slots);
    try std.testing.expect(limits.gzip.decoder_slots <= limits.body_workspace_slots);
    try std.testing.expectEqual(
        @as(u64, 64 * 1024),
        limits.gzip.inputBytesPerSlot(limits.receive_buffer_bytes),
    );
    try std.testing.expect(limits.pipeline_bytes_per_connection >= limits.receive_buffer_bytes);
    try std.testing.expectEqual(@as(u16, 576), limits.response_chunk_count);
    try std.testing.expectEqual(@as(u32, 2304 * 1024), responseChunkStorageBytes(limits));
    try std.testing.expect(
        limits.completion_entries >= @as(u32, limits.submission_entries) * 2,
    );
}

test "limits report representative capacity and queue failures" {
    try expectIssue(.connection_slots_zero, .{ .connection_slots = 0 });
    try expectIssue(.request_slots_above_connections, .{
        .connection_slots = 1,
        .request_slots = 2,
    });
    try expectIssue(.body_workspace_slots_zero, .{ .body_workspace_slots = 0 });
    try expectIssue(.body_workspace_slots_above_hard_max, .{
        .connection_slots = 8192,
        .request_slots = 8192,
        .body_workspace_slots = 8193,
    });
    try expectIssue(.body_workspace_slots_above_requests, .{
        .request_slots = 1,
        .body_workspace_slots = 2,
    });
    try expectIssue(.chunked_workspace_slots_zero, .{ .chunked_workspace_slots = 0 });
    try expectIssue(.chunked_workspace_slots_above_hard_max, .{
        .connection_slots = 8192,
        .request_slots = 8192,
        .body_workspace_slots = 8192,
        .chunked_workspace_slots = 8193,
    });
    try expectIssue(.chunked_workspace_slots_above_body_workspaces, .{
        .request_slots = 2,
        .body_workspace_slots = 1,
        .chunked_workspace_slots = 2,
    });
    try expectIssue(.chunked_workspace_slots_above_requests, .{
        .request_slots = 1,
        .body_workspace_slots = 2,
        .chunked_workspace_slots = 2,
    });
    try expectIssue(.gzip_decoder_slots_above_body_workspaces, .{
        .body_workspace_slots = 1,
        .gzip = .{ .decoder_slots = 2 },
    });
    try expectIssue(.gzip_profile_invalid, .{
        .gzip = .{ .input_chunks_per_slot = 1 },
    });
    try expectIssue(.receive_buffers_not_power_of_two, .{ .receive_buffers = 3 });
    try expectIssue(.pipeline_bytes_below_receive_buffer, .{
        .receive_buffer_bytes = 16,
        .pipeline_bytes_per_connection = 15,
    });
    try expectIssue(.response_chunk_count_zero, .{ .response_chunk_count = 0 });
    try expectIssue(.response_chunk_count_reaches_sentinel, .{
        .response_chunk_count = std.math.maxInt(u16),
    });
    try expectIssue(.completion_entries_below_double_submission, .{
        .submission_entries = 16,
        .completion_entries = 16,
    });
    try expectIssue(.timeout_profile_invalid, .{
        .timeouts = .{ .write_stall_ns = 0 },
    });
    try expectIssue(.chunked_profile_invalid, .{
        .chunked = .{ .chunks_max = 0 },
    });
}

pub fn responseChunkStorageBytes(limits: Limits) u32 {
    return @as(u32, limits.response_chunk_count) * response_chunk_bytes;
}

test "gzip profile bounds slots queue members and thread stacks" {
    const profile = GzipProfile{};
    try std.testing.expectEqual(@as(?GzipProfileIssue, null), profile.issue());
    try std.testing.expectEqual(@as(u64, 64 * 1024), profile.inputBytesPerSlot(16 * 1024));
    try expectGzipIssue(.decoder_slots_zero, .{ .decoder_slots = 0 });
    try expectGzipIssue(.decoder_slots_above_hard_max, .{ .decoder_slots = 65 });
    try expectGzipIssue(.input_chunks_below_two, .{ .input_chunks_per_slot = 1 });
    try expectGzipIssue(.input_chunks_above_hard_max, .{ .input_chunks_per_slot = 65 });
    try expectGzipIssue(.members_zero, .{ .members_max = 0 });
    try expectGzipIssue(.members_above_hard_max, .{ .members_max = 65 });
    try expectGzipIssue(.thread_stack_below_min, .{ .thread_stack_bytes = 127 * 1024 });
    try expectGzipIssue(.thread_stack_above_max, .{ .thread_stack_bytes = 9 * 1024 * 1024 });
    try expectGzipIssue(.thread_stack_unaligned, .{ .thread_stack_bytes = 128 * 1024 + 1 });
}

fn expectIssue(expected: Issue, limits: Limits) !void {
    try std.testing.expectEqual(@as(?Issue, expected), limits.issue());
}

fn expectGzipIssue(expected: GzipProfileIssue, profile: GzipProfile) !void {
    try std.testing.expectEqual(@as(?GzipProfileIssue, expected), profile.issue());
}
