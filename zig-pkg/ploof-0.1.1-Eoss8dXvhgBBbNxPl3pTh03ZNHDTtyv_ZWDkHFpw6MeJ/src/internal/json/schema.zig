const std = @import("std");

pub const declaration_name = "ploof_json_fields";

pub const FieldOptions = struct {
    rename: ?[]const u8 = null,
    omit_if_null: bool = false,
};

pub const Issue = enum(u8) {
    metadata_not_struct,
    unknown_field,
    invalid_options,
    empty_name,
    invalid_utf8,
    duplicate_name,
    omit_non_optional,
};

pub fn field(comptime options: FieldOptions) FieldOptions {
    return options;
}

pub fn validate(comptime T: type) void {
    const problem = comptime issue(T);
    if (problem) |value| @compileError(diagnostic(value));
}

pub fn issue(comptime T: type) ?Issue {
    @setEvalBranchQuota(100_000);
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return .metadata_not_struct,
    };
    if (@hasDecl(T, declaration_name)) {
        const metadata = @field(T, declaration_name);
        const metadata_info = switch (@typeInfo(@TypeOf(metadata))) {
            .@"struct" => |metadata_info| metadata_info,
            else => return .metadata_not_struct,
        };
        inline for (metadata_info.fields) |entry| {
            if (!@hasField(T, entry.name)) return .unknown_field;
            if (entry.type != FieldOptions) return .invalid_options;
        }
    }
    inline for (info.fields) |candidate| {
        if (candidate.type == void) continue;
        const options = comptime optionsFor(T, candidate.name);
        const name = options.rename orelse candidate.name;
        if (name.len == 0) return .empty_name;
        if (!std.unicode.utf8ValidateSlice(name)) return .invalid_utf8;
        if (options.omit_if_null and @typeInfo(candidate.type) != .optional) {
            return .omit_non_optional;
        }
        inline for (info.fields) |other| {
            if (other.type == void or comptime std.mem.eql(u8, candidate.name, other.name)) {
                continue;
            }
            const other_options = comptime optionsFor(T, other.name);
            const other_name = other_options.rename orelse other.name;
            if (std.mem.eql(u8, name, other_name)) return .duplicate_name;
        }
    }
    return null;
}

pub fn wireName(comptime T: type, comptime field_name: []const u8) []const u8 {
    validate(T);
    return optionsFor(T, field_name).rename orelse field_name;
}

pub fn omitIfNull(comptime T: type, comptime field_name: []const u8) bool {
    validate(T);
    return optionsFor(T, field_name).omit_if_null;
}

fn optionsFor(comptime T: type, comptime field_name: []const u8) FieldOptions {
    if (!@hasDecl(T, declaration_name)) return .{};
    const metadata = @field(T, declaration_name);
    if (!@hasField(@TypeOf(metadata), field_name)) return .{};
    const options = @field(metadata, field_name);
    if (@TypeOf(options) != FieldOptions) return .{};
    return options;
}

fn diagnostic(problem: Issue) []const u8 {
    return switch (problem) {
        .metadata_not_struct => "PLOOF-E3220 JSON field metadata must be a struct",
        .unknown_field => "PLOOF-E3221 JSON metadata names an unknown field",
        .invalid_options => "PLOOF-E3222 JSON metadata must use json.field",
        .empty_name => "PLOOF-E3223 JSON wire field names must be nonempty",
        .invalid_utf8 => "PLOOF-E3224 JSON wire field names must be valid UTF-8",
        .duplicate_name => "PLOOF-E3225 duplicate JSON wire field name",
        .omit_non_optional => "PLOOF-E3226 omit_if_null requires an optional field",
    };
}

test "schema resolves explicit names and omission" {
    const T = struct {
        id: u64,
        note: ?[]const u8,

        pub const ploof_json_fields = .{
            .id = field(.{ .rename = "recordId" }),
            .note = field(.{ .omit_if_null = true }),
        };
    };
    try std.testing.expect(issue(T) == null);
    try std.testing.expectEqualStrings("recordId", wireName(T, "id"));
    try std.testing.expect(omitIfNull(T, "note"));
}
