const std = @import("std");
const syntax = @import("internal/url/syntax.zig");

pub const url_bytes_hard_max = syntax.url_bytes_hard_max;
pub const url_bytes_standard_max = syntax.url_bytes_standard_max;
pub const ValidationError = syntax.ValidationError;
pub const BuildError = syntax.BuildError;
pub const Scheme = syntax.Scheme;
pub const FinishError = BuildError || ValidationError;

pub const WebError = ValidationError || error{HostNotAllowed};
pub const ContactError = ValidationError || BuildError || error{InvalidMailbox};

pub const Limits = struct {
    bytes_max: u32 = url_bytes_standard_max,

    pub fn validate(comptime limits: Limits) Limits {
        if (limits.bytes_max == 0) {
            @compileError("PLOOF-E3700 URL byte limit must be nonzero");
        }
        if (limits.bytes_max > url_bytes_hard_max) {
            @compileError("PLOOF-E3701 URL byte limit exceeds 64 KiB");
        }
        return limits;
    }
};

pub const standard_limits = Limits.validate(.{});

pub const HostPolicy = union(enum) {
    deny,
    any,
    allowlist: []const []const u8,

    fn allows(comptime policy: HostPolicy, host: syntax.Host) bool {
        return switch (policy) {
            .deny => false,
            .any => true,
            .allowlist => |allowed| allow: {
                inline for (allowed) |candidate| {
                    const configured = comptime syntax.parseHost(candidate) catch unreachable;
                    if (host.eql(configured)) break :allow true;
                }
                break :allow false;
            },
        };
    }
};

pub const WebPolicy = struct {
    https: HostPolicy,
    http: HostPolicy = .deny,

    pub fn validate(comptime policy: WebPolicy) WebPolicy {
        @setEvalBranchQuota(100_000);
        if (policy.https == .deny) {
            @compileError("PLOOF-E3702 web URL policy must select HTTPS hosts");
        }
        validateHostPolicy(policy.https, "HTTPS");
        validateHostPolicy(policy.http, "HTTP");
        return policy;
    }

    pub fn anyHttps() WebPolicy {
        return .{ .https = .any };
    }

    pub fn exactHttps(comptime hosts: []const []const u8) WebPolicy {
        return validate(.{ .https = .{ .allowlist = hosts } });
    }
};

pub const Url = struct {
    bytes_value: []const u8,
    kind_value: Kind,

    pub const ploof_url = true;

    pub const Kind = enum(u3) {
        local,
        http,
        https,
        mailto,
        tel,
    };

    pub fn local(input: []const u8) ValidationError!Url {
        return localWith(input, standard_limits);
    }

    pub fn localWith(input: []const u8, comptime requested: Limits) ValidationError!Url {
        const limits = comptime requested.validate();
        try syntax.validateLocal(input, limits.bytes_max);
        return .{ .bytes_value = input, .kind_value = .local };
    }

    pub fn web(input: []const u8, comptime requested: WebPolicy) WebError!Url {
        return webWith(input, requested, standard_limits);
    }

    pub fn webWith(
        input: []const u8,
        comptime requested_policy: WebPolicy,
        comptime requested_limits: Limits,
    ) WebError!Url {
        const policy = comptime requested_policy.validate();
        const limits = comptime requested_limits.validate();
        const parsed = try syntax.parseWeb(input, limits.bytes_max);
        const allowed = switch (parsed.scheme) {
            .http => policy.http.allows(parsed.host),
            .https => policy.https.allows(parsed.host),
        };
        if (!allowed) return error.HostNotAllowed;
        return .{
            .bytes_value = input,
            .kind_value = if (parsed.scheme == .https) .https else .http,
        };
    }

    pub fn mailto(address: []const u8, output: []u8) ContactError!Url {
        const separator = std.mem.indexOfScalar(u8, address, '@') orelse {
            return error.InvalidMailbox;
        };
        if (separator == 0 or separator + 1 == address.len) return error.InvalidMailbox;
        if (std.mem.indexOfScalarPos(u8, address, separator + 1, '@') != null) {
            return error.InvalidMailbox;
        }
        const domain = address[separator + 1 ..];
        _ = syntax.parseHost(domain) catch return error.InvalidMailbox;

        var buffer = try Buffer.init(output);
        try buffer.appendLiteral("mailto:");
        try buffer.appendComponent(address[0..separator]);
        try buffer.appendLiteral("@");
        try buffer.appendLiteral(domain);
        return .{ .bytes_value = buffer.slice(), .kind_value = .mailto };
    }

    pub fn tel(number: []const u8, output: []u8) ContactError!Url {
        if (number.len == 0) return error.EmptyComponent;
        var buffer = try Buffer.init(output);
        try buffer.appendLiteral("tel:");
        try buffer.appendComponent(number);
        return .{ .bytes_value = buffer.slice(), .kind_value = .tel };
    }

    pub fn bytes(url: Url) []const u8 {
        return url.bytes_value;
    }

    pub fn kind(url: Url) Kind {
        return url.kind_value;
    }

    pub fn validatedCopy(url: Url) ValidationError!Url {
        switch (url.kind_value) {
            .local => try syntax.validateLocal(url.bytes_value, url_bytes_hard_max),
            .http, .https => {
                const parsed = try syntax.parseWeb(url.bytes_value, url_bytes_hard_max);
                if (url.kind_value == .http and parsed.scheme != .http) {
                    return error.UnsupportedScheme;
                }
                if (url.kind_value == .https and parsed.scheme != .https) {
                    return error.UnsupportedScheme;
                }
            },
            .mailto => try validateMailto(url.bytes_value),
            .tel => try validateTel(url.bytes_value),
        }
        return url;
    }
};

pub const LocalBuilder = struct {
    components: Components,

    pub fn init(output: []u8) BuildError!LocalBuilder {
        var buffer = try Buffer.init(output);
        try buffer.appendLiteral("/");
        return .{ .components = .{ .buffer = buffer, .root_present = true } };
    }

    pub fn segment(builder: *LocalBuilder, value: []const u8) BuildError!void {
        try builder.components.segment(value);
    }

    pub fn query(builder: *LocalBuilder, name: []const u8, value: []const u8) BuildError!void {
        try builder.components.query(name, value);
    }

    pub fn fragment(builder: *LocalBuilder, value: []const u8) BuildError!void {
        try builder.components.fragment(value);
    }

    pub fn finish(builder: *const LocalBuilder) FinishError!Url {
        const result = Url{
            .bytes_value = try builder.components.buffer.checkedSlice(),
            .kind_value = .local,
        };
        _ = try result.validatedCopy();
        return result;
    }
};

pub const WebOrigin = struct {
    scheme: Scheme = .https,
    host: []const u8,
    port: ?u16 = null,
};

pub const WebBuilder = struct {
    components: Components,
    scheme: Scheme,

    pub fn init(
        output: []u8,
        origin: WebOrigin,
        comptime requested_policy: WebPolicy,
    ) (BuildError || WebError)!WebBuilder {
        const policy = comptime requested_policy.validate();
        const host = try syntax.parseHost(origin.host);
        const allowed = switch (origin.scheme) {
            .http => policy.http.allows(host),
            .https => policy.https.allows(host),
        };
        if (!allowed) return error.HostNotAllowed;

        var buffer = try Buffer.init(output);
        try buffer.appendLiteral(origin.scheme.wire());
        try buffer.appendLiteral("://");
        try buffer.appendLiteral(origin.host);
        if (origin.port) |port| {
            if (port != origin.scheme.defaultPort()) try appendPort(&buffer, port);
        }
        return .{
            .components = .{ .buffer = buffer },
            .scheme = origin.scheme,
        };
    }

    pub fn segment(builder: *WebBuilder, value: []const u8) BuildError!void {
        try builder.components.segment(value);
    }

    pub fn query(builder: *WebBuilder, name: []const u8, value: []const u8) BuildError!void {
        try builder.components.query(name, value);
    }

    pub fn fragment(builder: *WebBuilder, value: []const u8) BuildError!void {
        try builder.components.fragment(value);
    }

    pub fn finish(builder: *const WebBuilder) FinishError!Url {
        const result = Url{
            .bytes_value = try builder.components.buffer.checkedSlice(),
            .kind_value = if (builder.scheme == .https) .https else .http,
        };
        _ = try result.validatedCopy();
        return result;
    }
};

const Phase = enum(u2) {
    path,
    query,
    fragment,
};

const Components = struct {
    buffer: Buffer,
    phase: Phase = .path,
    segment_count: u16 = 0,
    query_count: u16 = 0,
    root_present: bool = false,

    fn segment(components: *Components, value: []const u8) BuildError!void {
        if (components.phase != .path) return error.InvalidOrder;
        if (value.len == 0) return error.EmptyComponent;
        try validateBuilderSegment(value);
        const checkpoint = components.buffer.length;
        errdefer components.buffer.length = checkpoint;
        if (components.segment_count > 0 or !components.root_present) {
            try components.buffer.appendLiteral("/");
        }
        try components.buffer.appendComponent(value);
        components.segment_count = std.math.add(u16, components.segment_count, 1) catch {
            return error.TooLong;
        };
    }

    fn query(components: *Components, name: []const u8, value: []const u8) BuildError!void {
        if (components.phase == .fragment) return error.InvalidOrder;
        try validateBuilderComponent(name);
        try validateBuilderComponent(value);
        const checkpoint = components.buffer.length;
        errdefer components.buffer.length = checkpoint;
        try components.buffer.appendLiteral(if (components.query_count == 0) "?" else "&");
        try components.buffer.appendComponent(name);
        try components.buffer.appendLiteral("=");
        try components.buffer.appendComponent(value);
        components.query_count = std.math.add(u16, components.query_count, 1) catch {
            return error.TooLong;
        };
        components.phase = .query;
    }

    fn fragment(components: *Components, value: []const u8) BuildError!void {
        if (components.phase == .fragment) return error.InvalidOrder;
        try validateBuilderComponent(value);
        const checkpoint = components.buffer.length;
        errdefer components.buffer.length = checkpoint;
        try components.buffer.appendLiteral("#");
        try components.buffer.appendComponent(value);
        components.phase = .fragment;
    }
};

const Buffer = struct {
    storage: []u8,
    length: u32 = 0,

    fn init(storage: []u8) BuildError!Buffer {
        if (storage.len == 0) return error.NoSpace;
        return .{ .storage = storage };
    }

    fn appendLiteral(buffer: *Buffer, value: []const u8) BuildError!void {
        if (value.len > url_bytes_hard_max) return error.TooLong;
        const addition: u32 = @intCast(value.len);
        const end = std.math.add(u32, buffer.length, addition) catch return error.TooLong;
        if (end > url_bytes_hard_max) return error.TooLong;
        if (end > buffer.storage.len) return error.NoSpace;
        @memcpy(buffer.storage[buffer.length..end], value);
        buffer.length = end;
    }

    fn appendComponent(buffer: *Buffer, value: []const u8) BuildError!void {
        const encoded_length = try syntax.encodedLength(value);
        const end = std.math.add(u32, buffer.length, encoded_length) catch {
            return error.TooLong;
        };
        if (end > url_bytes_hard_max) return error.TooLong;
        if (end > buffer.storage.len) return error.NoSpace;
        const written = try syntax.writeEncoded(value, buffer.storage[buffer.length..end]);
        std.debug.assert(written == encoded_length);
        buffer.length = end;
    }

    fn slice(buffer: *const Buffer) []const u8 {
        std.debug.assert(buffer.length <= buffer.storage.len);
        return buffer.storage[0..buffer.length];
    }

    fn checkedSlice(buffer: *const Buffer) BuildError![]const u8 {
        if (buffer.length > url_bytes_hard_max) return error.TooLong;
        if (buffer.length > buffer.storage.len) return error.NoSpace;
        return buffer.storage[0..buffer.length];
    }
};

fn validateHostPolicy(comptime policy: HostPolicy, comptime scheme: []const u8) void {
    switch (policy) {
        .deny, .any => {},
        .allowlist => |hosts| {
            if (hosts.len == 0 or hosts.len > 64) {
                @compileError(
                    "PLOOF-E3703 " ++ scheme ++ " host allowlist must contain 1 to 64 hosts",
                );
            }
            for (hosts) |host| {
                _ = syntax.parseHost(host) catch {
                    @compileError("PLOOF-E3704 invalid " ++ scheme ++ " web URL host: " ++ host);
                };
            }
        },
    }
}

fn validateMailto(input: []const u8) ValidationError!void {
    if (input.len > url_bytes_hard_max) return error.TooLong;
    if (!std.mem.startsWith(u8, input, "mailto:")) return error.UnsupportedScheme;
    const address = input["mailto:".len..];
    const separator = std.mem.indexOfScalar(u8, address, '@') orelse {
        return error.ForbiddenByte;
    };
    if (separator == 0 or separator + 1 == address.len) return error.ForbiddenByte;
    if (std.mem.indexOfScalarPos(u8, address, separator + 1, '@') != null) {
        return error.ForbiddenByte;
    }
    try syntax.validateOpaqueComponent(address[0..separator]);
    _ = try syntax.parseHost(address[separator + 1 ..]);
}

fn validateTel(input: []const u8) ValidationError!void {
    if (input.len > url_bytes_hard_max) return error.TooLong;
    if (!std.mem.startsWith(u8, input, "tel:")) return error.UnsupportedScheme;
    const number = input["tel:".len..];
    if (number.len == 0) return error.Empty;
    try syntax.validateOpaqueComponent(number);
}

fn validateBuilderComponent(input: []const u8) BuildError!void {
    if (std.mem.indexOfScalar(u8, input, '\\') != null) return error.InvalidComponent;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
}

fn validateBuilderSegment(input: []const u8) BuildError!void {
    try validateBuilderComponent(input);
    if (std.mem.indexOfScalar(u8, input, '/') != null or
        std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, ".."))
    {
        return error.InvalidComponent;
    }
}

fn appendPort(buffer: *Buffer, port: u16) BuildError!void {
    var storage: [5]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    writer.print("{d}", .{port}) catch return error.NoSpace;
    try buffer.appendLiteral(":");
    try buffer.appendLiteral(writer.buffered());
}

comptime {
    std.debug.assert(url_bytes_standard_max > 0);
    std.debug.assert(url_bytes_standard_max <= url_bytes_hard_max);
}
