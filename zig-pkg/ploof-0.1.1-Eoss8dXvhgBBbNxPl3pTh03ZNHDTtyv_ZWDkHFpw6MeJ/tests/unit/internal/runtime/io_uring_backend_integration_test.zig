const std = @import("std");
const linux = std.os.linux;

const address = @import("../../../../src/address.zig");
const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
const config = @import("../../../../src/internal/runtime/config.zig");
const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
const reactor = @import("../../../../src/internal/runtime/reactor.zig");

const limits = config.Limits.validate(.{
    .connection_slots = 2,
    .request_slots = 1,
    .receive_buffers = 2,
    .receive_buffer_bytes = 64,
    .pipeline_bytes_per_connection = 64,
    .response_bytes_per_request = 256,
    .submission_entries = 8,
    .completion_entries = 16,
});
const ReceiveBuffers = buffer_ring.BufferRing(2, 64, 29);
const Backend = io_uring_backend.IoUringBackend(limits, ReceiveBuffers);
const UploadBackend = io_uring_backend.IoUringBackendWithUploads(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = 2,
        .request_handles_max = 2,
        .runtime_handles_max = 1,
        .async_sink_present = true,
    },
);
const StaticBackend = io_uring_backend.IoUringBackendWithFiles(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = 0,
        .request_handles_max = 0,
        .runtime_handles_max = 0,
        .async_sink_present = false,
        .live_static_slots = 1,
        .live_static_roots = 1,
    },
);

test "real backend registers times out and tears down quiescently" {
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const token = try reactor.OperationToken.init(.{
        .kind = .timeout,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try backend.submit(.{
        .token = token,
        .operation = .{ .timeout = .{ .deadline_ns = try deadlineAfter(std.time.ns_per_ms) } },
    });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());

    const completion = try backend.wait();
    try std.testing.expect(completion.token.eql(token));
    try std.testing.expect(!completion.more);
    switch (completion.result) {
        .success => |success| switch (success) {
            .timeout => {},
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(u32, 0), backend.activeCount());
    try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());
    try backend.deinit();
    backend_live = false;
}

test "real backend one-shot selected receive retires without MORE" {
    var sockets: [2]linux.fd_t = undefined;
    const pair_result = linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_result));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const token = try reactor.OperationToken.init(.{
        .kind = .receive,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    try backend.submit(.{
        .token = token,
        .operation = .{ .receive = .{
            .socket = .{ .value = @intCast(sockets[0]) },
            .multishot = false,
        } },
    });
    const sent = linux.sendto(sockets[1], "one", 3, linux.MSG.NOSIGNAL, null, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(sent));
    try std.testing.expectEqual(@as(usize, 3), sent);
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());

    const completion = try backend.wait();
    try std.testing.expect(completion.token.eql(token));
    try std.testing.expect(!completion.more);
    const borrowed = switch (completion.result) {
        .success => |success| switch (success) {
            .receive => |received| switch (received) {
                .bytes => |value| value,
                .end_of_stream => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("one", borrowed.bytes);
    try backend.recycle(borrowed);
    try backend.deinit();
    backend_live = false;
}

test "real backend publishes an anonymous upload through unprivileged procfs link" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: UploadBackend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const descriptor = try openUpload(&backend, temporary.dir.handle);
    var descriptor_live = true;
    defer if (descriptor_live) {
        _ = linux.close(descriptor.value);
    };
    try writeUpload(&backend, descriptor);
    try syncAndCancelUpload(&backend, descriptor);
    try syncUpload(&backend, descriptor);
    try linkUpload(&backend, descriptor, temporary.dir.handle);
    try closeUpload(&backend, descriptor);
    descriptor_live = false;

    try std.testing.expectEqual(
        linux.E.BADF,
        linux.errno(linux.fcntl(descriptor.value, linux.F.GETFD, 0)),
    );
    try expectPublishedUpload(temporary.dir.handle);
    try backend.deinit();
    backend_live = false;
}

test "real backend opens stats reads cancels and closes a confined static file" {
    const contents = "live-static-body";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "asset.txt",
        .data = contents,
    });

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: StaticBackend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const open_token = try testToken(.file_open, 1);
    try backend.submit(.{ .token = open_token, .operation = .{ .file_open = .{
        .base = .{ .directory = .{ .value = temporary.dir.handle } },
        .path = "asset.txt",
        .access = .read_only,
        .resolve = .{
            .beneath = true,
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    } } });
    _ = try backend.flush();
    const descriptor = switch ((try backend.wait()).result) {
        .success => |success| switch (success) {
            .file_open => |value| value,
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    };
    var descriptor_live = true;
    defer if (descriptor_live) {
        _ = linux.close(descriptor.value);
    };

    var statx: linux.Statx = undefined;
    const stat_token = try testToken(.file_stat, 2);
    try backend.submit(.{ .token = stat_token, .operation = .{ .file_stat = .{
        .file = descriptor,
        .output = &statx,
    } } });
    _ = try backend.flush();
    const stat_completion = try backend.wait();
    try std.testing.expect(stat_completion.result.success == .file_stat);
    try std.testing.expect(statx.mask.TYPE and statx.mask.SIZE and statx.mask.MTIME and
        statx.mask.INO);
    try std.testing.expectEqual(@as(u16, 0o100000), statx.mode & 0o170000);
    try std.testing.expectEqual(@as(u64, contents.len), statx.size);

    var read_buffer: [64]u8 = undefined;
    const read_token = try testToken(.file_read, 3);
    try backend.submit(.{ .token = read_token, .operation = .{ .file_read = .{
        .file = descriptor,
        .bytes = &read_buffer,
        .offset = 0,
    } } });
    _ = try backend.flush();
    const read_count = (try backend.wait()).result.success.file_read;
    try std.testing.expectEqual(@as(u32, contents.len), read_count);
    try std.testing.expectEqualStrings(contents, read_buffer[0..read_count]);

    const eof_token = try testToken(.file_read, 4);
    try backend.submit(.{ .token = eof_token, .operation = .{ .file_read = .{
        .file = descriptor,
        .bytes = &read_buffer,
        .offset = contents.len,
    } } });
    _ = try backend.flush();
    try std.testing.expectEqual(@as(u32, 0), (try backend.wait()).result.success.file_read);

    const raced_read_token = try testToken(.file_read, 5);
    const cancel_token = try testToken(.file_cancel, 6);
    try backend.submit(.{ .token = raced_read_token, .operation = .{ .file_read = .{
        .file = descriptor,
        .bytes = &read_buffer,
        .offset = 0,
    } } });
    try backend.submit(.{ .token = cancel_token, .operation = .{ .file_cancel = .{
        .target = raced_read_token,
    } } });
    _ = try backend.flush();
    var read_seen = false;
    var cancel_seen = false;
    for (0..2) |_| {
        const completion = try backend.wait();
        if (completion.token.eql(raced_read_token)) {
            read_seen = true;
            switch (completion.result) {
                .success => |success| try std.testing.expect(success == .file_read),
                .failure => |failure| try std.testing.expectEqual(
                    reactor.CompletionError.canceled,
                    failure,
                ),
            }
        } else if (completion.token.eql(cancel_token)) {
            cancel_seen = true;
            _ = completion.result.success.file_cancel;
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expect(read_seen and cancel_seen);

    const close_token = try testToken(.file_close, 7);
    try backend.submit(.{ .token = close_token, .operation = .{ .file_close = .{
        .file = descriptor,
    } } });
    _ = try backend.flush();
    try std.testing.expect((try backend.wait()).result.success == .file_close);
    descriptor_live = false;
    try backend.deinit();
    backend_live = false;
}

test "real backend accept captures exact IPv4 peer and transfers descriptor ownership" {
    try expectAcceptedPeer(.{ .ipv4 = .{} });
}

test "real backend accept captures exact IPv6 peer when loopback is available" {
    try expectAcceptedPeer(.{ .ipv6 = .{} });
}

test "untracked positive CQE prevents quiescence and requires process exit" {
    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const descriptor_result = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_result));
    const descriptor: linux.fd_t = @intCast(descriptor_result);
    defer _ = linux.close(descriptor);
    const unknown = try reactor.OperationToken.init(.{
        .kind = .accept,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = 1,
    });
    injectCompletion(&backend.ring, .{
        .user_data = unknown.raw(),
        .res = descriptor,
        .flags = 0,
    });

    try std.testing.expectEqual(@as(u32, 1), backend.activeCount());
    try std.testing.expectError(error.NotQuiescent, backend.deinit());
    try std.testing.expectError(error.InvalidCompletion, backend.poll());
    const status = try backend.abort();
    backend_live = false;
    try std.testing.expect(!status.ownership_proven);
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.fcntl(descriptor, linux.F.GETFD, 0)),
    );
}

fn injectCompletion(ring: *linux.IoUring, completion: linux.io_uring_cqe) void {
    const tail = @atomicLoad(u32, ring.cq.tail, .acquire);
    std.debug.assert(tail -% ring.cq.head.* < ring.cq.cqes.len);
    ring.cq.cqes[tail & ring.cq.mask] = completion;
    @atomicStore(u32, ring.cq.tail, tail +% 1, .release);
}

fn deadlineAfter(delta_ns: u64) !u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) {
        return error.ClockUnavailable;
    }
    if (value.sec < 0 or value.nsec < 0) return error.ClockUnavailable;
    const seconds = try std.math.mul(u64, @intCast(value.sec), std.time.ns_per_s);
    const now = try std.math.add(u64, seconds, @intCast(value.nsec));
    return std.math.add(u64, now, delta_ns);
}

fn openUpload(backend: *UploadBackend, directory: linux.fd_t) !reactor.FileDescriptor {
    const token = try testToken(.file_open, 1);
    try backend.submit(.{ .token = token, .operation = .{ .file_open = .{
        .base = .{ .directory = .{ .value = directory } },
        .path = ".",
        .access = .read_write,
        .create = .anonymous,
        .mode = 0o600,
        .resolve = .{
            .beneath = true,
            .no_symlinks = true,
            .no_magic_links = true,
            .no_mount_crossing = true,
        },
    } } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    return switch (completion.result) {
        .success => |success| switch (success) {
            .file_open => |descriptor| descriptor,
            else => error.TestUnexpectedResult,
        },
        .failure => error.TestUnexpectedResult,
    };
}

fn writeUpload(backend: *UploadBackend, descriptor: reactor.FileDescriptor) !void {
    const token = try testToken(.file_write, 2);
    try backend.submit(.{ .token = token, .operation = .{ .file_write = .{
        .file = descriptor,
        .bytes = "upload body",
        .offset = 0,
    } } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    switch (completion.result) {
        .success => |success| switch (success) {
            .file_write => |written| try std.testing.expectEqual(@as(u32, 11), written),
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

fn syncAndCancelUpload(
    backend: *UploadBackend,
    descriptor: reactor.FileDescriptor,
) !void {
    const sync_token = try testToken(.file_sync, 3);
    const cancel_token = try testToken(.upload_cancel, 4);
    try backend.submit(.{ .token = sync_token, .operation = .{
        .file_sync = .{ .file = descriptor },
    } });
    try backend.submit(.{ .token = cancel_token, .operation = .{
        .upload_cancel = .{ .target = sync_token },
    } });
    try std.testing.expectEqual(@as(u32, 2), try backend.flush());
    var sync_seen = false;
    var cancel_seen = false;
    for (0..2) |_| {
        const completion = try backend.wait();
        if (completion.token.eql(sync_token)) {
            sync_seen = true;
            switch (completion.result) {
                .success => |success| switch (success) {
                    .file_sync => {},
                    else => return error.TestUnexpectedResult,
                },
                .failure => |failure| try std.testing.expect(failure == .canceled),
            }
        } else if (completion.token.eql(cancel_token)) {
            cancel_seen = true;
            switch (completion.result) {
                .success => |success| switch (success) {
                    .upload_cancel => {},
                    else => return error.TestUnexpectedResult,
                },
                .failure => return error.TestUnexpectedResult,
            }
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expect(sync_seen and cancel_seen);
}

fn syncUpload(backend: *UploadBackend, descriptor: reactor.FileDescriptor) !void {
    const token = try testToken(.file_sync, 5);
    try backend.submit(.{ .token = token, .operation = .{
        .file_sync = .{ .file = descriptor },
    } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    switch (completion.result) {
        .success => |success| switch (success) {
            .file_sync => {},
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

fn closeUpload(backend: *UploadBackend, descriptor: reactor.FileDescriptor) !void {
    const token = try testToken(.file_close, 7);
    try backend.submit(.{ .token = token, .operation = .{
        .file_close = .{ .file = descriptor },
    } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    switch (completion.result) {
        .success => |success| switch (success) {
            .file_close => {},
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

fn linkUpload(
    backend: *UploadBackend,
    descriptor: reactor.FileDescriptor,
    directory: linux.fd_t,
) !void {
    const token = try testToken(.file_link, 6);
    try backend.submit(.{ .token = token, .operation = .{ .file_link = .{
        .source = descriptor,
        .target_directory = .{ .value = directory },
        .target_path = "published.bin",
    } } });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());
    const completion = try backend.wait();
    switch (completion.result) {
        .success => |success| switch (success) {
            .file_link => {},
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    }
}

fn expectPublishedUpload(directory: linux.fd_t) !void {
    const open_result = linux.openat(
        directory,
        "published.bin",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(open_result));
    const descriptor: linux.fd_t = @intCast(open_result);
    defer _ = linux.close(descriptor);
    var buffer: [16]u8 = undefined;
    const read_result = linux.read(descriptor, &buffer, buffer.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read_result));
    try std.testing.expectEqualStrings("upload body", buffer[0..read_result]);
}

fn expectAcceptedPeer(requested: listener_runtime.Address) !void {
    var listener = try openListener(requested);
    defer _ = listener.close();

    var buffers: ReceiveBuffers.Buffers = undefined;
    var backend: Backend = undefined;
    try backend.init(&buffers);
    var backend_live = true;
    defer if (backend_live) {
        _ = backend.abort() catch {};
    };

    const token = try testToken(.accept, 1);
    try backend.submit(.{
        .token = token,
        .operation = .{ .accept = .{ .listener = listener.socket } },
    });
    try std.testing.expectEqual(@as(u32, 1), try backend.flush());

    const client = try connectClient(listener.bound_address);
    defer _ = linux.close(client);
    const expected = try clientEndpoint(client, listener.bound_address);
    try std.testing.expect(expected.port != 0);

    const completion = try backend.wait();
    try std.testing.expect(completion.token.eql(token));
    try std.testing.expect(!completion.more);
    const accepted = switch (completion.result) {
        .success => |success| switch (success) {
            .accept => |value| value,
            else => return error.TestUnexpectedResult,
        },
        .failure => return error.TestUnexpectedResult,
    };
    var accepted_live = true;
    defer if (accepted_live) {
        _ = backend.discard(accepted.socket) catch {};
    };
    try std.testing.expect(accepted.peer.eql(expected));
    try expectAcceptedFlags(accepted.socket);

    try backend.discard(accepted.socket);
    accepted_live = false;
    const fd: linux.fd_t = @intCast(accepted.socket.value);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(u32, 0), backend.activeCount());
    try std.testing.expectEqual(@as(u32, 0), backend.trackedTokenCount());
    try backend.deinit();
    backend_live = false;
}

fn openListener(requested: listener_runtime.Address) !listener_runtime.Listener {
    return switch (listener_runtime.open(.{ .address = requested })) {
        .listener => |value| value,
        .failure => |failure| switch (failure) {
            .syscall => |syscall| {
                if (requested == .ipv6 and ipv6Unavailable(syscall.errno)) {
                    return error.Ipv6Unavailable;
                }
                return error.ListenerOpenFailed;
            },
            else => error.ListenerOpenFailed,
        },
    };
}

fn connectClient(bound: listener_runtime.Address) !linux.fd_t {
    const family: u32 = switch (bound) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const result = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    const socket_errno = linux.errno(result);
    if (socket_errno != .SUCCESS) {
        if (bound == .ipv6 and ipv6Unavailable(socket_errno)) {
            return error.Ipv6Unavailable;
        }
        return error.SocketFailed;
    }
    const client: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(client);
    const connect_result = switch (bound) {
        .ipv4 => |value| connectIpv4(client, value),
        .ipv6 => |value| connectIpv6(client, value),
    };
    const connect_errno = linux.errno(connect_result);
    if (connect_errno != .SUCCESS) return error.ConnectFailed;
    return client;
}

fn connectIpv4(client: linux.fd_t, value: listener_runtime.Ipv4Address) usize {
    const socket_address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, value.port),
        .addr = @bitCast(value.bytes),
    };
    return linux.connect(client, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in));
}

fn connectIpv6(client: linux.fd_t, value: listener_runtime.Ipv6Address) usize {
    const socket_address = linux.sockaddr.in6{
        .family = linux.AF.INET6,
        .port = std.mem.nativeToBig(u16, value.port),
        .flowinfo = std.mem.nativeToBig(u32, value.flowinfo),
        .addr = value.bytes,
        .scope_id = value.scope_id,
    };
    return linux.connect(client, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in6));
}

fn clientEndpoint(
    client: linux.fd_t,
    bound: listener_runtime.Address,
) !address.Endpoint {
    return switch (bound) {
        .ipv4 => |value| clientIpv4Endpoint(client, value.bytes),
        .ipv6 => |value| clientIpv6Endpoint(client, value.bytes),
    };
}

fn clientIpv4Endpoint(client: linux.fd_t, expected: [4]u8) !address.Endpoint {
    var socket_address: linux.sockaddr.in = undefined;
    var length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const result = linux.getsockname(client, @ptrCast(&socket_address), &length);
    if (linux.errno(result) != .SUCCESS or length != @sizeOf(linux.sockaddr.in) or
        socket_address.family != linux.AF.INET)
    {
        return error.ClientAddressFailed;
    }
    const bytes: *const [4]u8 = @ptrCast(&socket_address.addr);
    try std.testing.expectEqual(expected, bytes.*);
    return address.Endpoint.initIpv4(
        bytes.*,
        std.mem.bigToNative(u16, socket_address.port),
    );
}

fn clientIpv6Endpoint(client: linux.fd_t, expected: [16]u8) !address.Endpoint {
    var socket_address: linux.sockaddr.in6 = undefined;
    var length: linux.socklen_t = @sizeOf(linux.sockaddr.in6);
    const result = linux.getsockname(client, @ptrCast(&socket_address), &length);
    if (linux.errno(result) != .SUCCESS or length != @sizeOf(linux.sockaddr.in6) or
        socket_address.family != linux.AF.INET6)
    {
        return error.ClientAddressFailed;
    }
    try std.testing.expectEqual(expected, socket_address.addr);
    return address.Endpoint.initIpv6(
        socket_address.addr,
        std.mem.bigToNative(u16, socket_address.port),
    );
}

fn expectAcceptedFlags(socket: reactor.Socket) !void {
    if (socket.value > std.math.maxInt(linux.fd_t)) return error.InvalidAcceptedSocket;
    const fd: linux.fd_t = @intCast(socket.value);
    const descriptor_flags = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_flags));
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);
    const status_flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_flags));
    try std.testing.expect(status_flags & linux.SOCK.NONBLOCK != 0);
}

fn testToken(kind: reactor.OperationKind, sequence: u16) !reactor.OperationToken {
    return reactor.OperationToken.init(.{
        .kind = kind,
        .worker_index = 0,
        .slot_index = 0,
        .slot_generation = 1,
        .sequence = sequence,
    });
}

fn ipv6Unavailable(problem: linux.E) bool {
    return problem == .AFNOSUPPORT or problem == .ADDRNOTAVAIL or
        problem == .PROTONOSUPPORT;
}
