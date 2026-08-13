const std = @import("std");
const body = @import("body.zig");
const flat_schema = @import("internal/flat/schema.zig");
const syntax = @import("internal/http1/syntax.zig");
const file_sink = @import("multipart/file_sink.zig");
const file_sink_config = @import("multipart/file_sink_config.zig");
const upload = @import("multipart/upload.zig");
const upload_schema = @import("multipart/upload_schema.zig");

pub const TextDecodeError = flat_schema.TextDecodeError;
pub const Access = upload.Access;
pub const Create = upload.Create;
pub const FileHandle = upload.FileHandle;
pub const OpenBase = upload.OpenBase;
pub const IoCompletion = upload.IoCompletion;
pub const IoError = upload.IoError;
pub const IoKind = upload.IoKind;
pub const IoRequest = upload.IoRequest;
pub const IoRequirements = upload.IoRequirements;
pub const IoSuccess = upload.IoSuccess;
pub const OpenKind = upload.OpenKind;
pub const Poll = upload.Poll;
pub const PollEvent = upload.PollEvent;
pub const RequestIssue = upload.RequestIssue;
pub const Resolve = upload.Resolve;
pub const SinkIssue = upload.SinkIssue;
pub const SuccessIssue = upload.SuccessIssue;
pub const StorageKeyError = upload.StorageKeyError;
pub const WriteInput = upload.WriteInput;
pub const FinishInput = upload.FinishInput;
pub const RuntimeStartInput = upload.RuntimeStartInput;
pub const Decision = upload.Decision;
pub const FileDecision = upload.FileDecision;
pub const StorageKey = upload.StorageKey;
pub const FileDurability = file_sink_config.FileDurability;
pub const FileStagingKind = file_sink_config.FileStagingKind;
pub const FileStagingMode = file_sink_config.FileStagingMode;
pub const FileSinkConfig = file_sink_config.FileSinkConfig;
pub const FileSinkReport = file_sink_config.FileSinkReport;
pub const FileIoError = file_sink_config.FileIoError;
pub const FileSink = file_sink.FileSink;
pub const file_sink_root_bytes_hard_max = file_sink_config.root_bytes_hard_max;
pub const storage_key_bytes_hard_max = file_sink_config.storage_key_bytes_hard_max;
pub const commit = upload.commit;
pub const abort = upload.abort;
pub const sinkIssue = upload.sinkIssue;
pub const validateSink = upload.validateSink;
pub const sink_handles_hard_max = upload.sink_handles_hard_max;
pub const boundary_bytes_hard_max: u8 = 70;
pub const disposition_parameters_hard_max: u8 = 64;
pub const delimiter_transport_padding_bytes_hard_max: u16 = 1024;
pub const upload_chunk_bytes_hard_max = upload.upload_chunk_bytes_hard_max;
pub const multipart_file_routes_hard_max = upload.multipart_file_routes_hard_max;
pub const upload_window_hard_max = upload.upload_window_hard_max;
pub const csrf_field_bytes_max: usize = 128;

const disposition_hard_diagnostic =
    "PLOOF-E3411 multipart disposition parameter limit exceeds 64";
const padding_hard_diagnostic =
    "PLOOF-E3412 multipart delimiter transport padding limit exceeds 1024";
const ignored_above_total_diagnostic =
    "PLOOF-E3440 ignored multipart part limit exceeds total body limit";
const part_header_minimum_diagnostic =
    "PLOOF-E3404 multipart part-header bytes must be at least two";

pub const LimitIssue = enum(u8) {
    encoded_wire_bytes_zero,
    total_body_bytes_zero,
    parts_zero,
    part_headers_zero,
    part_header_bytes_below_minimum,
    disposition_parameters_zero,
    name_bytes_zero,
    boundary_bytes_zero,
    file_bytes_above_total,
    field_bytes_above_total,
    files_above_parts,
    disposition_parameters_above_hard_max,
    delimiter_transport_padding_above_hard_max,
    boundary_bytes_above_hard_max,

    pub fn diagnostic(problem: LimitIssue) []const u8 {
        return switch (problem) {
            .encoded_wire_bytes_zero => "PLOOF-E3400 multipart encoded wire limit must be nonzero",
            .total_body_bytes_zero => "PLOOF-E3401 multipart total body limit must be nonzero",
            .parts_zero => "PLOOF-E3402 multipart part limit must be nonzero",
            .part_headers_zero => "PLOOF-E3403 multipart part-header count must be nonzero",
            .part_header_bytes_below_minimum => part_header_minimum_diagnostic,
            .disposition_parameters_zero => "PLOOF-E3405 multipart disposition parameter " ++
                "limit must be nonzero",
            .name_bytes_zero => "PLOOF-E3406 multipart name byte limit must be nonzero",
            .boundary_bytes_zero => "PLOOF-E3407 multipart boundary byte limit must be nonzero",
            .file_bytes_above_total => "PLOOF-E3408 multipart file limit exceeds total body limit",
            .field_bytes_above_total => "PLOOF-E3409 multipart field limit exceeds " ++
                "total body limit",
            .files_above_parts => "PLOOF-E3410 multipart file count exceeds part count",
            .disposition_parameters_above_hard_max => disposition_hard_diagnostic,
            .delimiter_transport_padding_above_hard_max => padding_hard_diagnostic,
            .boundary_bytes_above_hard_max => "PLOOF-E3413 multipart boundary byte limit " ++
                "exceeds 70",
        };
    }
};

pub const Limits = struct {
    encoded_wire_bytes_max: u64 = 16 * 1024 * 1024,
    total_body_bytes_max: u64 = 16 * 1024 * 1024,
    file_bytes_max: u64 = 8 * 1024 * 1024,
    field_bytes_max: u64 = 64 * 1024,
    parts_max: u16 = 8,
    files_max: u16 = 4,
    part_headers_max: u16 = 16,
    part_header_bytes_max: u32 = 8 * 1024,
    disposition_parameters_max: u8 = 16,
    delimiter_transport_padding_bytes_max: u16 = 64,
    name_bytes_max: u16 = 128,
    filename_bytes_max: u16 = 255,
    boundary_bytes_max: u8 = boundary_bytes_hard_max,

    pub fn issue(limits: Limits) ?LimitIssue {
        if (limits.encoded_wire_bytes_max == 0) return .encoded_wire_bytes_zero;
        if (limits.total_body_bytes_max == 0) return .total_body_bytes_zero;
        if (limits.parts_max == 0) return .parts_zero;
        if (limits.part_headers_max == 0) return .part_headers_zero;
        if (limits.part_header_bytes_max < 2) return .part_header_bytes_below_minimum;
        if (limits.disposition_parameters_max == 0) return .disposition_parameters_zero;
        if (limits.name_bytes_max == 0) return .name_bytes_zero;
        if (limits.boundary_bytes_max == 0) return .boundary_bytes_zero;
        if (limits.file_bytes_max > limits.total_body_bytes_max) {
            return .file_bytes_above_total;
        }
        if (limits.field_bytes_max > limits.total_body_bytes_max) {
            return .field_bytes_above_total;
        }
        if (limits.files_max > limits.parts_max) return .files_above_parts;
        if (limits.disposition_parameters_max > disposition_parameters_hard_max) {
            return .disposition_parameters_above_hard_max;
        }
        if (limits.delimiter_transport_padding_bytes_max >
            delimiter_transport_padding_bytes_hard_max)
        {
            return .delimiter_transport_padding_above_hard_max;
        }
        if (limits.boundary_bytes_max > boundary_bytes_hard_max) {
            return .boundary_bytes_above_hard_max;
        }
        return null;
    }

    pub fn validate(comptime limits: Limits) Limits {
        if (limits.issue()) |problem| @compileError(problem.diagnostic());
        return limits;
    }
};

pub const standard_limits = Limits.validate(.{});

pub const UploadProfileIssue = enum(u8) {
    window_zero,
    window_above_hard_max,
    chunk_bytes_zero,
    chunk_bytes_above_hard_max,

    pub fn diagnostic(problem: UploadProfileIssue) []const u8 {
        return switch (problem) {
            .window_zero => "PLOOF-E3462 multipart upload window must be nonzero",
            .window_above_hard_max => "PLOOF-E3463 multipart upload window exceeds 16",
            .chunk_bytes_zero => "PLOOF-E3464 multipart upload chunk size must be nonzero",
            .chunk_bytes_above_hard_max => "PLOOF-E3465 multipart upload chunk size exceeds 1 MiB",
        };
    }
};

pub const UploadProfile = struct {
    window: u8 = 4,
    chunk_bytes: u32 = 16 * 1024,

    pub fn issue(profile: UploadProfile) ?UploadProfileIssue {
        if (profile.window == 0) return .window_zero;
        if (profile.window > upload_window_hard_max) return .window_above_hard_max;
        if (profile.chunk_bytes == 0) return .chunk_bytes_zero;
        if (profile.chunk_bytes > upload_chunk_bytes_hard_max) {
            return .chunk_bytes_above_hard_max;
        }
        return null;
    }

    pub fn validate(comptime profile: UploadProfile) UploadProfile {
        if (profile.issue()) |problem| @compileError(problem.diagnostic());
        return profile;
    }
};

pub const standard_upload_profile = UploadProfile.validate(.{});

pub const Cardinality = union(enum) {
    required,
    optional,
    zero_to: u16,
    one_to: u16,

    pub fn isRequired(value: Cardinality) bool {
        return switch (value) {
            .required, .one_to => true,
            .optional, .zero_to => false,
        };
    }

    pub fn maximum(value: Cardinality) u16 {
        return switch (value) {
            .required, .optional => 1,
            .zero_to, .one_to => |limit| limit,
        };
    }
};

pub const required: Cardinality = .required;
pub const optional: Cardinality = .optional;

pub fn zeroTo(comptime maximum: u16) Cardinality {
    return validateCardinality(.{ .zero_to = maximum });
}

pub fn oneTo(comptime maximum: u16) Cardinality {
    return validateCardinality(.{ .one_to = maximum });
}

pub const UnknownParts = union(enum) {
    reject,
    ignore_unknown: u64,
};

pub const reject_unknown: UnknownParts = .reject;

pub fn ignoreUnknown(comptime max_part_bytes: u64) UnknownParts {
    if (max_part_bytes == 0) {
        @compileError("PLOOF-E3420 ignored multipart part limit must be nonzero");
    }
    return .{ .ignore_unknown = max_part_bytes };
}

pub const ignore_unknown = ignoreUnknown;

pub const Options = struct {
    limits: Limits = standard_limits,
    unknown_parts: UnknownParts = reject_unknown,
    upload: UploadProfile = standard_upload_profile,
};

pub const PartKind = enum(u8) {
    field,
    bytes_field,
    file,
};

pub const FilenameSource = enum(u8) {
    filename,
    filename_star,
};

/// Request-scoped, untrusted display metadata. `bytes` is borrowed for the callback.
pub const ClientFilename = struct {
    bytes: []const u8,
    source: FilenameSource,
};

/// Parsed client claim. All slices are borrowed for the callback.
pub const ClaimedMediaType = struct {
    raw: []const u8,
    type: []const u8,
    subtype: []const u8,
};

pub const MissingMedia = enum(u8) {
    allow,
    reject,
};

pub const MediaClaim = struct {
    type: []const u8,
    subtype: []const u8,
};

pub const ClaimedMediaPolicy = struct {
    /// `null` accepts any syntactically valid claimed type; a slice is an exact list.
    exact: ?[]const MediaClaim,
    missing: MissingMedia,
};

pub const MediaPolicyIssue = enum(u8) {
    exact_list_empty,
    invalid_claim,
    claim_not_normalized,
    duplicate_claim,

    pub fn diagnostic(problem: MediaPolicyIssue) []const u8 {
        return switch (problem) {
            .exact_list_empty => "PLOOF-E3444 multipart claimed media list must not be empty",
            .invalid_claim => "PLOOF-E3445 invalid multipart claimed media type",
            .claim_not_normalized => "PLOOF-E3446 multipart claimed media type must be lowercase",
            .duplicate_claim => "PLOOF-E3447 duplicate multipart claimed media type",
        };
    }
};

pub fn anyClaimedMedia(comptime missing: MissingMedia) ClaimedMediaPolicy {
    return .{ .exact = null, .missing = missing };
}

pub fn claimedMediaTypes(
    comptime values: []const []const u8,
    comptime missing: MissingMedia,
) ClaimedMediaPolicy {
    const claims = &MediaClaims(values).values;
    const policy = ClaimedMediaPolicy{ .exact = claims, .missing = missing };
    if (comptime mediaPolicyIssue(policy)) |problem| @compileError(problem.diagnostic());
    return policy;
}

pub fn mediaPolicyIssue(policy: ClaimedMediaPolicy) ?MediaPolicyIssue {
    const claims = policy.exact orelse return null;
    if (claims.len == 0) return .exact_list_empty;
    for (claims, 0..) |claim, index| {
        if (!validClaimToken(claim.type) or !validClaimToken(claim.subtype)) {
            return .invalid_claim;
        }
        if (!normalizedClaimToken(claim.type) or !normalizedClaimToken(claim.subtype)) {
            return .claim_not_normalized;
        }
        for (claims[index + 1 ..]) |other| {
            if (std.mem.eql(u8, claim.type, other.type) and
                std.mem.eql(u8, claim.subtype, other.subtype)) return .duplicate_claim;
        }
    }
    return null;
}

/// Metadata borrowed only for synchronous file-start delivery.
pub const FileStart = struct {
    part_name: []const u8,
    occurrence: u16,
    client_filename: ?ClientFilename,
    claimed_media_type: ?ClaimedMediaType,
};

/// File bytes are borrowed only until synchronous chunk delivery returns.
pub const FileChunk = struct {
    bytes: []const u8,
    offset: u64,
};

/// Explicit zero-state sink for admitted files intentionally consumed and discarded.
pub const DiscardSink = upload.DiscardSink;

pub fn field(comptime T: type, comptime cardinality: Cardinality) Field(T, cardinality) {
    return .{};
}

pub fn bytesField(comptime cardinality: Cardinality) BytesField(cardinality) {
    return .{};
}

pub const bytes_field = bytesField;

pub fn file(
    comptime Sink: type,
    comptime cardinality: Cardinality,
) File(Sink, cardinality, anyClaimedMedia(.allow)) {
    return .{};
}

pub fn fileWithPolicy(
    comptime Sink: type,
    comptime cardinality: Cardinality,
    comptime media_policy: ClaimedMediaPolicy,
) File(Sink, cardinality, media_policy) {
    return .{};
}

pub fn isPartSpec(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_multipart_part") and T.ploof_multipart_part;
}

pub fn isCsrfField(comptime T: type) bool {
    return isPartSpec(T) and
        @hasDecl(T, "ploof_csrf_field") and T.ploof_csrf_field;
}

pub const SchemaIssue = enum(u8) {
    not_named_struct,
    empty,
    invalid_part,
    empty_name,
    invalid_name,
    name_too_long,
    parts_above_limit,
    files_above_limit,
    ignored_part_bytes_zero,
    ignored_part_bytes_above_total,

    pub fn diagnostic(problem: SchemaIssue) []const u8 {
        return switch (problem) {
            .not_named_struct => "PLOOF-E3430 multipart schema must be a named struct literal",
            .empty => "PLOOF-E3431 multipart schema must not be empty",
            .invalid_part => "PLOOF-E3432 invalid multipart schema part declaration",
            .empty_name => "PLOOF-E3433 multipart part name must be nonempty",
            .invalid_name => "PLOOF-E3434 multipart part name must be valid UTF-8 without controls",
            .name_too_long => "PLOOF-E3435 multipart part name exceeds route limit",
            .parts_above_limit => "PLOOF-E3437 multipart schema cardinality exceeds part limit",
            .files_above_limit => "PLOOF-E3438 multipart file cardinality exceeds file limit",
            .ignored_part_bytes_zero => "PLOOF-E3439 ignored multipart part limit must be nonzero",
            .ignored_part_bytes_above_total => ignored_above_total_diagnostic,
        };
    }
};

pub fn schemaIssue(comptime schema: anytype, options: Options) ?SchemaIssue {
    const info = @typeInfo(@TypeOf(schema));
    if (info != .@"struct" or info.@"struct".is_tuple) return .not_named_struct;
    const fields = info.@"struct".fields;
    if (fields.len == 0) return .empty;
    var part_total: u64 = 0;
    var file_total: u64 = 0;
    inline for (fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        if (comptime !isPartSpec(Part)) return .invalid_part;
        if (nameIssue(schema_field.name, options.limits.name_bytes_max)) |problem| {
            return problem;
        }
        part_total += Part.cardinality.maximum();
        if (Part.kind == .file) file_total += Part.cardinality.maximum();
    }
    if (part_total > options.limits.parts_max) return .parts_above_limit;
    if (file_total > options.limits.files_max) return .files_above_limit;
    return unknownPartsIssue(options.unknown_parts, options.limits.total_body_bytes_max);
}

/// Zero-size endpoint body marker; multipart values are delivered through push callbacks.
pub const PushInput = struct {};

/// Declares a streaming multipart body for the generic `ploof.Endpoint`.
/// Named schema fields are exact decoded part names; Zig rejects duplicate map keys.
pub fn decode(comptime schema: anytype, comptime requested: Options) Decoder(schema, requested) {
    return .{};
}

pub fn isSpec(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_multipart_push_decoder") and T.ploof_multipart_push_decoder;
}

fn Decoder(comptime schema: anytype, comptime requested: Options) type {
    const limits = comptime requested.limits.validate();
    const upload_profile = comptime requested.upload.validate();
    const options = Options{
        .limits = limits,
        .unknown_parts = requested.unknown_parts,
        .upload = upload_profile,
    };
    const problem = comptime schemaIssue(schema, options);
    if (problem) |value| @compileError(value.diagnostic());
    const FieldEvent = fieldEventType(schema);
    const FileTag = fileTagType(schema);
    const FileStartEvent = upload_schema.FileStartEvent(schema, FileTag, FileStart);
    const BeginEvent = upload_schema.BeginInput(schema, FileTag);
    const UploadSummaries = upload_schema.Summaries(schema);

    return struct {
        pub const ploof_body_decoder_spec = true;
        pub const ploof_multipart_push_decoder = true;
        pub const decoder_kind: body.DecoderKind = .multipart;
        pub const Target = PushInput;
        pub const configured_schema = schema;
        pub const resolved_options = options;
        pub const ploof_csrf_field_count = csrfFieldCount(schema);
        pub const ploof_csrf_field_name = csrfFieldName(schema);
        pub const ploof_csrf_field_index = csrfFieldIndex(schema);
        pub const encoded_wire_bytes_max = limits.encoded_wire_bytes_max;
        pub const decoded_bytes_max = limits.total_body_bytes_max;
        pub const accepted_media = [_]body.MediaPattern{
            .{ .exact = "multipart/form-data" },
        };
        pub const Field = FieldEvent;
        pub const File = FileTag;
        pub const FileStart = FileStartEvent;
        pub const BeginInput = BeginEvent;
        pub const Summaries = UploadSummaries;

        pub fn FileAdmission(comptime Response: type) type {
            return upload.FileDecision(BeginEvent, Response);
        }
    };
}

fn Field(comptime T: type, comptime requested: Cardinality) type {
    comptime validateScalar(T);
    const resolved_cardinality = comptime validateCardinality(requested);
    return struct {
        pub const ploof_multipart_part = true;
        pub const kind: PartKind = .field;
        pub const Target = T;
        pub const cardinality = resolved_cardinality;
    };
}

fn BytesField(comptime requested: Cardinality) type {
    const resolved_cardinality = comptime validateCardinality(requested);
    return struct {
        pub const ploof_multipart_part = true;
        pub const kind: PartKind = .bytes_field;
        pub const Target = []const u8;
        pub const cardinality = resolved_cardinality;
    };
}

fn File(
    comptime Sink: type,
    comptime requested: Cardinality,
    comptime media_policy: ClaimedMediaPolicy,
) type {
    const resolved_cardinality = comptime validateCardinality(requested);
    comptime upload.validateSink(Sink);
    if (comptime mediaPolicyIssue(media_policy)) |problem| {
        @compileError(problem.diagnostic());
    }
    return struct {
        pub const ploof_multipart_part = true;
        pub const kind: PartKind = .file;
        pub const SinkType = Sink;
        pub const cardinality = resolved_cardinality;
        pub const claimed_media_policy = media_policy;
    };
}

fn validateCardinality(comptime value: Cardinality) Cardinality {
    switch (value) {
        .zero_to, .one_to => |maximum| if (maximum == 0) {
            @compileError("PLOOF-E3429 multipart cardinality maximum must be nonzero");
        },
        .required, .optional => {},
    }
    return value;
}

fn validateScalar(comptime T: type) void {
    if (T == []const u8) return;
    if (hasTextHook(T)) {
        if (flat_schema.textHookIssue(T)) |problem| switch (problem) {
            .not_function => @compileError("PLOOF-E3441 multipart parseText must be a function"),
            .wrong_signature => @compileError(
                "PLOOF-E3442 multipart parseText must use the Ploof flat text signature",
            ),
        };
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional_type| validateScalar(optional_type.child),
        .int, .float, .bool, .@"enum" => {},
        else => @compileError("PLOOF-E3443 unsupported multipart text field type"),
    }
}

fn hasTextHook(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "parseText"),
        else => false,
    };
}

fn nameIssue(name: []const u8, name_bytes_max: u16) ?SchemaIssue {
    if (name.len == 0) return .empty_name;
    if (name.len > name_bytes_max) return .name_too_long;
    if (!std.unicode.utf8ValidateSlice(name)) return .invalid_name;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return .invalid_name;
    return null;
}

fn unknownPartsIssue(policy: UnknownParts, total_bytes_max: u64) ?SchemaIssue {
    return switch (policy) {
        .reject => null,
        .ignore_unknown => |maximum| if (maximum == 0)
            .ignored_part_bytes_zero
        else if (maximum > total_bytes_max)
            .ignored_part_bytes_above_total
        else
            null,
    };
}

fn MediaClaims(comptime media_types: []const []const u8) type {
    return struct {
        pub const values: [media_types.len]MediaClaim = resolved: {
            var claims: [media_types.len]MediaClaim = undefined;
            for (media_types, 0..) |media_type, index| {
                claims[index] = splitMediaClaim(media_type);
            }
            break :resolved claims;
        };
    };
}

fn splitMediaClaim(comptime value: []const u8) MediaClaim {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse {
        @compileError("PLOOF-E3445 invalid multipart claimed media type");
    };
    if (std.mem.indexOfScalar(u8, value[slash + 1 ..], '/') != null) {
        @compileError("PLOOF-E3445 invalid multipart claimed media type");
    }
    return .{ .type = value[0..slash], .subtype = value[slash + 1 ..] };
}

fn validClaimToken(value: []const u8) bool {
    return syntax.isToken(value) and std.mem.indexOfScalar(u8, value, '*') == null;
}

fn normalizedClaimToken(value: []const u8) bool {
    for (value) |byte| if (byte >= 'A' and byte <= 'Z') return false;
    return true;
}

fn fieldEventType(comptime schema: anytype) type {
    const fields = @typeInfo(@TypeOf(schema)).@"struct".fields;
    const count = comptime fieldEntryCount(schema);
    if (count == 0) return void;
    var names: [count][]const u8 = undefined;
    var values: [count]u16 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        if (Part.kind == .file or isCsrfField(Part)) continue;
        names[index] = schema_field.name;
        values[index] = @intCast(index);
        types[index] = Part.Target;
        index += 1;
    }
    const Tag = @Enum(u16, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &@splat(.{}));
}

fn fileTagType(comptime schema: anytype) type {
    const fields = @typeInfo(@TypeOf(schema)).@"struct".fields;
    const count = comptime fileEntryCount(schema);
    if (count == 0) return void;
    var names: [count][]const u8 = undefined;
    var values: [count]u16 = undefined;
    var index: usize = 0;
    inline for (fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        if (Part.kind != .file) continue;
        names[index] = schema_field.name;
        values[index] = @intCast(index);
        index += 1;
    }
    return @Enum(u16, .exhaustive, &names, &values);
}

fn fieldEntryCount(comptime schema: anytype) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        count += @intFromBool(Part.kind != .file and !isCsrfField(Part));
    }
    return count;
}

fn csrfFieldCount(comptime schema: anytype) u16 {
    var count: u16 = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        count += @intFromBool(isCsrfField(Part));
    }
    return count;
}

fn csrfFieldName(comptime schema: anytype) ?[]const u8 {
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        if (isCsrfField(Part)) return schema_field.name;
    }
    return null;
}

fn csrfFieldIndex(comptime schema: anytype) ?u16 {
    inline for (
        @typeInfo(@TypeOf(schema)).@"struct".fields,
        0..,
    ) |schema_field, index| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        if (isCsrfField(Part)) return @intCast(index);
    }
    return null;
}

fn fileEntryCount(comptime schema: anytype) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |schema_field| {
        const Part = @TypeOf(@field(schema, schema_field.name));
        count += @intFromBool(Part.kind == .file);
    }
    return count;
}
