const std = @import("std");
const linux = std.os.linux;

const io_uring_token_table = @import("token_table.zig");
const reactor = @import("../reactor.zig");
const runtime_socket = @import("../socket.zig");

pub fn drain(
    ring: anytype,
    tokens: []u64,
    completion_entries: u32,
) reactor.AbortStatus {
    var status = reactor.AbortStatus{
        .ownership_proven = true,
        .accepted_sockets_discarded = 0,
    };
    var raw: [32]linux.io_uring_cqe = undefined;
    var drained: u32 = 0;
    _ = ring.enter(0, 0, linux.IORING_ENTER_GETEVENTS) catch {
        status.ownership_proven = false;
    };
    drainReady(
        ring,
        tokens,
        &raw,
        completion_entries,
        &drained,
        &status,
    );
    if (drained == completion_entries or
        ring.cq_ready() != 0 or ring.cq_ring_needs_flush())
    {
        status.ownership_proven = false;
    }
    return status;
}

fn drainReady(
    ring: anytype,
    tokens: []u64,
    raw: *[32]linux.io_uring_cqe,
    completion_entries: u32,
    drained: *u32,
    status: *reactor.AbortStatus,
) void {
    while (ring.cq_ready() != 0 and drained.* < completion_entries) {
        const remaining = completion_entries - drained.*;
        const batch_len: usize = @intCast(@min(remaining, raw.len));
        const count = ring.copy_cqes(raw[0..batch_len], 0) catch {
            status.ownership_proven = false;
            return;
        };
        if (count == 0) break;
        drained.* += count;
        for (raw[0..count]) |completion| {
            discardTrackedCompletion(tokens, completion, status);
        }
    }
}

pub fn hasTrackedDescriptorRisk(tokens: []const u64) bool {
    for (tokens) |raw_token| {
        if (raw_token == 0) continue;
        const token = reactor.OperationToken.fromRaw(raw_token) catch return true;
        const fields = token.fields() catch return true;
        if (fields.kind == .accept or fields.kind == .close or
            fields.kind == .file_open or fields.kind == .file_close)
        {
            return true;
        }
    }
    return false;
}

fn discardTrackedCompletion(
    tokens: []u64,
    raw: linux.io_uring_cqe,
    status: *reactor.AbortStatus,
) void {
    const token = reactor.OperationToken.fromRaw(raw.user_data) catch {
        status.ownership_proven = false;
        return;
    };
    if (!io_uring_token_table.contains(tokens, token.raw())) {
        status.ownership_proven = false;
        return;
    }
    const fields = token.fields() catch {
        status.ownership_proven = false;
        return;
    };
    if (fields.kind == .close or fields.kind == .file_close) {
        if (raw.res != 0 or raw.flags != 0) status.ownership_proven = false;
        retireTerminal(tokens, token, raw.flags);
        return;
    }
    if (fields.kind == .accept and raw.res >= 0) {
        runtime_socket.discard(.{ .value = @intCast(raw.res) }) catch {
            status.ownership_proven = false;
            return;
        };
        status.accepted_sockets_discarded += 1;
    } else if (fields.kind == .file_open and raw.res >= 0) {
        if (linux.errno(linux.close(raw.res)) != .SUCCESS) {
            status.ownership_proven = false;
            return;
        }
    }
    retireTerminal(tokens, token, raw.flags);
}

fn retireTerminal(
    tokens: []u64,
    token: reactor.OperationToken,
    flags: u32,
) void {
    if (flags & linux.IORING_CQE_F_MORE == 0 and
        !io_uring_token_table.remove(tokens, token.raw()))
    {
        unreachable;
    }
}
