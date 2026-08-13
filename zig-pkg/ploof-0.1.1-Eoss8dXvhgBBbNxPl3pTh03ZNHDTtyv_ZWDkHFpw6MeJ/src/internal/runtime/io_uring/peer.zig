const std = @import("std");
const linux = std.os.linux;
const address = @import("../../../address.zig");

pub fn accepted(
    storage: *const linux.sockaddr.storage,
    length: linux.socklen_t,
) ?address.Endpoint {
    if (length < @sizeOf(linux.sa_family_t)) return null;
    return switch (storage.family) {
        linux.AF.INET => ipv4(storage, length),
        linux.AF.INET6 => ipv6(storage, length),
        else => null,
    };
}

fn ipv4(
    storage: *const linux.sockaddr.storage,
    length: linux.socklen_t,
) ?address.Endpoint {
    if (length < @sizeOf(linux.sockaddr.in)) return null;
    const value: *const linux.sockaddr.in = @ptrCast(storage);
    const bytes: *const [4]u8 = @ptrCast(&value.addr);
    return address.Endpoint.initIpv4(
        bytes.*,
        std.mem.bigToNative(u16, value.port),
    );
}

fn ipv6(
    storage: *const linux.sockaddr.storage,
    length: linux.socklen_t,
) ?address.Endpoint {
    if (length < @sizeOf(linux.sockaddr.in6)) return null;
    const value: *const linux.sockaddr.in6 = @ptrCast(storage);
    return address.Endpoint.initIpv6(
        value.addr,
        std.mem.bigToNative(u16, value.port),
    );
}

test {
    _ = std.testing.refAllDecls(@This());
}
