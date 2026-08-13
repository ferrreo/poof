const std = @import("std");
const linux = std.os.linux;
const reactor = @import("reactor.zig");

pub const backlog_max: u32 = std.math.maxInt(i32);

pub const Ipv4Address = struct {
    bytes: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 0,
};

pub const Ipv6Address = struct {
    bytes: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
    port: u16 = 0,
    flowinfo: u32 = 0,
    scope_id: u32 = 0,
};

pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,
};

pub const ConfigIssue = enum(u8) {
    backlog_zero,
    backlog_above_max,
};

pub const Config = struct {
    address: Address = .{ .ipv4 = .{} },
    backlog: u32 = 4096,

    pub fn issue(config: Config) ?ConfigIssue {
        if (config.backlog == 0) return .backlog_zero;
        if (config.backlog > backlog_max) return .backlog_above_max;
        return null;
    }
};

pub const Stage = enum(u8) {
    socket,
    reuse_address,
    reuse_port,
    bind,
    listen,
    bound_address,
    close,
};

pub const SyscallFailure = struct {
    stage: Stage,
    errno: linux.E,
};

pub const BoundAddressIssue = enum(u8) {
    unexpected_size,
    unexpected_family,
    zero_port,
};

pub const Failure = union(enum) {
    config: ConfigIssue,
    syscall: SyscallFailure,
    bound_address: BoundAddressIssue,
};

pub const Listener = struct {
    socket: reactor.Socket,
    bound_address: Address,
    live: bool = true,

    pub fn close(listener: *Listener) ?SyscallFailure {
        if (!listener.live) return null;
        listener.live = false;
        const close_errno = linux.errno(linux.close(socketFd(listener.socket)));
        if (close_errno != .SUCCESS) {
            return .{ .stage = .close, .errno = close_errno };
        }
        return null;
    }
};

pub const OpenResult = union(enum) {
    listener: Listener,
    failure: Failure,
};

pub fn open(config: Config) OpenResult {
    if (config.issue()) |problem| return .{ .failure = .{ .config = problem } };

    const family: u32 = switch (config.address) {
        .ipv4 => linux.AF.INET,
        .ipv6 => linux.AF.INET6,
    };
    const socket_result = linux.socket(
        family,
        linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        0,
    );
    const socket_errno = linux.errno(socket_result);
    if (socket_errno != .SUCCESS) return syscallResult(.socket, socket_errno);

    const fd: linux.fd_t = @intCast(socket_result);
    if (setReuse(fd, linux.SO.REUSEADDR)) |failure| {
        return closeAfterFailure(fd, syscallResult(.reuse_address, failure));
    }
    if (setReuse(fd, linux.SO.REUSEPORT)) |failure| {
        return closeAfterFailure(fd, syscallResult(.reuse_port, failure));
    }
    if (bindAddress(fd, config.address)) |failure| {
        return closeAfterFailure(fd, .{ .failure = failure });
    }

    const listen_errno = linux.errno(linux.listen(fd, config.backlog));
    if (listen_errno != .SUCCESS) {
        return closeAfterFailure(fd, syscallResult(.listen, listen_errno));
    }

    const bound = switch (readBoundAddress(fd, config.address)) {
        .address => |address| address,
        .failure => |failure| return closeAfterFailure(fd, .{ .failure = failure }),
    };

    return .{ .listener = .{
        .socket = .{ .value = @intCast(fd) },
        .bound_address = bound,
    } };
}

fn setReuse(fd: linux.fd_t, option: u32) ?linux.E {
    const enabled: i32 = 1;
    const result = linux.setsockopt(
        fd,
        linux.SOL.SOCKET,
        option,
        @ptrCast(&enabled),
        @sizeOf(i32),
    );
    const result_errno = linux.errno(result);
    return if (result_errno == .SUCCESS) null else result_errno;
}

fn bindAddress(fd: linux.fd_t, address: Address) ?Failure {
    const bind_result = switch (address) {
        .ipv4 => |ipv4| bindIpv4(fd, ipv4),
        .ipv6 => |ipv6| bindIpv6(fd, ipv6),
    };
    const bind_errno = linux.errno(bind_result);
    if (bind_errno != .SUCCESS) {
        return .{ .syscall = .{ .stage = .bind, .errno = bind_errno } };
    }
    return null;
}

fn bindIpv4(fd: linux.fd_t, address: Ipv4Address) usize {
    const socket_address = ipv4Sockaddr(address);
    return linux.bind(fd, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in));
}

fn bindIpv6(fd: linux.fd_t, address: Ipv6Address) usize {
    const socket_address = ipv6Sockaddr(address);
    return linux.bind(fd, @ptrCast(&socket_address), @sizeOf(linux.sockaddr.in6));
}

const BoundResult = union(enum) {
    address: Address,
    failure: Failure,
};

fn readBoundAddress(fd: linux.fd_t, requested: Address) BoundResult {
    return switch (requested) {
        .ipv4 => readBoundIpv4(fd),
        .ipv6 => readBoundIpv6(fd),
    };
}

fn readBoundIpv4(fd: linux.fd_t) BoundResult {
    var socket_address: linux.sockaddr.in = undefined;
    var address_length: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const result = linux.getsockname(fd, @ptrCast(&socket_address), &address_length);
    const result_errno = linux.errno(result);
    if (result_errno != .SUCCESS) return syscallFailure(.bound_address, result_errno);
    if (address_length != @sizeOf(linux.sockaddr.in)) {
        return boundAddressFailure(.unexpected_size);
    }
    if (socket_address.family != linux.AF.INET) {
        return boundAddressFailure(.unexpected_family);
    }

    const address = ipv4FromSockaddr(socket_address);
    if (address.port == 0) return boundAddressFailure(.zero_port);
    return .{ .address = .{ .ipv4 = address } };
}

fn readBoundIpv6(fd: linux.fd_t) BoundResult {
    var socket_address: linux.sockaddr.in6 = undefined;
    var address_length: linux.socklen_t = @sizeOf(linux.sockaddr.in6);
    const result = linux.getsockname(fd, @ptrCast(&socket_address), &address_length);
    const result_errno = linux.errno(result);
    if (result_errno != .SUCCESS) return syscallFailure(.bound_address, result_errno);
    if (address_length != @sizeOf(linux.sockaddr.in6)) {
        return boundAddressFailure(.unexpected_size);
    }
    if (socket_address.family != linux.AF.INET6) {
        return boundAddressFailure(.unexpected_family);
    }

    const address = ipv6FromSockaddr(socket_address);
    if (address.port == 0) return boundAddressFailure(.zero_port);
    return .{ .address = .{ .ipv6 = address } };
}

fn ipv4Sockaddr(address: Ipv4Address) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, address.port),
        .addr = @bitCast(address.bytes),
    };
}

fn ipv4FromSockaddr(address: linux.sockaddr.in) Ipv4Address {
    return .{
        .bytes = @bitCast(address.addr),
        .port = std.mem.bigToNative(u16, address.port),
    };
}

fn ipv6Sockaddr(address: Ipv6Address) linux.sockaddr.in6 {
    return .{
        .family = linux.AF.INET6,
        .port = std.mem.nativeToBig(u16, address.port),
        .flowinfo = std.mem.nativeToBig(u32, address.flowinfo),
        .addr = address.bytes,
        .scope_id = address.scope_id,
    };
}

fn ipv6FromSockaddr(address: linux.sockaddr.in6) Ipv6Address {
    return .{
        .bytes = address.addr,
        .port = std.mem.bigToNative(u16, address.port),
        .flowinfo = std.mem.bigToNative(u32, address.flowinfo),
        .scope_id = address.scope_id,
    };
}

fn socketFd(socket: reactor.Socket) linux.fd_t {
    std.debug.assert(socket.value <= std.math.maxInt(linux.fd_t));
    return @intCast(socket.value);
}

fn syscallResult(stage: Stage, syscall_errno: linux.E) OpenResult {
    return .{ .failure = .{ .syscall = .{ .stage = stage, .errno = syscall_errno } } };
}

fn closeAfterFailure(fd: linux.fd_t, failure: OpenResult) OpenResult {
    std.debug.assert(failure == .failure);
    const close_errno = linux.errno(linux.close(fd));
    if (close_errno != .SUCCESS) return syscallResult(.close, close_errno);
    return failure;
}

fn syscallFailure(stage: Stage, syscall_errno: linux.E) BoundResult {
    return .{ .failure = .{ .syscall = .{ .stage = stage, .errno = syscall_errno } } };
}

fn boundAddressFailure(issue: BoundAddressIssue) BoundResult {
    return .{ .failure = .{ .bound_address = issue } };
}

test "listener config rejects non-positive and overflowing backlog" {
    try std.testing.expectEqual(@as(?ConfigIssue, null), (Config{}).issue());
    switch ((Config{}).address) {
        .ipv4 => |address| {
            try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, address.bytes);
            try std.testing.expectEqual(@as(u16, 0), address.port);
        },
        .ipv6 => return error.UnexpectedDefaultAddress,
    }
    try std.testing.expectEqual(
        @as(?ConfigIssue, .backlog_zero),
        (Config{ .backlog = 0 }).issue(),
    );
    try std.testing.expectEqual(
        @as(?ConfigIssue, .backlog_above_max),
        (Config{ .backlog = backlog_max + 1 }).issue(),
    );

    const result = open(.{ .backlog = 0 });
    switch (result) {
        .failure => |failure| switch (failure) {
            .config => |issue| try std.testing.expectEqual(ConfigIssue.backlog_zero, issue),
            else => return error.UnexpectedFailure,
        },
        .listener => return error.UnexpectedSuccess,
    }
}

test "IPv4 and IPv6 socket addresses round trip through Linux layouts" {
    const ipv4 = Ipv4Address{ .bytes = .{ 192, 0, 2, 9 }, .port = 8443 };
    try std.testing.expectEqualDeep(ipv4, ipv4FromSockaddr(ipv4Sockaddr(ipv4)));

    const ipv6 = Ipv6Address{
        .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 },
        .port = 9443,
        .flowinfo = 7,
        .scope_id = 3,
    };
    try std.testing.expectEqualDeep(ipv6, ipv6FromSockaddr(ipv6Sockaddr(ipv6)));
}

test "listener binds loopback port zero with required descriptor and socket options" {
    var listener = switch (open(.{})) {
        .listener => |value| value,
        .failure => return error.ListenerOpenFailed,
    };
    defer _ = listener.close();

    const bound = switch (listener.bound_address) {
        .ipv4 => |value| value,
        .ipv6 => return error.UnexpectedAddressFamily,
    };
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, bound.bytes);
    try std.testing.expect(bound.port != 0);

    const fd = socketFd(listener.socket);
    try expectSocketOption(fd, linux.SO.REUSEADDR, 1);
    try expectSocketOption(fd, linux.SO.REUSEPORT, 1);
    try expectSocketOption(fd, linux.SO.ACCEPTCONN, 1);

    const status_flags = linux.fcntl(fd, linux.F.GETFL, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(status_flags));
    try std.testing.expect(status_flags & linux.SOCK.NONBLOCK != 0);

    const descriptor_flags = linux.fcntl(fd, linux.F.GETFD, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(descriptor_flags));
    try std.testing.expect(descriptor_flags & linux.FD_CLOEXEC != 0);

    try std.testing.expectEqual(@as(?SyscallFailure, null), listener.close());
    try std.testing.expectEqual(@as(?SyscallFailure, null), listener.close());
}

test "listener binds IPv6 loopback and reads the kernel address" {
    var listener = switch (open(.{ .address = .{ .ipv6 = .{} } })) {
        .listener => |value| value,
        .failure => |failure| switch (failure) {
            .syscall => |syscall| if (syscall.errno == .AFNOSUPPORT or
                syscall.errno == .ADDRNOTAVAIL)
            {
                return error.Ipv6Unavailable;
            } else return error.ListenerOpenFailed,
            else => return error.ListenerOpenFailed,
        },
    };
    defer _ = listener.close();

    const bound = switch (listener.bound_address) {
        .ipv6 => |value| value,
        .ipv4 => return error.UnexpectedAddressFamily,
    };
    try std.testing.expectEqual((Ipv6Address{}).bytes, bound.bytes);
    try std.testing.expect(bound.port != 0);
    try std.testing.expectEqual(@as(u32, 0), bound.flowinfo);
    try std.testing.expectEqual(@as(u32, 0), bound.scope_id);
}

fn expectSocketOption(fd: linux.fd_t, option: u32, expected: i32) !void {
    var value: i32 = 0;
    var value_length: linux.socklen_t = @sizeOf(i32);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        option,
        @ptrCast(&value),
        &value_length,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    try std.testing.expectEqual(@as(linux.socklen_t, @sizeOf(i32)), value_length);
    try std.testing.expectEqual(expected, value);
}
