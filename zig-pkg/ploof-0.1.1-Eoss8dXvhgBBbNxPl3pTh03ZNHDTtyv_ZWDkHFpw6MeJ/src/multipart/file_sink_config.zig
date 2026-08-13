const std = @import("std");
const multipart_upload = @import("upload.zig");
const upload_io = @import("../upload_io.zig");

pub const FileDurability = enum(u8) {
    buffered,
    crash_durable,
};

pub const FileStagingMode = union(enum) {
    anonymous_required,
    /// The staging directory must remain service-owned and inaccessible to
    /// untrusted writers until publication completes. Prefer anonymous staging.
    named_staging: []const u8,
};

pub const FileStagingKind = enum(u8) {
    anonymous_required,
    named_staging,
};

pub const FileSinkReport = struct {
    staging: FileStagingKind,
    durability: FileDurability,
    live_anonymous: u32,
    live_named: u32,
};

pub const FileSinkConfig = struct {
    root: []const u8,
    storage_key_bytes_max: usize = 256,
    durability: ?FileDurability = null,
    staging: FileStagingMode = .anonymous_required,
    mode: u16 = 0o600,
};

pub const root_bytes_hard_max: usize = 4095;
pub const storage_key_bytes_hard_max: usize = 4095;

pub const ConfigIssue = enum(u8) {
    durability_required,
    root_empty,
    root_invalid_utf8,
    root_control_character,
    root_above_hard_max,
    storage_key_max_zero,
    storage_key_max_address_space,
    storage_key_max_hard_limit,
    named_staging_invalid,
    mode_invalid,

    pub fn diagnostic(issue: ConfigIssue) []const u8 {
        return switch (issue) {
            .durability_required => "PLOOF-E3510 FileSink durability must be explicit",
            .root_empty => "PLOOF-E3511 FileSink root must be nonempty",
            .root_invalid_utf8 => "PLOOF-E3512 FileSink root must be valid UTF-8",
            .root_control_character => {
                return "PLOOF-E3513 FileSink root must not contain C0 or C1 controls";
            },
            .root_above_hard_max => {
                return "PLOOF-E3531 FileSink root exceeds 4095 bytes";
            },
            .storage_key_max_zero => {
                return "PLOOF-E3514 FileSink storage-key byte maximum must be nonzero";
            },
            .storage_key_max_address_space => {
                return "PLOOF-E3515 FileSink storage-key byte maximum exceeds address space";
            },
            .named_staging_invalid => {
                return "PLOOF-E3516 FileSink named staging must be a valid relative path";
            },
            .mode_invalid => "PLOOF-E3517 FileSink mode must be between 0001 and 0777",
            .storage_key_max_hard_limit => {
                return "PLOOF-E3518 FileSink storage-key byte maximum exceeds 4095";
            },
        };
    }
};

pub fn configIssue(config: FileSinkConfig) ?ConfigIssue {
    if (config.root.len == 0) return .root_empty;
    if (config.root.len > root_bytes_hard_max) return .root_above_hard_max;
    const root = std.unicode.Utf8View.init(config.root) catch {
        return .root_invalid_utf8;
    };
    var codepoints = root.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (controlCodepoint(codepoint)) return .root_control_character;
    }
    if (config.storage_key_bytes_max == 0) return .storage_key_max_zero;
    if (config.storage_key_bytes_max == std.math.maxInt(usize)) {
        return .storage_key_max_address_space;
    }
    if (config.storage_key_bytes_max > storage_key_bytes_hard_max) {
        return .storage_key_max_hard_limit;
    }
    if (config.durability == null) return .durability_required;
    switch (config.staging) {
        .anonymous_required => {},
        .named_staging => |path| {
            if (path.len > storage_key_bytes_hard_max or !validStoragePath(path)) {
                return .named_staging_invalid;
            }
        },
    }
    if (config.mode == 0 or config.mode > 0o777) return .mode_invalid;
    return null;
}

pub fn validateConfig(comptime config: FileSinkConfig) void {
    if (configIssue(config)) |issue| @compileError(issue.diagnostic());
}

pub const FileIoError = error{
    Canceled,
    AlreadyExists,
    NotFound,
    InvalidPath,
    CrossDevice,
    ReadOnly,
    QuotaExceeded,
    FileTooLarge,
    NoSpace,
    PermissionDenied,
    ResourceExhausted,
    InvalidResource,
    Unsupported,
    IoFailure,
};

pub fn mapIoError(failure: upload_io.IoError) FileIoError {
    return switch (failure) {
        .canceled => error.Canceled,
        .already_exists => error.AlreadyExists,
        .not_found => error.NotFound,
        .invalid_path => error.InvalidPath,
        .cross_device => error.CrossDevice,
        .read_only => error.ReadOnly,
        .quota_exceeded => error.QuotaExceeded,
        .file_too_large => error.FileTooLarge,
        .no_space => error.NoSpace,
        .permission_denied => error.PermissionDenied,
        .resource_exhausted => error.ResourceExhausted,
        .invalid_resource => error.InvalidResource,
        .unsupported => error.Unsupported,
        .io_failure => error.IoFailure,
    };
}

pub const stage_name_prefix = ".ploof-upload-v1-";
pub const probe_stage_name_prefix = ".ploof-probe-stage-v1-";
pub const probe_final_name_prefix = ".ploof-probe-final-v1-";
pub const random_name_bytes: usize = 16;
pub const random_name_hex_bytes: usize = random_name_bytes * 2;
pub const name_bytes_max: usize = probe_stage_name_prefix.len + random_name_hex_bytes;

pub const NameKind = enum(u8) {
    stage,
    probe_stage,
    probe_final,

    pub fn prefix(kind: NameKind) []const u8 {
        return switch (kind) {
            .stage => stage_name_prefix,
            .probe_stage => probe_stage_name_prefix,
            .probe_final => probe_final_name_prefix,
        };
    }
};

pub const Name = struct {
    storage: [name_bytes_max + 1]u8,
    length: u8,

    pub const empty = Name{
        .storage = [_]u8{0} ** (name_bytes_max + 1),
        .length = 0,
    };

    pub fn bytes(name: *const Name) []const u8 {
        return name.storage[0..name.length];
    }

    pub fn sentinel(name: *const Name) [:0]const u8 {
        return name.storage[0..name.length :0];
    }

    fn init(kind: NameKind, random: [random_name_bytes]u8) Name {
        const prefix = kind.prefix();
        const encoded = std.fmt.bytesToHex(random, .lower);
        const length = prefix.len + encoded.len;
        var name = Name.empty;
        @memcpy(name.storage[0..prefix.len], prefix);
        @memcpy(name.storage[prefix.len..length], &encoded);
        name.length = @intCast(length);
        return name;
    }
};

pub const NameError = error{NameSequenceExhausted};

pub fn Resolved(comptime supplied: FileSinkConfig) type {
    validateConfig(supplied);
    const root_path = Sentinel(supplied.root).value;
    const staging_path: ?[:0]const u8 = switch (supplied.staging) {
        .anonymous_required => null,
        .named_staging => |path| Sentinel(path).value,
    };
    const is_named = supplied.staging == .named_staging;
    const is_durable = supplied.durability.? == .crash_durable;
    const staging_kind: FileStagingKind = if (is_named)
        .named_staging
    else
        .anonymous_required;

    return struct {
        pub const config = supplied;
        pub const root_z: [:0]const u8 = root_path;
        pub const staging_z: ?[:0]const u8 = staging_path;
        pub const named: bool = is_named;
        pub const durable: bool = is_durable;
        pub const startup_report = FileSinkReport{
            .staging = staging_kind,
            .durability = supplied.durability.?,
            .live_anonymous = 0,
            .live_named = 0,
        };
        pub const io_requirements = requirementsFor(named, durable);
        pub const request_handles_max: u8 = 2;
        pub const runtime_handles_max: u8 = if (named) 3 else 2;
        pub const Key = multipart_upload.StorageKey(config.storage_key_bytes_max);
        pub const NameGenerator = NameGeneratorType(config);
    };
}

pub fn requirementsFor(named: bool, durable: bool) upload_io.IoRequirements {
    var requirements = upload_io.IoRequirements{
        .open = true,
        .write = true,
        .close = true,
        .unlink = true,
    };
    requirements.link = !named;
    requirements.rename_no_replace = named;
    requirements.sync = durable;
    return requirements;
}

fn NameGeneratorType(comptime config: FileSinkConfig) type {
    return struct {
        const Self = @This();

        key: [std.crypto.hash.Blake3.key_length]u8,
        counter: u64,

        pub fn init(entropy: *const [32]u8, worker_index: u16) Self {
            return .{
                .key = deriveGeneratorKey(config, entropy, worker_index),
                .counter = 0,
            };
        }

        pub fn next(generator: *Self, kind: NameKind) NameError!Name {
            if (generator.counter == std.math.maxInt(u64)) {
                return error.NameSequenceExhausted;
            }
            var hasher = std.crypto.hash.Blake3.init(.{ .key = generator.key });
            defer secureZeroOne(std.crypto.hash.Blake3, &hasher);
            hasher.update(name_domain);
            hasher.update(&.{@intFromEnum(kind)});
            updateU64(&hasher, generator.counter);
            generator.counter += 1;
            var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            defer std.crypto.secureZero(u8, &digest);
            hasher.final(&digest);
            return Name.init(kind, digest[0..random_name_bytes].*);
        }

        pub fn deinit(generator: *Self) void {
            secureZeroOne(Self, generator);
        }
    };
}

const generator_domain = "ploof/filesink/name-generator-key/v1";
const name_domain = "ploof/filesink/name/v1";

fn deriveGeneratorKey(
    comptime config: FileSinkConfig,
    entropy: *const [32]u8,
    worker_index: u16,
) [std.crypto.hash.Blake3.key_length]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{ .key = entropy.* });
    defer secureZeroOne(std.crypto.hash.Blake3, &hasher);
    hasher.update(generator_domain);
    updateSlice(&hasher, config.root);
    updateU64(&hasher, config.storage_key_bytes_max);
    hasher.update(&.{@intFromEnum(config.durability.?)});
    switch (config.staging) {
        .anonymous_required => hasher.update(&.{0}),
        .named_staging => |path| {
            hasher.update(&.{1});
            updateSlice(&hasher, path);
        },
    }
    updateU16(&hasher, config.mode);
    updateU16(&hasher, worker_index);
    var key: [std.crypto.hash.Blake3.key_length]u8 = undefined;
    hasher.final(&key);
    return key;
}

fn updateSlice(hasher: *std.crypto.hash.Blake3, value: []const u8) void {
    updateU64(hasher, value.len);
    hasher.update(value);
}

fn updateU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hasher.update(&encoded);
}

fn updateU16(hasher: *std.crypto.hash.Blake3, value: u16) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    hasher.update(&encoded);
}

fn secureZeroOne(comptime T: type, value: *T) void {
    std.crypto.secureZero(T, @as(*volatile T, value)[0..1]);
}

fn Sentinel(comptime bytes: []const u8) type {
    return struct {
        const storage = bytes[0..bytes.len].* ++ [_]u8{0};
        const value: [:0]const u8 = storage[0..bytes.len :0];
    };
}

fn validStoragePath(input: []const u8) bool {
    if (input.len == 0 or input[0] == '/') return false;
    const view = std.unicode.Utf8View.init(input) catch return false;
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (controlCodepoint(codepoint)) return false;
    }
    var components = std.mem.splitScalar(u8, input, '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return false;
        }
    }
    return true;
}

fn controlCodepoint(codepoint: u21) bool {
    return codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f);
}

comptime {
    std.debug.assert(stage_name_prefix.len < probe_stage_name_prefix.len);
    std.debug.assert(probe_stage_name_prefix.len == probe_final_name_prefix.len);
    std.debug.assert(name_bytes_max <= std.math.maxInt(u8));
}

test {
    std.testing.refAllDecls(@This());
}
