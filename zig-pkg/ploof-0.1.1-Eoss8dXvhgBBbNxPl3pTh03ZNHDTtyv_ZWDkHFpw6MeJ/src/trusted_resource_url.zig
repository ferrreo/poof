const std = @import("std");
const syntax = @import("internal/url/syntax.zig");

pub const TrustedResourceUrl = opaque {
    pub const ploof_trusted_resource_url = true;

    pub const Kind = enum(u1) {
        local,
        https,
    };

    pub const Provenance = enum(u1) {
        literal,
        startup_table,
    };

    pub fn literal(comptime input: []const u8) *const TrustedResourceUrl {
        if (input.len > 0 and input[0] == '/') {
            comptime syntax.validateLocal(input, syntax.url_bytes_hard_max) catch |problem| {
                @compileError(
                    "PLOOF-E3710 invalid trusted resource URL literal: " ++ @errorName(problem),
                );
            };
            const Holder = struct {
                const value = Value{
                    .bytes_value = .{ .borrowed = input },
                    .kind_value = .local,
                    .provenance = .literal,
                    .allowed_origin = null,
                    .seal = 0,
                    .content_seal = 0,
                };
            };
            return asResource(&Holder.value);
        }
        const parsed = comptime syntax.parseWeb(
            input,
            syntax.url_bytes_hard_max,
        ) catch |problem| {
            @compileError(
                "PLOOF-E3710 invalid trusted resource URL literal: " ++ @errorName(problem),
            );
        };
        if (parsed.scheme != .https) {
            @compileError("PLOOF-E3711 trusted resource URL literal must use HTTPS");
        }
        const Holder = struct {
            const value = Value{
                .bytes_value = .{ .borrowed = input },
                .kind_value = .https,
                .provenance = .literal,
                .allowed_origin = null,
                .seal = 0,
                .content_seal = 0,
            };
        };
        return asResource(&Holder.value);
    }

    pub fn bytes(resource: *const TrustedResourceUrl) []const u8 {
        return resourceValue(resource).checkedBytes() catch "";
    }

    pub fn validatedBytes(resource: *const TrustedResourceUrl) AccessError![]const u8 {
        const value = resourceValue(resource);
        const bytes_value = try value.checkedBytes();
        try validateValue(value, bytes_value);
        return bytes_value;
    }

    pub fn kind(resource: *const TrustedResourceUrl) Kind {
        return resourceValue(resource).kind_value;
    }

    pub fn provenance(resource: *const TrustedResourceUrl) Provenance {
        return resourceValue(resource).provenance;
    }

    pub fn validate(resource: *const TrustedResourceUrl) AccessError!void {
        _ = try resource.validatedBytes();
    }
};

const relative_offset_hard_max: u32 = 32 * 1024 * 1024;
const value_seal_seed: u64 = 0x7265_736f_7572_6365;

const RelativeBytes = struct {
    offset: i32,
    length: u32,
    capacity: u32,

    fn slice(relative: RelativeBytes, value: *const Value) AccessError![]const u8 {
        if (relative.length == 0 or relative.length > relative.capacity) {
            return error.CorruptState;
        }
        const magnitude = offsetMagnitude(relative.offset) orelse return error.CorruptState;
        if (magnitude > relative_offset_hard_max) return error.CorruptState;
        const value_address = @intFromPtr(value);
        const address = if (relative.offset < 0)
            std.math.sub(usize, value_address, magnitude) catch return error.CorruptState
        else
            std.math.add(usize, value_address, magnitude) catch return error.CorruptState;
        const pointer: [*]const u8 = @ptrFromInt(address);
        return pointer[0..relative.length];
    }
};

const StoredBytes = struct {
    borrowed: []const u8 = "",
    relative: ?RelativeBytes = null,
};

const Value = struct {
    bytes_value: StoredBytes,
    kind_value: TrustedResourceUrl.Kind,
    provenance: TrustedResourceUrl.Provenance,
    allowed_origin: ?[]const u8,
    seal: u64,
    content_seal: u64,

    fn checkedBytes(value: *const Value) AccessError![]const u8 {
        if (value.bytes_value.relative) |relative| {
            if (value.bytes_value.borrowed.len != 0 or value.provenance != .startup_table or
                value.kind_value != .https)
            {
                return error.CorruptState;
            }
            const origin = value.allowed_origin orelse return error.CorruptState;
            const seal = valueSeal(relative, value.kind_value, value.provenance, origin);
            if (value.seal != seal) {
                return error.CorruptState;
            }
            const bytes_value = try relative.slice(value);
            if (value.content_seal != contentSeal(seal, bytes_value)) {
                return error.CorruptState;
            }
            return bytes_value;
        }
        if (value.provenance != .literal or value.allowed_origin != null or value.seal != 0 or
            value.content_seal != 0)
        {
            return error.CorruptState;
        }
        return value.bytes_value.borrowed;
    }
};

pub const AccessError = syntax.ValidationError || error{
    CorruptState,
    NotInitialized,
    OriginNotAllowed,
};

fn asResource(value: *const Value) *const TrustedResourceUrl {
    return @ptrCast(value);
}

fn resourceValue(resource: *const TrustedResourceUrl) *const Value {
    return @ptrCast(@alignCast(resource));
}

pub const ResourceIssue = union(enum) {
    invalid_url: syntax.ValidationError,
    too_long,
    origin_not_allowed,
};

pub fn ResourceTable(
    comptime Resource: type,
    comptime origins: []const []const u8,
    comptime url_bytes_max: u32,
) type {
    const enum_info = validateTable(Resource, origins, url_bytes_max);
    const resource_count = enum_info.fields.len;
    const Length = std.math.IntFittingRange(0, url_bytes_max);
    return struct {
        storage: [resource_count][url_bytes_max]u8,
        lengths: [resource_count]Length,
        values: [resource_count]Value,
        initialized: bool,

        pub const Configuration = [resource_count][]const u8;
        pub const resource_type = Resource;
        pub const resource_count_maximum = resource_count;
        pub const url_bytes_maximum = url_bytes_max;
        const Self = @This();

        comptime {
            std.debug.assert(@sizeOf(Self) <= relative_offset_hard_max);
        }

        pub const Failure = struct {
            resource: Resource,
            issue: ResourceIssue,

            pub fn name(failure: Failure) []const u8 {
                return @tagName(failure.resource);
            }
        };

        pub fn init(table: *Self, configuration: *const Configuration) ?Failure {
            table.* = .{
                .storage = [_][url_bytes_max]u8{
                    [_]u8{0} ** url_bytes_max,
                } ** resource_count,
                .lengths = [_]Length{0} ** resource_count,
                .values = [_]Value{empty_value} ** resource_count,
                .initialized = false,
            };
            inline for (enum_info.fields, 0..) |field, index| {
                const input = configuration[index];
                if (input.len > url_bytes_max) {
                    table.clear();
                    return failureFor(field, .too_long);
                }
                const parsed = syntax.parseWeb(input, url_bytes_max) catch |problem| {
                    table.clear();
                    return failureFor(field, .{ .invalid_url = problem });
                };
                if (parsed.scheme != .https) {
                    table.clear();
                    return failureFor(field, .{ .invalid_url = error.UnsupportedScheme });
                }
                const allowed_origin = allowedOrigin(parsed, origins) orelse {
                    table.clear();
                    return failureFor(field, .origin_not_allowed);
                };
                @memcpy(table.storage[index][0..input.len], input);
                table.lengths[index] = @intCast(input.len);
                const relative = RelativeBytes{
                    .offset = relativeOffset(&table.values[index], &table.storage[index]),
                    .length = @intCast(input.len),
                    .capacity = url_bytes_max,
                };
                const seal = valueSeal(relative, .https, .startup_table, allowed_origin);
                table.values[index] = .{
                    .bytes_value = .{ .relative = relative },
                    .kind_value = .https,
                    .provenance = .startup_table,
                    .allowed_origin = allowed_origin,
                    .seal = seal,
                    .content_seal = contentSeal(
                        seal,
                        table.storage[index][0..input.len],
                    ),
                };
            }
            table.initialized = true;
            return null;
        }

        pub fn get(
            table: *const Self,
            comptime resource: Resource,
        ) AccessError!*const TrustedResourceUrl {
            if (!table.initialized) return error.NotInitialized;
            const index = comptime enumIndex(enum_info, resource);
            const length: u32 = @intCast(table.lengths[index]);
            if (length == 0 or length > url_bytes_max) return error.CorruptState;
            const value = &table.values[index];
            const relative = value.bytes_value.relative orelse return error.CorruptState;
            if (relative.offset != relativeOffset(value, &table.storage[index]) or
                relative.length != length or relative.capacity != url_bytes_max)
            {
                return error.CorruptState;
            }
            const result = asResource(value);
            _ = try result.validatedBytes();
            const origin = value.allowed_origin orelse return error.CorruptState;
            if (!configuredOrigin(origin, origins)) return error.CorruptState;
            return result;
        }

        pub fn clear(table: *Self) void {
            @memset(std.mem.asBytes(&table.storage), 0);
            @memset(std.mem.asBytes(&table.lengths), 0);
            @memset(&table.values, empty_value);
            table.initialized = false;
        }

        fn failureFor(comptime field: std.builtin.Type.EnumField, issue: ResourceIssue) Failure {
            return .{
                .resource = @enumFromInt(field.value),
                .issue = issue,
            };
        }
    };
}

const empty_value = Value{
    .bytes_value = .{},
    .kind_value = .local,
    .provenance = .literal,
    .allowed_origin = null,
    .seal = 0,
    .content_seal = 0,
};

fn relativeOffset(value: *const Value, storage: *const anyopaque) i32 {
    const value_address = @intFromPtr(value);
    const storage_address = @intFromPtr(storage);
    if (storage_address >= value_address) {
        const distance = storage_address - value_address;
        std.debug.assert(distance <= relative_offset_hard_max);
        return @intCast(distance);
    }
    const distance = value_address - storage_address;
    std.debug.assert(distance <= relative_offset_hard_max);
    return -@as(i32, @intCast(distance));
}

fn offsetMagnitude(offset: i32) ?usize {
    if (offset == std.math.minInt(i32)) return null;
    return @intCast(if (offset < 0) -offset else offset);
}

fn valueSeal(
    relative: RelativeBytes,
    kind: TrustedResourceUrl.Kind,
    provenance: TrustedResourceUrl.Provenance,
    origin: []const u8,
) u64 {
    const fields = [_]u64{
        @as(u32, @bitCast(relative.offset)),
        relative.length,
        relative.capacity,
        (@as(u64, @intFromEnum(kind)) << 8) | @intFromEnum(provenance),
    };
    const field_hash = std.hash.Wyhash.hash(value_seal_seed, std.mem.asBytes(&fields));
    return std.hash.Wyhash.hash(field_hash, origin);
}

fn contentSeal(metadata_seal: u64, bytes_value: []const u8) u64 {
    return std.hash.Wyhash.hash(metadata_seal ^ value_seal_seed, bytes_value);
}

fn validateValue(value: *const Value, bytes_value: []const u8) AccessError!void {
    switch (value.kind_value) {
        .local => {
            if (bytes_value.len == 0 or bytes_value[0] != '/') {
                return error.InvalidLocalReference;
            }
            try syntax.validateLocal(bytes_value, syntax.url_bytes_hard_max);
        },
        .https => {
            const parsed = try syntax.parseWeb(bytes_value, syntax.url_bytes_hard_max);
            if (parsed.scheme != .https) return error.UnsupportedScheme;
            if (value.allowed_origin) |origin| {
                const allowed = syntax.validateOrigin(origin) catch return error.CorruptState;
                if (!parsed.sameOrigin(allowed)) return error.OriginNotAllowed;
            }
        },
    }
}

fn validateTable(
    comptime Resource: type,
    comptime origins: []const []const u8,
    comptime url_bytes_max: u32,
) std.builtin.Type.Enum {
    @setEvalBranchQuota(100_000);
    const type_info = @typeInfo(Resource);
    if (type_info != .@"enum") {
        @compileError("PLOOF-E3712 trusted resource table key must be an enum");
    }
    const enum_info = type_info.@"enum";
    if (!enum_info.is_exhaustive or enum_info.fields.len == 0 or enum_info.fields.len > 256) {
        @compileError("PLOOF-E3713 trusted resource table must have 1 to 256 exhaustive keys");
    }
    if (url_bytes_max == 0 or url_bytes_max > syntax.url_bytes_hard_max) {
        @compileError("PLOOF-E3714 trusted resource table URL limit must be 1 to 65536 bytes");
    }
    if (origins.len == 0 or origins.len > 64) {
        @compileError("PLOOF-E3715 trusted resource origin allowlist must contain 1 to 64 origins");
    }
    for (origins, 0..) |origin, index| {
        _ = syntax.validateOrigin(origin) catch |problem| {
            @compileError(
                "PLOOF-E3716 invalid trusted resource origin at index " ++
                    std.fmt.comptimePrint("{d}: {s}", .{ index, @errorName(problem) }),
            );
        };
    }
    return enum_info;
}

fn allowedOrigin(
    parsed: syntax.ParsedWeb,
    comptime origins: []const []const u8,
) ?[]const u8 {
    inline for (origins) |origin| {
        const allowed = syntax.validateOrigin(origin) catch unreachable;
        if (parsed.sameOrigin(allowed)) return origin;
    }
    return null;
}

fn configuredOrigin(origin: []const u8, comptime origins: []const []const u8) bool {
    inline for (origins) |configured| {
        if (std.mem.eql(u8, origin, configured)) return true;
    }
    return false;
}

fn enumIndex(comptime info: std.builtin.Type.Enum, comptime resource: anytype) usize {
    inline for (info.fields, 0..) |field, index| {
        if (field.value == @intFromEnum(resource)) return index;
    }
    unreachable;
}
