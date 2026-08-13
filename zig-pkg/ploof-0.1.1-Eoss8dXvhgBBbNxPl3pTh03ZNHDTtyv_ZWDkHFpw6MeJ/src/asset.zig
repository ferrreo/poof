const std = @import("std");
const bundle = @import("internal/asset/bundle.zig");
const syntax = @import("internal/url/syntax.zig");

pub const MediaKind = bundle.MediaKind;
pub const format_version = bundle.format_version;
pub const assets_hard_max = bundle.assets_hard_max;
pub const origin_bytes_hard_max: u16 = 4096;
pub const origin_prefix_bytes_hard_max: u16 = 1024;
const relative_offset_hard_max: u32 = 32 * 1024 * 1024;
const reference_seal_seed: u64 = 0x6173_7365_745f_7265;
const origin_seal_seed: u64 = 0x6173_7365_745f_6f72;
const AssetRefBrand = opaque {};

pub const AccessError = error{
    CorruptState,
    NotInitialized,
};

pub const UrlParts = struct {
    base: []const u8,
    path: []const u8,

    pub fn encodedLength(parts: UrlParts) usize {
        return parts.base.len + parts.path.len;
    }
};

pub const OriginConfiguration = struct {
    origin: []const u8,
    prefix: []const u8 = "",
};

pub const OriginIssue = union(enum) {
    invalid_origin: syntax.ValidationError,
    origin_too_long,
    origin_not_allowed,
    prefix_too_long,
    invalid_prefix,
};

pub const OriginFailure = struct {
    issue: OriginIssue,
};

pub const OriginLimits = struct {
    origin_bytes_max: u16 = 512,
    prefix_bytes_max: u16 = 128,

    pub fn validate(comptime limits: OriginLimits) OriginLimits {
        if (limits.origin_bytes_max == 0 or
            limits.origin_bytes_max > origin_bytes_hard_max or
            limits.prefix_bytes_max > origin_prefix_bytes_hard_max)
        {
            @compileError("PLOOF-E5113 invalid embedded asset origin limits");
        }
        return limits;
    }
};

pub const standard_origin_limits = OriginLimits.validate(.{});

pub const AssetOrigin = opaque {
    pub const ploof_template_helper_capability = true;

    pub fn base(origin: *const AssetOrigin) AccessError![]const u8 {
        return checkedOrigin(originValue(origin));
    }
};

pub fn AssetRef(comptime requested_kind: MediaKind) type {
    return opaque {
        pub const ploof_asset_ref_brand = AssetRefBrand;
        pub const media_kind = requested_kind;

        pub fn url(reference: *const @This()) AccessError!UrlParts {
            const value = try checkedReference(referenceValue(reference), media_kind);
            const base = if (value.origin_offset == 0)
                ""
            else
                try checkedOrigin(linkedOrigin(value));
            return .{ .base = base, .path = value.path };
        }

        pub fn canonicalPath(reference: *const @This()) AccessError![]const u8 {
            return (try checkedReference(referenceValue(reference), media_kind)).path;
        }

        pub fn identityBytes(reference: *const @This()) AccessError![]const u8 {
            return (try checkedReference(referenceValue(reference), media_kind)).identity;
        }

        pub fn identityDigest(reference: *const @This()) AccessError![32]u8 {
            return (try checkedReference(referenceValue(reference), media_kind)).digest;
        }
    };
}

pub fn isAssetRef(comptime Candidate: type) bool {
    const Base = switch (@typeInfo(Candidate)) {
        .pointer => |pointer| if (pointer.size == .one and pointer.is_const)
            pointer.child
        else
            return false,
        else => Candidate,
    };
    if (@typeInfo(Base) != .@"opaque" or !@hasDecl(Base, "ploof_asset_ref_brand") or
        !@hasDecl(Base, "media_kind"))
    {
        return false;
    }
    const kind = @field(Base, "media_kind");
    if (@TypeOf(kind) != MediaKind) return false;
    return Base == AssetRef(kind);
}

pub fn referenceKind(comptime Candidate: type) ?MediaKind {
    if (!isAssetRef(Candidate)) return null;
    const Base = switch (@typeInfo(Candidate)) {
        .pointer => |pointer| pointer.child,
        else => Candidate,
    };
    return @field(Base, "media_kind");
}

pub fn mediaType(kind: MediaKind) []const u8 {
    return bundle.mediaType(kind);
}

pub fn Bundle(comptime Generated: type) type {
    const AssetPlan = bundle.Plan(Generated);
    return struct {
        pub const ploof_asset_bundle = true;
        pub const generated = AssetPlan.Module;
        pub const route_prefix = AssetPlan.route_prefix;
        pub const asset_count = AssetPlan.asset_count;

        pub fn kind(comptime logical_name: []const u8) MediaKind {
            return AssetPlan.kindOf(logical_name);
        }

        pub fn local(
            comptime logical_name: []const u8,
        ) *const AssetRef(AssetPlan.kindOf(logical_name)) {
            const index = comptime AssetPlan.indexOf(logical_name);
            const ref_kind = comptime AssetPlan.kindAt(index);
            const record = AssetPlan.Module.assets[index];
            const Holder = struct {
                const value = makeReference(
                    record.path,
                    record.identity.bytes,
                    record.identity.digest,
                    ref_kind,
                    0,
                );
            };
            return asReference(ref_kind, &Holder.value);
        }

        pub fn References(
            comptime allowed_origins: []const []const u8,
            comptime requested_limits: OriginLimits,
        ) type {
            const limits = comptime requested_limits.validate();
            validateOrigins(allowed_origins, limits);
            const base_capacity = limits.origin_bytes_max + limits.prefix_bytes_max;

            return struct {
                origin_storage: [base_capacity]u8,
                origin_value: OriginValue,
                values: [AssetPlan.asset_count]ReferenceValue,
                initialized: bool,

                pub const origin_limits = limits;
                pub const reference_count = AssetPlan.asset_count;
                pub const ploof_template_helper_capability = true;
                const Self = @This();

                comptime {
                    if (@sizeOf(Self) > relative_offset_hard_max) {
                        @compileError("PLOOF-E5115 embedded asset reference table exceeds 32 MiB");
                    }
                }

                pub fn init(
                    table: *Self,
                    configuration: ?OriginConfiguration,
                ) ?OriginFailure {
                    table.reset();
                    if (configuration) |configured| {
                        const failure = table.initExternal(configured);
                        if (failure) |problem| return problem;
                    }
                    table.initReferences();
                    table.initialized = true;
                    return null;
                }

                pub fn get(
                    table: *const Self,
                    comptime logical_name: []const u8,
                ) AccessError!*const AssetRef(AssetPlan.kindOf(logical_name)) {
                    if (!table.initialized) return error.NotInitialized;
                    const index = comptime AssetPlan.indexOf(logical_name);
                    const ref_kind = comptime AssetPlan.kindAt(index);
                    const value = &table.values[index];
                    const expected_offset = relativeOffset(value, &table.origin_value);
                    if (value.origin_offset != expected_offset) return error.CorruptState;
                    _ = try checkedReference(value, ref_kind);
                    return asReference(ref_kind, value);
                }

                pub fn origin(table: *const Self) AccessError!?*const AssetOrigin {
                    if (!table.initialized) return error.NotInitialized;
                    const base = try checkedOrigin(&table.origin_value);
                    if (base.len == 0) return null;
                    return asOrigin(&table.origin_value);
                }

                pub fn clear(table: *Self) void {
                    table.reset();
                }

                fn initExternal(
                    table: *Self,
                    configured: OriginConfiguration,
                ) ?OriginFailure {
                    if (configured.origin.len > limits.origin_bytes_max) {
                        return .{ .issue = .origin_too_long };
                    }
                    const parsed = syntax.validateOrigin(configured.origin) catch |problem| {
                        return .{ .issue = .{ .invalid_origin = problem } };
                    };
                    const allowed = allowedOrigin(parsed, allowed_origins) orelse {
                        return .{ .issue = .origin_not_allowed };
                    };
                    if (configured.prefix.len > limits.prefix_bytes_max) {
                        return .{ .issue = .prefix_too_long };
                    }
                    if (!validOriginPrefix(configured.prefix)) {
                        return .{ .issue = .invalid_prefix };
                    }
                    const length = allowed.len + configured.prefix.len;
                    std.debug.assert(length <= base_capacity);
                    @memcpy(table.origin_storage[0..allowed.len], allowed);
                    @memcpy(table.origin_storage[allowed.len..length], configured.prefix);
                    const relative = RelativeBytes{
                        .offset = relativeOffset(&table.origin_value, &table.origin_storage),
                        .length = @intCast(length),
                        .capacity = base_capacity,
                    };
                    const bytes = table.origin_storage[0..length];
                    const seal = originSeal(relative);
                    table.origin_value = .{
                        .relative = relative,
                        .seal = seal,
                        .content_seal = std.hash.Wyhash.hash(seal, bytes),
                    };
                    return null;
                }

                fn initReferences(table: *Self) void {
                    inline for (AssetPlan.Module.assets, 0..) |record, index| {
                        const ref_kind = comptime AssetPlan.kindAt(index);
                        const value = &table.values[index];
                        value.* = makeReference(
                            record.path,
                            record.identity.bytes,
                            record.identity.digest,
                            ref_kind,
                            relativeOffset(value, &table.origin_value),
                        );
                    }
                }

                fn reset(table: *Self) void {
                    table.* = .{
                        .origin_storage = [_]u8{0} ** base_capacity,
                        .origin_value = empty_origin,
                        .values = [_]ReferenceValue{empty_reference} ** AssetPlan.asset_count,
                        .initialized = false,
                    };
                }
            };
        }
    };
}

const RelativeBytes = struct {
    offset: i32,
    length: u16,
    capacity: u16,
};

const OriginValue = struct {
    relative: ?RelativeBytes,
    seal: u64,
    content_seal: u64,
};

const ReferenceValue = struct {
    path: []const u8,
    identity: []const u8,
    digest: [32]u8,
    kind: MediaKind,
    origin_offset: i32,
    seal: u64,
};

fn makeReference(
    path: []const u8,
    identity: []const u8,
    digest: [32]u8,
    kind: MediaKind,
    origin_offset: i32,
) ReferenceValue {
    var value = ReferenceValue{
        .path = path,
        .identity = identity,
        .digest = digest,
        .kind = kind,
        .origin_offset = origin_offset,
        .seal = 0,
    };
    value.seal = referenceSeal(&value);
    return value;
}

fn checkedReference(
    value: *const ReferenceValue,
    kind: MediaKind,
) AccessError!*const ReferenceValue {
    if (value.kind != kind or value.path.len == 0 or value.path[0] != '/' or
        value.seal != referenceSeal(value))
    {
        return error.CorruptState;
    }
    return value;
}

fn referenceSeal(value: *const ReferenceValue) u64 {
    const fields = [_]u64{
        value.path.len,
        value.identity.len,
        @intFromEnum(value.kind),
        @as(u32, @bitCast(value.origin_offset)),
        digestWord(value.digest[0..8]),
        digestWord(value.digest[24..32]),
    };
    return std.hash.Wyhash.hash(reference_seal_seed, std.mem.asBytes(&fields));
}

fn digestWord(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    var result: u64 = 0;
    for (bytes, 0..) |byte, shift| result |= @as(u64, byte) << @intCast(shift * 8);
    return result;
}

fn checkedOrigin(value: *const OriginValue) AccessError![]const u8 {
    const relative = value.relative orelse {
        if (value.seal != 0 or value.content_seal != 0) return error.CorruptState;
        return "";
    };
    if (relative.length == 0 or relative.length > relative.capacity or
        value.seal != originSeal(relative))
    {
        return error.CorruptState;
    }
    const bytes = try relativeSlice(relative, value);
    if (value.content_seal != std.hash.Wyhash.hash(value.seal, bytes)) {
        return error.CorruptState;
    }
    return bytes;
}

fn originSeal(relative: RelativeBytes) u64 {
    const fields = [_]u64{
        @as(u32, @bitCast(relative.offset)),
        relative.length,
        relative.capacity,
    };
    return std.hash.Wyhash.hash(origin_seal_seed, std.mem.asBytes(&fields));
}

fn relativeSlice(relative: RelativeBytes, value: *const OriginValue) AccessError![]const u8 {
    const address = addOffset(@intFromPtr(value), relative.offset) orelse {
        return error.CorruptState;
    };
    const pointer: [*]const u8 = @ptrFromInt(address);
    return pointer[0..relative.length];
}

fn linkedOrigin(value: *const ReferenceValue) *const OriginValue {
    std.debug.assert(value.origin_offset != 0);
    const address = addOffset(@intFromPtr(value), value.origin_offset) orelse unreachable;
    return @ptrFromInt(address);
}

fn addOffset(address: usize, offset: i32) ?usize {
    if (offset == std.math.minInt(i32)) return null;
    if (offset < 0) return std.math.sub(usize, address, @intCast(-offset)) catch null;
    return std.math.add(usize, address, @intCast(offset)) catch null;
}

fn relativeOffset(from: *const anyopaque, to: *const anyopaque) i32 {
    const from_address = @intFromPtr(from);
    const to_address = @intFromPtr(to);
    if (to_address >= from_address) {
        const distance = to_address - from_address;
        std.debug.assert(distance <= relative_offset_hard_max);
        return @intCast(distance);
    }
    const distance = from_address - to_address;
    std.debug.assert(distance <= relative_offset_hard_max);
    return -@as(i32, @intCast(distance));
}

fn validateOrigins(
    comptime origins: []const []const u8,
    comptime limits: OriginLimits,
) void {
    if (origins.len > 64) {
        @compileError("PLOOF-E5114 embedded asset origin allowlist exceeds 64 entries");
    }
    for (origins, 0..) |origin, index| {
        if (origin.len > limits.origin_bytes_max) {
            @compileError("PLOOF-E5114 embedded asset origin exceeds configured limit");
        }
        const parsed = syntax.validateOrigin(origin) catch |problem| {
            @compileError(
                "PLOOF-E5114 invalid embedded asset origin at index " ++
                    std.fmt.comptimePrint("{d}: {s}", .{ index, @errorName(problem) }),
            );
        };
        for (origins[0..index]) |previous| {
            const previous_parsed = syntax.validateOrigin(previous) catch unreachable;
            if (parsed.sameOrigin(previous_parsed)) {
                @compileError("PLOOF-E5114 duplicate embedded asset origin");
            }
        }
    }
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

fn validOriginPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix[0] != '/' or prefix[prefix.len - 1] == '/') return false;
    var segment_bytes: u16 = 0;
    for (prefix[1..]) |byte| {
        if (byte == '/') {
            if (segment_bytes == 0) return false;
            segment_bytes = 0;
        } else if ((byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '-' or byte == '_')
        {
            segment_bytes += 1;
        } else return false;
    }
    return segment_bytes != 0;
}

fn asReference(
    comptime kind: MediaKind,
    value: *const ReferenceValue,
) *const AssetRef(kind) {
    return @ptrCast(value);
}

fn referenceValue(reference: *const anyopaque) *const ReferenceValue {
    return @ptrCast(@alignCast(reference));
}

fn asOrigin(value: *const OriginValue) *const AssetOrigin {
    return @ptrCast(value);
}

fn originValue(origin: *const AssetOrigin) *const OriginValue {
    return @ptrCast(@alignCast(origin));
}

const empty_origin = OriginValue{
    .relative = null,
    .seal = 0,
    .content_seal = 0,
};

const empty_reference = ReferenceValue{
    .path = "",
    .identity = "",
    .digest = @splat(0),
    .kind = .binary,
    .origin_offset = 0,
    .seal = 0,
};

comptime {
    std.debug.assert(origin_bytes_hard_max + origin_prefix_bytes_hard_max <=
        std.math.maxInt(u16));
}
