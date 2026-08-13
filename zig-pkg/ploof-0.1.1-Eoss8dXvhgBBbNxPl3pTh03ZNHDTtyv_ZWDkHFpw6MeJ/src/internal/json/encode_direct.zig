const std = @import("std");
const scalar = @import("encode_scalar.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");

// Runtime sequence lengths change iteration count, not call depth. Limiting
// the type wrappers keeps this common-record path statically stack-bounded.
const type_depth_max = 4;

pub fn eligible(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == types.Value) return false;
    const info = switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => return false,
    };
    if (info.is_tuple or std.meta.hasFn(T, "jsonStringify")) return false;
    inline for (info.fields) |field| {
        if (field.type != void and !fieldEligible(field.type, .{T})) return false;
    }
    return true;
}

fn fieldEligible(comptime T: type, comptime ancestors: anytype) bool {
    if (T == types.Value) return false;
    if (T == types.Number) return true;
    switch (@typeInfo(T)) {
        .int,
        .comptime_int,
        .float,
        .comptime_float,
        .bool,
        .null,
        .enum_literal,
        .error_set,
        => return true,
        .@"enum" => return !std.meta.hasFn(T, "jsonStringify"),
        .optional => |info| {
            if (!canDescend(T, ancestors)) return false;
            return fieldEligible(info.child, ancestors ++ .{T});
        },
        .array => |info| {
            if (info.child == u8) return true;
            if (!canDescend(T, ancestors)) return false;
            return fieldEligible(info.child, ancestors ++ .{T});
        },
        .pointer => |info| {
            if (info.child == u8 and (info.size == .slice or info.size == .many)) {
                return info.size != .many or info.sentinel() != null;
            }
            if (info.size != .slice and info.size != .many) return false;
            if (info.size == .many and info.sentinel() == null) return false;
            if (!canDescend(T, ancestors)) return false;
            return fieldEligible(info.child, ancestors ++ .{T});
        },
        else => return false,
    }
}

fn canDescend(comptime T: type, comptime ancestors: anytype) bool {
    if (ancestors.len == type_depth_max) return false;
    inline for (ancestors) |Ancestor| {
        if (T == Ancestor) return false;
    }
    return true;
}

pub fn Driver(comptime Host: type, comptime FullError: type) type {
    return struct {
        const Self = @This();

        pub fn write(self: *Host, value: anytype) FullError!void {
            const T = @TypeOf(value);
            const info = @typeInfo(T).@"struct";
            comptime schema.validate(T);
            try self.open('{');
            var emitted: usize = 0;
            inline for (info.fields) |field| {
                if (field.type == void) continue;
                if (comptime schema.omitIfNull(T, field.name)) {
                    if (@field(value, field.name) != null) {
                        try Self.writeStructField(
                            self,
                            T,
                            field.name,
                            @field(value, field.name),
                            &emitted,
                        );
                    }
                } else {
                    try Self.writeStructField(
                        self,
                        T,
                        field.name,
                        @field(value, field.name),
                        &emitted,
                    );
                }
            }
            try self.close('}', emitted != 0);
        }

        fn writeStructField(
            self: *Host,
            comptime T: type,
            comptime field_name: []const u8,
            value: anytype,
            emitted: *usize,
        ) FullError!void {
            try self.separator(emitted.*);
            try self.writeString(comptime schema.wireName(T, field_name));
            try self.colon();
            try Self.writeField(self, value);
            emitted.* += 1;
        }

        fn writeField(self: *Host, value: anytype) FullError!void {
            const T = @TypeOf(value);
            if (T == types.Number) return scalar.writeNumber(&self.sink, value);
            switch (@typeInfo(T)) {
                .int => return scalar.writeInteger(&self.sink, value),
                .comptime_int => {
                    const Fitting = std.math.IntFittingRange(value, value);
                    return scalar.writeInteger(&self.sink, @as(Fitting, value));
                },
                .float => return scalar.writeFloat(&self.sink, value),
                .comptime_float => return scalar.writeFloat(&self.sink, @as(f128, value)),
                .bool => return self.sink.writeAll(if (value) "true" else "false"),
                .null => return self.sink.writeAll("null"),
                .optional => {
                    if (value) |payload| return Self.writeField(self, payload);
                    return self.sink.writeAll("null");
                },
                .@"enum" => return self.writeEnum(value),
                .enum_literal => return self.writeString(@tagName(value)),
                .error_set => return self.writeString(@errorName(value)),
                .pointer => return Self.writePointer(self, value),
                .array => return Self.writeArray(self, value),
                else => unreachable,
            }
        }

        fn writePointer(self: *Host, value: anytype) FullError!void {
            const info = @typeInfo(@TypeOf(value)).pointer;
            switch (info.size) {
                .slice => {
                    if (info.child == u8) return self.writeString(value);
                    return Self.writeSequence(self, value);
                },
                .many => {
                    const slice = std.mem.span(value);
                    if (info.child == u8) return self.writeString(slice);
                    return Self.writeSequence(self, slice);
                },
                .one, .c => unreachable,
            }
        }

        fn writeArray(self: *Host, value: anytype) FullError!void {
            const info = @typeInfo(@TypeOf(value)).array;
            if (info.child == u8) return self.writeString(value[0..]);
            return Self.writeSequence(self, value[0..]);
        }

        fn writeSequence(self: *Host, value: anytype) FullError!void {
            try self.open('[');
            for (value, 0..) |item, index| {
                try self.separator(index);
                try Self.writeField(self, item);
            }
            try self.close(']', value.len != 0);
        }
    };
}

test "direct eligibility is finite and excludes trampoline-owned shapes" {
    const Finite = struct {
        id: u64,
        names: []const []const u8,
        note: ?[]const u8,
    };
    const Recursive = struct {
        next: ?*const @This(),
    };
    const Hook = struct {
        pub fn jsonStringify(_: @This(), _: anytype) types.Error!void {}
    };
    const WrappedHook = struct {
        values: ?[]const Hook,
    };
    const NestedObject = struct {
        child: struct { value: u8 },
    };
    const AtLimit = struct {
        values: []const []const []const []const u8,
    };
    const OverLimit = struct {
        values: []const []const []const []const []const u8,
    };

    try std.testing.expect(eligible(Finite));
    try std.testing.expect(eligible(AtLimit));
    try std.testing.expect(!eligible(OverLimit));
    try std.testing.expect(!eligible(Recursive));
    try std.testing.expect(!eligible(WrappedHook));
    try std.testing.expect(!eligible(NestedObject));
    try std.testing.expect(!eligible(types.Value));
}
