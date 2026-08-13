const std = @import("std");
const forwarding = @import("../../forwarding.zig");
const authority_parser = @import("../http1/authority.zig");
const request_cors = @import("../http1/request_cors.zig");
const syntax = @import("../http1/syntax.zig");

pub const capacity_hard_max: u16 = 64;
pub const host_bytes_hard_max: u16 = 1024;

pub const SetIssue = enum(u8) {
    uninitialized,
    empty,
    too_many,
    invalid_origin,
    opaque_origin,
    unsupported_scheme,
    host_too_long,
    duplicate_origin,
};

pub const InitFailure = struct {
    issue: SetIssue,
    index: ?u16 = null,
};

pub const HeaderValue = union(enum) {
    absent,
    multiple,
    value: []const u8,
};

pub const Headers = struct {
    fetch_site: HeaderValue = .absent,
    origin: HeaderValue = .absent,
    referer: HeaderValue = .absent,
};

pub const GateDecision = enum(u8) {
    allow,
    forbidden,
    misdirected,
};

pub const FetchSite = enum(u8) {
    same_origin,
    same_site,
    cross_site,
    none,
    unknown,
};

pub fn OriginSet(comptime capacity: u16, comptime host_bytes_max: u16) type {
    comptime validateLimits(capacity, host_bytes_max);
    const origin_bytes_max: usize = @as(usize, host_bytes_max) + 16;
    const seal_seed: u64 = 0x706c_6f6f_662e_6373;

    return struct {
        const Self = @This();

        pub const ploof_csrf_origin_set = true;
        pub const origins_max = capacity;
        pub const host_max = host_bytes_max;

        const Entry = struct {
            bytes: [origin_bytes_max]u8 = [_]u8{0} ** origin_bytes_max,
            length: u16 = 0,
            seal: u64 = 0,

            fn slice(entry: *const Entry) ?[]const u8 {
                if (entry.length == 0 or entry.length > origin_bytes_max) return null;
                return entry.bytes[0..entry.length];
            }

            fn validSlice(entry: *const Entry, index: u16) ?[]const u8 {
                const raw = entry.slice() orelse return null;
                if (entry.seal != entrySeal(index, raw)) return null;
                return raw;
            }
        };

        entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
        count_value: u16 = 0,
        initialized: bool = false,

        pub const InitResult = union(enum) {
            set: Self,
            failure: InitFailure,
        };

        pub fn init(values: []const []const u8) error{InvalidOriginSet}!Self {
            return switch (initDetailed(values)) {
                .set => |set| set,
                .failure => error.InvalidOriginSet,
            };
        }

        pub fn initDetailed(values: []const []const u8) InitResult {
            if (values.len == 0) return fail(.empty, null);
            if (values.len > capacity) return fail(.too_many, capacity);

            var set = Self{};
            for (values, 0..) |raw, index| {
                const parsed = request_cors.parseOrigin(raw) orelse {
                    return fail(.invalid_origin, index);
                };
                const tuple = switch (parsed) {
                    .opaque_null => return fail(.opaque_origin, index),
                    .tuple => |tuple| tuple,
                };
                const scheme = authority_parser.parseScheme(tuple.scheme) orelse {
                    return fail(.unsupported_scheme, index);
                };
                const parsed_authority = tuple.canonical_authority orelse {
                    return fail(.invalid_origin, index);
                };
                if (tuple.host.len > host_bytes_max or raw.len > origin_bytes_max) {
                    return fail(.host_too_long, index);
                }
                var canonical_storage: [origin_bytes_max]u8 = undefined;
                const canonical = canonicalOrigin(
                    scheme,
                    parsed_authority,
                    &canonical_storage,
                ) orelse return fail(.host_too_long, index);
                for (set.entries[0..set.count_value]) |*entry| {
                    if (std.mem.eql(u8, canonical, entry.slice().?)) {
                        return fail(.duplicate_origin, index);
                    }
                }
                const entry = &set.entries[set.count_value];
                @memcpy(entry.bytes[0..canonical.len], canonical);
                entry.length = @intCast(canonical.len);
                entry.seal = entrySeal(set.count_value, canonical);
                set.count_value += 1;
            }
            set.initialized = true;
            return .{ .set = set };
        }

        pub fn issue(set: *const Self) ?SetIssue {
            if (!set.initialized) return .uninitialized;
            if (set.count_value == 0) return .empty;
            if (set.count_value > capacity) return .too_many;
            for (set.entries[0..set.count_value], 0..) |*entry, index| {
                const raw = entry.slice() orelse return if (entry.length > origin_bytes_max)
                    .host_too_long
                else
                    .invalid_origin;
                const parsed = request_cors.parseOrigin(raw) orelse return .invalid_origin;
                const tuple = switch (parsed) {
                    .opaque_null => return .opaque_origin,
                    .tuple => |tuple| tuple,
                };
                const scheme = authority_parser.parseScheme(tuple.scheme) orelse {
                    return .unsupported_scheme;
                };
                const parsed_authority = tuple.canonical_authority orelse {
                    return .invalid_origin;
                };
                if (tuple.host.len > host_bytes_max or raw.len > origin_bytes_max) {
                    return .host_too_long;
                }
                var canonical_storage: [origin_bytes_max]u8 = undefined;
                const canonical = canonicalOrigin(
                    scheme,
                    parsed_authority,
                    &canonical_storage,
                ) orelse return .host_too_long;
                if (!std.mem.eql(u8, canonical, raw)) return .invalid_origin;
                if (entry.validSlice(@intCast(index)) == null) return .invalid_origin;
                for (set.entries[0..index], 0..) |*previous, previous_index| {
                    const previous_raw = previous.validSlice(@intCast(previous_index)) orelse {
                        return .invalid_origin;
                    };
                    if (std.mem.eql(u8, raw, previous_raw)) {
                        return .duplicate_origin;
                    }
                }
            }
            return null;
        }

        pub fn count(set: *const Self) u16 {
            return set.count_value;
        }

        pub fn at(set: *const Self, index: u16) ?[]const u8 {
            if (set.issue() != null) return null;
            if (index >= set.count_value) return null;
            return set.entries[index].slice();
        }

        pub fn containsRaw(set: *const Self, raw: []const u8) bool {
            const parsed = request_cors.parseOrigin(raw) orelse return false;
            return set.containsParsed(parsed);
        }

        pub fn containsParsed(set: *const Self, parsed: request_cors.Origin) bool {
            if (!set.shapeValid() or parsed == .opaque_null) return false;
            const tuple = parsed.tuple;
            const scheme = authority_parser.parseScheme(tuple.scheme) orelse return false;
            const parsed_authority = tuple.canonical_authority orelse return false;
            var canonical_storage: [origin_bytes_max]u8 = undefined;
            const canonical = canonicalOrigin(
                scheme,
                parsed_authority,
                &canonical_storage,
            ) orelse return false;
            var matches: u16 = 0;
            for (set.entries[0..set.count_value], 0..) |*entry, index| {
                const stored = entry.validSlice(@intCast(index)) orelse return false;
                matches += @intFromBool(std.mem.eql(u8, canonical, stored));
            }
            return matches == 1;
        }

        pub fn containsEffective(
            set: *const Self,
            scheme: forwarding.Scheme,
            authority: forwarding.Authority,
        ) bool {
            if (!set.shapeValid()) return false;
            var canonical_storage: [origin_bytes_max]u8 = undefined;
            const canonical = canonicalOrigin(
                scheme,
                authority,
                &canonical_storage,
            ) orelse return false;
            var matches: u16 = 0;
            for (set.entries[0..set.count_value], 0..) |*entry, index| {
                const stored = entry.validSlice(@intCast(index)) orelse return false;
                matches += @intFromBool(std.mem.eql(u8, canonical, stored));
            }
            return matches == 1;
        }

        fn shapeValid(set: *const Self) bool {
            return set.initialized and set.count_value > 0 and set.count_value <= capacity;
        }

        fn entrySeal(index: u16, raw: []const u8) u64 {
            return std.hash.Wyhash.hash(seal_seed ^ index, raw);
        }

        fn fail(issue_value: SetIssue, index: ?usize) InitResult {
            return .{ .failure = .{
                .issue = issue_value,
                .index = if (index) |value| @intCast(value) else null,
            } };
        }
    };
}

fn canonicalOrigin(
    scheme: forwarding.Scheme,
    authority: forwarding.Authority,
    output: []u8,
) ?[]const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll(switch (scheme) {
        .http => "http://",
        .https => "https://",
    }) catch return null;
    authority.formatCanonical(&writer) catch return null;
    return writer.buffered();
}

pub fn gate(
    public_origins: anytype,
    source_origins: anytype,
    effective_scheme: ?forwarding.Scheme,
    effective_authority: ?forwarding.Authority,
    unsafe_method: bool,
    headers: Headers,
) GateDecision {
    const scheme = effective_scheme orelse return .misdirected;
    const authority = effective_authority orelse return .misdirected;
    if (!public_origins.containsEffective(scheme, authority)) return .misdirected;
    if (!unsafe_method) return .allow;

    if (headers.fetch_site == .multiple) return .forbidden;
    if (checkSourceOrigin(source_origins, headers.origin, headers.referer)) |decision| {
        return decision;
    }
    return switch (headers.fetch_site) {
        .value => |value| if (parseFetchSite(value) == .cross_site)
            .forbidden
        else
            .allow,
        .absent => .allow,
        .multiple => unreachable,
    };
}

pub fn parseFetchSite(value: []const u8) FetchSite {
    if (std.mem.eql(u8, value, "same-origin")) return .same_origin;
    if (std.mem.eql(u8, value, "same-site")) return .same_site;
    if (std.mem.eql(u8, value, "cross-site")) return .cross_site;
    if (std.mem.eql(u8, value, "none")) return .none;
    return .unknown;
}

pub fn parseRefererOrigin(value: []const u8) ?request_cors.Origin {
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '#') != null) return null;
    var scan_index: usize = 0;
    while (scan_index < value.len) : (scan_index += 1) {
        const byte = value[scan_index];
        if (byte <= ' ' or byte >= 0x7f or byte == '\\') return null;
        if (byte == '%') {
            if (scan_index + 2 >= value.len or
                !std.ascii.isHex(value[scan_index + 1]) or
                !std.ascii.isHex(value[scan_index + 2])) return null;
            scan_index += 2;
        }
    }
    const separator = std.mem.indexOf(u8, value, "://") orelse return null;
    const scheme = value[0..separator];
    if (authority_parser.parseScheme(scheme) == null) return null;

    const authority_start = separator + 3;
    if (authority_start == value.len) return null;
    var origin_end = value.len;
    for (value[authority_start..], authority_start..) |byte, index| {
        if (byte == '/' or byte == '?') {
            origin_end = index;
            break;
        }
    }
    return request_cors.parseOrigin(value[0..origin_end]);
}

pub fn unsafeMethod(method: []const u8) bool {
    return !std.mem.eql(u8, method, "GET") and
        !std.mem.eql(u8, method, "HEAD") and
        !std.mem.eql(u8, method, "OPTIONS");
}

fn checkSourceOrigin(
    origins: anytype,
    origin: HeaderValue,
    referer: HeaderValue,
) ?GateDecision {
    switch (origin) {
        .multiple => return .forbidden,
        .value => |value| {
            const parsed = request_cors.parseOrigin(value) orelse return .forbidden;
            return if (origins.containsParsed(parsed)) .allow else .forbidden;
        },
        .absent => {},
    }
    return switch (referer) {
        .multiple => .forbidden,
        .value => |value| blk: {
            const parsed = parseRefererOrigin(value) orelse break :blk .forbidden;
            break :blk if (origins.containsParsed(parsed)) .allow else .forbidden;
        },
        .absent => null,
    };
}

fn validateLimits(comptime capacity: u16, comptime host_bytes_max: u16) void {
    if (capacity == 0 or capacity > capacity_hard_max) {
        @compileError("PLOOF-E3600 CSRF origin capacity must be between 1 and 64");
    }
    if (host_bytes_max == 0 or host_bytes_max > host_bytes_hard_max) {
        @compileError("PLOOF-E3601 CSRF origin host limit must be between 1 and 1024 bytes");
    }
}

comptime {
    std.debug.assert(syntax.isToken("Sec-Fetch-Site"));
}

test {
    std.testing.refAllDecls(@This());
}
