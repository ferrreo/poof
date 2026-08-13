const std = @import("std");
const flat_wire = @import("wire.zig");
const text_scalar = @import("../text/scalar.zig");

pub const TextDecodeError = text_scalar.TextDecodeError;
pub const TextHookIssue = text_scalar.HookIssue;

pub const UnknownPolicy = enum(u8) {
    ignore,
    reject,
};

pub const Options = struct {
    unknown_fields: UnknownPolicy = .ignore,
};

pub const IssueClass = enum(u8) {
    unknown_field,
    missing_field,
    cardinality,
    invalid_text,
    invalid_value,
    insufficient_storage,
};

pub const Issue = struct {
    class: IssueClass,
    /// Known schema name only; unknown submitted names are never reflected.
    field: ?[]const u8,
};

pub const Arena = struct {
    bytes: []u8,
    used: usize = 0,

    pub fn init(bytes: []u8) Arena {
        return .{ .bytes = bytes };
    }

    pub fn reset(self: *Arena) void {
        self.used = 0;
    }

    fn allocate(self: *Arena, comptime T: type, count: usize) ConversionError![]T {
        if (@sizeOf(T) == 0) {
            const pointer: [*]T = @ptrFromInt(@alignOf(T));
            return pointer[0..count];
        }
        if (self.used > self.bytes.len) return error.InsufficientStorage;
        const byte_count = std.math.mul(usize, @sizeOf(T), count) catch {
            return error.InsufficientStorage;
        };
        const base = @intFromPtr(self.bytes.ptr);
        const current = base + self.used;
        const aligned = std.mem.alignForward(usize, current, @alignOf(T));
        const start = aligned - base;
        if (start > self.bytes.len or byte_count > self.bytes.len - start) {
            return error.InsufficientStorage;
        }
        const pointer: [*]T = @ptrCast(@alignCast(self.bytes.ptr + start));
        self.used = start + byte_count;
        return pointer[0..count];
    }
};

pub fn BindResult(comptime T: type) type {
    return union(enum) {
        ready: T,
        rejected: Issue,
    };
}

pub fn textHookIssue(comptime T: type) ?TextHookIssue {
    return text_scalar.hookIssue(T);
}

pub fn bind(
    comptime T: type,
    table: flat_wire.Table,
    arena: *Arena,
    comptime options: Options,
) BindResult(T) {
    comptime validateSchema(T);
    const fields = @typeInfo(T).@"struct".fields;
    var counts = [_]usize{0} ** fields.len;
    const arena_mark = arena.used;

    for (table.pairs) |pair| {
        var matched = false;
        inline for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, pair.name, wireName(T, field.name))) {
                counts[index] += 1;
                matched = true;
            }
        }
        if (!matched and options.unknown_fields == .reject) {
            arena.used = arena_mark;
            return .{ .rejected = .{ .class = .unknown_field, .field = null } };
        }
    }

    inline for (fields, 0..) |field, index| {
        if (counts[index] == 0) {
            if (field.default_value_ptr == null) {
                return reject(T, arena, arena_mark, .missing_field, wireName(T, field.name));
            }
        } else if (!cardinalityMatches(field.type, counts[index])) {
            return reject(T, arena, arena_mark, .cardinality, wireName(T, field.name));
        }
    }

    var result: T = undefined;
    inline for (fields, 0..) |field, index| {
        if (counts[index] == 0) {
            @field(result, field.name) = field.defaultValue().?;
        } else {
            @field(result, field.name) = convertField(
                field.type,
                wireName(T, field.name),
                table,
                arena,
            ) catch |conversion_error| {
                return reject(
                    T,
                    arena,
                    arena_mark,
                    issueClass(conversion_error),
                    wireName(T, field.name),
                );
            };
        }
    }
    return .{ .ready = result };
}

fn reject(
    comptime T: type,
    arena: *Arena,
    arena_mark: usize,
    class: IssueClass,
    field: []const u8,
) BindResult(T) {
    arena.used = arena_mark;
    return .{ .rejected = .{ .class = class, .field = field } };
}

const Cardinality = union(enum) {
    one,
    many,
    exact: usize,
};

fn cardinality(comptime T: type) Cardinality {
    if (T == []const u8) return .one;
    return switch (@typeInfo(T)) {
        .array => |array| .{ .exact = array.len },
        .pointer => |pointer| if (pointer.size == .slice) .many else .one,
        else => .one,
    };
}

fn cardinalityMatches(comptime T: type, count: usize) bool {
    return switch (cardinality(T)) {
        .one => count == 1,
        .many => count != 0,
        .exact => |expected| count == expected,
    };
}

const ConversionError = error{
    InvalidText,
    InvalidValue,
    InsufficientStorage,
};

fn issueClass(conversion_error: ConversionError) IssueClass {
    return switch (conversion_error) {
        error.InvalidText => .invalid_text,
        error.InvalidValue => .invalid_value,
        error.InsufficientStorage => .insufficient_storage,
    };
}

fn convertField(
    comptime T: type,
    name: []const u8,
    table: flat_wire.Table,
    arena: *Arena,
) ConversionError!T {
    switch (comptime cardinality(T)) {
        .one => {
            for (table.pairs) |pair| {
                if (std.mem.eql(u8, pair.name, name)) return text_scalar.parse(T, pair.value);
            }
        },
        .exact => {
            const array = @typeInfo(T).array;
            var result: T = undefined;
            var index: usize = 0;
            for (table.pairs) |pair| {
                if (!std.mem.eql(u8, pair.name, name)) continue;
                result[index] = try text_scalar.parse(array.child, pair.value);
                index += 1;
            }
            return result;
        },
        .many => {
            const child = @typeInfo(T).pointer.child;
            var count: usize = 0;
            for (table.pairs) |pair| if (std.mem.eql(u8, pair.name, name)) {
                count += 1;
            };
            const result = try arena.allocate(child, count);
            var index: usize = 0;
            for (table.pairs) |pair| {
                if (!std.mem.eql(u8, pair.name, name)) continue;
                result[index] = try text_scalar.parse(child, pair.value);
                index += 1;
            }
            return result;
        },
    }
    unreachable;
}

fn validateSchema(comptime T: type) void {
    if (@typeInfo(T) != .@"struct" or @typeInfo(T).@"struct".is_tuple) {
        @compileError("flat binding destination must be a non-tuple struct");
    }
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |field| {
        if (field.is_comptime) @compileError("comptime flat fields are unsupported");
        validateFieldType(field.type);
        const name = wireName(T, field.name);
        if (name.len == 0) @compileError("flat wire names must be nonempty");
        if (!std.unicode.utf8ValidateSlice(name)) {
            @compileError("flat wire names must be valid UTF-8");
        }
    }
    validateMetadata(T);
    inline for (fields, 0..) |left, left_index| {
        inline for (fields[left_index + 1 ..]) |right| {
            if (std.mem.eql(u8, wireName(T, left.name), wireName(T, right.name))) {
                @compileError("duplicate flat wire name");
            }
        }
    }
}

fn validateMetadata(comptime T: type) void {
    if (!@hasDecl(T, "ploof_flat_fields")) return;
    const metadata = T.ploof_flat_fields;
    if (@typeInfo(@TypeOf(metadata)) != .@"struct") {
        @compileError("ploof_flat_fields must be a struct literal");
    }
    const metadata_info = @typeInfo(@TypeOf(metadata)).@"struct";
    if (metadata_info.is_tuple) @compileError("ploof_flat_fields must use named entries");
    inline for (metadata_info.fields) |entry| {
        if (!@hasField(T, entry.name)) {
            @compileError("ploof_flat_fields names an unknown field");
        }
        const name: []const u8 = @field(metadata, entry.name);
        _ = name;
    }
}

fn validateFieldType(comptime T: type) void {
    switch (comptime cardinality(T)) {
        .one => validateScalarType(T),
        .exact => validateScalarType(@typeInfo(T).array.child),
        .many => {
            const pointer = @typeInfo(T).pointer;
            if (pointer.sentinel_ptr != null) {
                @compileError("sentinel flat slices are unsupported");
            }
            if (pointer.child == u8) {
                @compileError("mutable byte slices are not flat text fields");
            }
            validateScalarType(pointer.child);
        },
    }
}

fn validateScalarType(comptime T: type) void {
    if (T == []const u8) return;
    if (text_scalar.hasHook(T)) {
        if (textHookIssue(T)) |issue| switch (issue) {
            .not_function => @compileError("parseText must be a function"),
            .wrong_signature => @compileError(
                "parseText must use the Ploof flat text signature",
            ),
        };
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| validateScalarType(optional.child),
        .int, .float, .bool, .@"enum" => {},
        else => @compileError("unsupported flat field type"),
    }
}

pub fn wireName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (@hasDecl(T, "ploof_flat_fields")) {
        const metadata = T.ploof_flat_fields;
        if (@typeInfo(@TypeOf(metadata)) == .@"struct" and
            @hasField(@TypeOf(metadata), field_name))
        {
            return @field(metadata, field_name);
        }
    }
    return field_name;
}
