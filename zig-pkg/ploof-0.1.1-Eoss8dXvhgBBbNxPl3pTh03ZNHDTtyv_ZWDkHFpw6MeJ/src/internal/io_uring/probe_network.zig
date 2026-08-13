const std = @import("std");
const linux = std.os.linux;

const IoUring = linux.IoUring;
const accept_probe = @import("probe_accept.zig");
const model = @import("probe_types.zig");
const runtime = @import("probe_runtime.zig");

const Context = model.Context;
const Failure = model.Failure;
const Operation = model.Operation;
const Phase = model.Phase;
const Proof = model.Proof;

const buffer_count = runtime.buffer_count;
const buffer_group_id = runtime.buffer_group_id;
const buffer_size = runtime.buffer_size;
const max_poll_iterations = runtime.max_poll_iterations;
const BufferRing = runtime.BufferRing;
const Tag = runtime.Tag;
const cancelAndReap = runtime.cancelAndReap;
const completionFailure = runtime.completionFailure;
const deadlineFromNow = runtime.deadlineFromNow;
const pumpUntilRetry = runtime.pumpUntilRetry;
const submissionFailure = runtime.submissionFailure;
const submitPending = runtime.submitPending;
const waitFailure = runtime.waitFailure;
const waitOne = runtime.waitOne;
const waitOneUntil = runtime.waitOneUntil;

pub fn proveNetwork(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
    proofs: *Proof,
) ?Failure {
    var address = linux.sockaddr.in{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    const listener = switch (createListener(context, &address)) {
        .fd => |fd| fd,
        .failure => |failure| return failure,
    };
    var clients = [_]linux.fd_t{ -1, -1 };
    var accepted = [_]linux.fd_t{ -1, -1 };
    var race_client: linux.fd_t = -1;
    var accept_state = accept_probe.State{};
    var failure = proveNetworkInner(
        context,
        ring,
        buffer_ring,
        buffers,
        proofs,
        &address,
        listener,
        &clients,
        &accepted,
        &race_client,
        &accept_state,
    );
    const close_errno = closeNetworkDescriptors(
        listener,
        &clients,
        &accepted,
        race_client,
    );
    if (close_errno != .SUCCESS) {
        if (failure) |*existing| {
            existing.markProcessExitRequired();
        } else {
            failure = context.failure(
                .cleanup_failed,
                .cleanup,
                .close,
                .multishot_accept,
                close_errno,
                1,
                0,
            );
            failure.?.markProcessExitRequired();
        }
    }
    return failure;
}

fn proveNetworkInner(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
    proofs: *Proof,
    address: *const linux.sockaddr.in,
    listener: linux.fd_t,
    clients: *[2]linux.fd_t,
    accepted: *[2]linux.fd_t,
    race_client: *linux.fd_t,
    accept_state: *accept_probe.State,
) ?Failure {
    if (accept_probe.submit(context, ring, listener, accept_state)) |failure| {
        return accept_probe.unwind(context, ring, accept_state, failure);
    }
    if (connectClients(context, address, clients)) |failure| {
        return accept_probe.unwind(context, ring, accept_state, failure);
    }
    if (accept_probe.reapTwo(context, ring, accepted, accept_state)) |failure| {
        return accept_probe.unwind(context, ring, accept_state, failure);
    }
    proofs.multishot_accept = true;

    race_client.* = switch (connectClient(context, address)) {
        .fd => |fd| fd,
        .failure => |failure| {
            return accept_probe.unwind(context, ring, accept_state, failure);
        },
    };
    if (accept_probe.cancelAndDrain(context, ring, accept_state)) |failure| {
        return failure;
    }
    proofs.cancellation = true;

    const client_index = switch (findPeerClient(context, accepted[0], clients)) {
        .index => |index| index,
        .failure => |failure| return failure,
    };
    if (proveReceive(
        context,
        ring,
        buffer_ring,
        buffers,
        accepted[0],
        clients[client_index],
        proofs,
    )) |failure| return failure;
    return proveSend(context, ring, accepted[0], clients[client_index], proofs);
}

fn connectClients(
    context: *const Context,
    address: *const linux.sockaddr.in,
    clients: *[2]linux.fd_t,
) ?Failure {
    for (clients) |*client| {
        client.* = switch (connectClient(context, address)) {
            .fd => |fd| fd,
            .failure => |failure| return failure,
        };
    }
    return null;
}

fn submitReceive(context: *const Context, ring: *IoUring, accepted: linux.fd_t) ?Failure {
    const receive_sqe = ring.recv(
        @intFromEnum(Tag.receive),
        accepted,
        .{ .buffer_selection = .{
            .group_id = buffer_group_id,
            .len = 0,
        } },
        0,
    ) catch {
        return submissionFailure(
            context,
            .multishot_receive,
            .recv,
            .SUCCESS,
            1,
            0,
        );
    };
    receive_sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
    return submitPending(context, ring, .multishot_receive, .recv);
}

fn proveReceive(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
    accepted: linux.fd_t,
    client: linux.fd_t,
    proofs: *Proof,
) ?Failure {
    if (submitReceive(context, ring, accepted)) |failure| return failure;

    const payload = "r";
    if (sendRaw(context, ring, client, payload, .multishot_receive)) |failure| {
        return failure;
    }
    if (completeReceive(context, ring, buffer_ring, buffers, payload)) |failure| {
        return failure;
    }
    proofs.provided_buffer_receive = true;
    return cancelAndReap(
        context,
        ring,
        .receive,
        .cancel_receive,
        .multishot_receive,
        .recv,
    );
}

fn completeReceive(
    context: *const Context,
    ring: *IoUring,
    buffer_ring: *BufferRing,
    buffers: *[buffer_count][buffer_size]u8,
    payload: []const u8,
) ?Failure {
    const expected_result: i64 = @intCast(payload.len);
    const receive_cqe = switch (waitOne(ring)) {
        .cqe => |value| value,
        .failure => |wait_failure| {
            return waitFailure(
                context,
                .multishot_receive,
                .recv,
                .multishot_receive,
                wait_failure,
            );
        },
    };
    if (receive_cqe.user_data != @intFromEnum(Tag.receive) or
        receive_cqe.res != expected_result or
        receive_cqe.flags & linux.IORING_CQE_F_BUFFER == 0 or
        receive_cqe.flags & linux.IORING_CQE_F_MORE == 0 or
        receive_cqe.flags & linux.IORING_CQE_F_BUF_MORE != 0)
    {
        return completionFailure(
            context,
            .multishot_receive,
            .recv,
            receive_cqe,
            @intFromEnum(Tag.receive),
            expected_result,
        );
    }
    const buffer_id = receive_cqe.buffer_id() catch {
        return completionFailure(
            context,
            .multishot_receive,
            .recv,
            receive_cqe,
            @intFromEnum(Tag.receive),
            expected_result,
        );
    };
    if (buffer_id >= buffer_count or
        !std.mem.eql(u8, buffers[buffer_id][0..payload.len], payload))
    {
        return context.failure(
            .runtime_invariant,
            .multishot_receive,
            .recv,
            .multishot_receive,
            .SUCCESS,
            expected_result,
            buffer_id,
        );
    }
    IoUring.buf_ring_add(
        buffer_ring.ring,
        &buffers[buffer_id],
        buffer_id,
        IoUring.buf_ring_mask(buffer_count),
        0,
    );
    IoUring.buf_ring_advance(buffer_ring.ring, 1);
    return null;
}

fn proveSend(
    context: *const Context,
    ring: *IoUring,
    accepted: linux.fd_t,
    client: linux.fd_t,
    proofs: *Proof,
) ?Failure {
    const payload = "s";
    _ = ring.send(
        @intFromEnum(Tag.send),
        accepted,
        payload,
        linux.MSG.NOSIGNAL,
    ) catch {
        return submissionFailure(context, .send, .send, .SUCCESS, 1, 0);
    };
    if (submitPending(context, ring, .send, .send)) |failure| return failure;
    const send_cqe = switch (waitOne(ring)) {
        .cqe => |value| value,
        .failure => |wait_failure| {
            return waitFailure(context, .send, .send, .selected_send, wait_failure);
        },
    };
    if (send_cqe.user_data != @intFromEnum(Tag.send) or
        send_cqe.res != payload.len)
    {
        return completionFailure(
            context,
            .send,
            .send,
            send_cqe,
            @intFromEnum(Tag.send),
            payload.len,
        );
    }
    if (receiveRaw(context, ring, client, payload)) |failure| return failure;
    proofs.send = true;
    return null;
}

fn createListener(context: *const Context, address: *linux.sockaddr.in) union(enum) {
    fd: linux.fd_t,
    failure: Failure,
} {
    const socket_result = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    const socket_errno = linux.errno(socket_result);
    if (socket_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .socket, socket_errno) };
    }
    const fd: linux.fd_t = @intCast(socket_result);
    var fd_live = true;
    defer {
        if (fd_live) _ = linux.close(fd);
    }

    const bind_result = linux.bind(fd, @ptrCast(address), @sizeOf(linux.sockaddr.in));
    const bind_errno = linux.errno(bind_result);
    if (bind_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .bind, bind_errno) };
    }

    const listen_result = linux.listen(fd, 2);
    const listen_errno = linux.errno(listen_result);
    if (listen_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .listen, listen_errno) };
    }

    var address_length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const name_result = linux.getsockname(fd, @ptrCast(address), &address_length);
    const name_errno = linux.errno(name_result);
    if (name_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .bind, name_errno) };
    }
    if (address_length != @sizeOf(linux.sockaddr.in) or address.port == 0) {
        return .{ .failure = context.failure(
            .runtime_invariant,
            .listener,
            .bind,
            .multishot_accept,
            .SUCCESS,
            @sizeOf(linux.sockaddr.in),
            address_length,
        ) };
    }
    fd_live = false;
    return .{ .fd = fd };
}

fn connectClient(context: *const Context, address: *const linux.sockaddr.in) union(enum) {
    fd: linux.fd_t,
    failure: Failure,
} {
    const socket_result = linux.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
        0,
    );
    const socket_errno = linux.errno(socket_result);
    if (socket_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .socket, socket_errno) };
    }
    const fd: linux.fd_t = @intCast(socket_result);
    var fd_live = true;
    defer {
        if (fd_live) _ = linux.close(fd);
    }

    const connect_result = linux.connect(fd, address, @sizeOf(linux.sockaddr.in));
    const connect_errno = linux.errno(connect_result);
    if (connect_errno != .SUCCESS and connect_errno != .INPROGRESS) {
        return .{ .failure = socketFailure(context, .connect, connect_errno) };
    }
    fd_live = false;
    return .{ .fd = fd };
}

fn findPeerClient(
    context: *const Context,
    accepted: linux.fd_t,
    clients: *const [2]linux.fd_t,
) union(enum) {
    index: usize,
    failure: Failure,
} {
    var peer: linux.sockaddr.in = undefined;
    var peer_length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const peer_result = linux.getpeername(accepted, @ptrCast(&peer), &peer_length);
    const peer_errno = linux.errno(peer_result);
    if (peer_errno != .SUCCESS) {
        return .{ .failure = socketFailure(context, .connect, peer_errno) };
    }

    for (clients, 0..) |client, index| {
        var local: linux.sockaddr.in = undefined;
        var local_length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const local_result = linux.getsockname(client, @ptrCast(&local), &local_length);
        const local_errno = linux.errno(local_result);
        if (local_errno != .SUCCESS) {
            return .{ .failure = socketFailure(context, .connect, local_errno) };
        }
        if (peer.port == local.port and peer.addr == local.addr) {
            return .{ .index = index };
        }
    }

    return .{ .failure = context.failure(
        .runtime_invariant,
        .listener,
        .connect,
        .multishot_accept,
        .SUCCESS,
        1,
        0,
    ) };
}

fn sendRaw(
    context: *const Context,
    ring: *IoUring,
    fd: linux.fd_t,
    bytes: []const u8,
    phase: Phase,
) ?Failure {
    const deadline = deadlineFromNow() orelse {
        return waitFailure(
            context,
            phase,
            .send,
            .multishot_receive,
            .{ .errno = .SUCCESS, .kind = .clock_unavailable },
        );
    };
    var iteration: u32 = 0;
    while (iteration < max_poll_iterations) : (iteration += 1) {
        const result = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
        const errno_value = linux.errno(result);
        if (errno_value == .SUCCESS) {
            if (result == bytes.len) return null;
            return context.failure(
                .runtime_invariant,
                phase,
                .send,
                .multishot_receive,
                .SUCCESS,
                @intCast(bytes.len),
                @intCast(result),
            );
        }
        if (errno_value != .AGAIN) {
            return context.failure(
                .socket_probe_failed,
                phase,
                .send,
                .multishot_receive,
                errno_value,
                0,
                0,
            );
        }
        if (pumpUntilRetry(ring, deadline)) |failure| {
            return waitFailure(context, phase, .send, .multishot_receive, failure);
        }
    }
    return context.failure(
        .probe_timed_out,
        phase,
        .send,
        .multishot_receive,
        .SUCCESS,
        max_poll_iterations,
        iteration,
    );
}

fn receiveRaw(
    context: *const Context,
    ring: *IoUring,
    fd: linux.fd_t,
    expected: []const u8,
) ?Failure {
    var buffer: [buffer_size]u8 = undefined;
    const deadline = deadlineFromNow() orelse {
        return waitFailure(
            context,
            .send,
            .recv,
            .selected_send,
            .{ .errno = .SUCCESS, .kind = .clock_unavailable },
        );
    };
    var iteration: u32 = 0;
    while (iteration < max_poll_iterations) : (iteration += 1) {
        const result = linux.recvfrom(
            fd,
            &buffer,
            buffer.len,
            linux.MSG.DONTWAIT,
            null,
            null,
        );
        const errno_value = linux.errno(result);
        if (errno_value == .SUCCESS) {
            if (result == expected.len and std.mem.eql(u8, buffer[0..result], expected)) {
                return null;
            }
            return context.failure(
                .runtime_invariant,
                .send,
                .recv,
                .selected_send,
                .SUCCESS,
                @intCast(expected.len),
                @intCast(result),
            );
        }
        if (errno_value != .AGAIN) {
            return context.failure(
                .socket_probe_failed,
                .send,
                .recv,
                .selected_send,
                errno_value,
                0,
                0,
            );
        }
        if (pumpUntilRetry(ring, deadline)) |failure| {
            return waitFailure(context, .send, .recv, .selected_send, failure);
        }
    }
    return context.failure(
        .probe_timed_out,
        .send,
        .recv,
        .selected_send,
        .SUCCESS,
        max_poll_iterations,
        iteration,
    );
}

fn socketFailure(context: *const Context, operation: Operation, errno_value: linux.E) Failure {
    return context.failure(
        .socket_probe_failed,
        .listener,
        operation,
        .multishot_accept,
        errno_value,
        0,
        0,
    );
}

fn closeNetworkDescriptors(
    listener: linux.fd_t,
    clients: *const [2]linux.fd_t,
    accepted: *const [2]linux.fd_t,
    race_client: linux.fd_t,
) linux.E {
    var first_errno: linux.E = .SUCCESS;
    closeDescriptor(race_client, &first_errno);
    for (accepted) |fd| closeDescriptor(fd, &first_errno);
    for (clients) |fd| closeDescriptor(fd, &first_errno);
    closeDescriptor(listener, &first_errno);
    return first_errno;
}

fn closeDescriptor(fd: linux.fd_t, first_errno: *linux.E) void {
    if (fd < 0) return;
    const errno_value = linux.errno(linux.close(fd));
    if (errno_value != .SUCCESS and first_errno.* == .SUCCESS) {
        first_errno.* = errno_value;
    }
}
