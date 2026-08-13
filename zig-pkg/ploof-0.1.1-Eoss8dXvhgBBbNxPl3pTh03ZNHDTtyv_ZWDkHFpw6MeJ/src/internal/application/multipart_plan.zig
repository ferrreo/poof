const std = @import("std");
const multipart_plan = @import("../multipart/plan.zig");

pub fn compiledPlan(comptime Spec: type) multipart_plan.Plan {
    return CompiledPlan(Spec).value;
}

fn CompiledPlan(comptime Spec: type) type {
    comptime requireSpec(Spec);
    const options = Spec.resolved_options;
    const limits = options.limits;
    const padding_max = limits.delimiter_transport_padding_bytes_max;
    return struct {
        pub const value = multipart_plan.Plan{
            .entries = &EntryTable(Spec).values,
            .unknown_parts = compileUnknownParts(options.unknown_parts),
            .limits = .{
                .total_body_bytes_max = limits.total_body_bytes_max,
                .file_bytes_max = limits.file_bytes_max,
                .field_bytes_max = toUsize(limits.field_bytes_max),
                .parts_max = limits.parts_max,
                .files_max = limits.files_max,
                .part_headers_max = limits.part_headers_max,
                .part_header_bytes_max = limits.part_header_bytes_max,
                .disposition_parameters_max = limits.disposition_parameters_max,
                .delimiter_transport_padding_bytes_max = padding_max,
                .name_bytes_max = limits.name_bytes_max,
                .filename_bytes_max = limits.filename_bytes_max,
                .boundary_bytes_max = limits.boundary_bytes_max,
            },
        };

        comptime {
            multipart_plan.validate(value);
        }
    };
}

fn EntryTable(comptime Spec: type) type {
    const schema = Spec.configured_schema;
    const limits = Spec.resolved_options.limits;
    const fields = @typeInfo(@TypeOf(schema)).@"struct".fields;
    return struct {
        pub const values: [fields.len]multipart_plan.Entry = entries: {
            var result: [fields.len]multipart_plan.Entry = undefined;
            for (fields, 0..) |schema_field, index| {
                const Part = @TypeOf(@field(schema, schema_field.name));
                const csrf_field = @import("../../multipart.zig").isCsrfField(Part);
                result[index] = .{
                    .name = schema_field.name,
                    .kind = compilePartKind(Part.kind),
                    .required = if (csrf_field) false else Part.cardinality.isRequired(),
                    .maximum = if (csrf_field)
                        limits.parts_max
                    else
                        Part.cardinality.maximum(),
                    .bytes_max = if (csrf_field)
                        @import("../../multipart.zig").csrf_field_bytes_max
                    else
                        toUsize(limits.field_bytes_max),
                    .csrf_field = csrf_field,
                    .file_media = compileFileMedia(Part),
                };
            }
            break :entries result;
        };
    };
}

pub fn csrfFieldName(comptime Spec: type) ?[]const u8 {
    comptime requireSpec(Spec);
    return Spec.ploof_csrf_field_name;
}

pub fn csrfFieldIndex(comptime Spec: type) ?u16 {
    comptime requireSpec(Spec);
    return Spec.ploof_csrf_field_index;
}

pub fn csrfFieldCount(comptime Spec: type) u16 {
    comptime requireSpec(Spec);
    return Spec.ploof_csrf_field_count;
}

fn compilePartKind(comptime kind: anytype) multipart_plan.PartKind {
    return switch (kind) {
        .field => .text,
        .bytes_field => .bytes,
        .file => .file,
    };
}

fn compileFileMedia(comptime Part: type) multipart_plan.FileMediaPolicy {
    if (Part.kind != .file) return .{ .any = .allow };
    const policy = Part.claimed_media_policy;
    const missing: multipart_plan.MissingMedia = switch (policy.missing) {
        .allow => .allow,
        .reject => .reject,
    };
    const claims = policy.exact orelse return .{ .any = missing };
    return .{ .claimed = .{
        .values = &ClaimTable(claims).values,
        .missing = missing,
    } };
}

fn ClaimTable(comptime claims: anytype) type {
    return struct {
        pub const values: [claims.len]multipart_plan.MediaClaim = result: {
            var compiled: [claims.len]multipart_plan.MediaClaim = undefined;
            for (claims, 0..) |claim, index| {
                compiled[index] = .{ .type = claim.type, .subtype = claim.subtype };
            }
            break :result compiled;
        };
    };
}

fn compileUnknownParts(comptime policy: anytype) multipart_plan.UnknownParts {
    return switch (policy) {
        .reject => .reject,
        .ignore_unknown => |bytes_max| .{ .discard = bytes_max },
    };
}

fn requireSpec(comptime Spec: type) void {
    if (@typeInfo(Spec) != .@"struct" or
        !@hasDecl(Spec, "ploof_multipart_push_decoder") or
        !Spec.ploof_multipart_push_decoder)
    {
        @compileError("PLOOF-E3448 invalid multipart decoder declaration");
    }
}

fn toUsize(comptime value: u64) usize {
    if (value > std.math.maxInt(usize)) {
        @compileError("PLOOF-E3449 multipart parser workspace exceeds address space");
    }
    return @intCast(value);
}

test {
    std.testing.refAllDecls(@This());
}
