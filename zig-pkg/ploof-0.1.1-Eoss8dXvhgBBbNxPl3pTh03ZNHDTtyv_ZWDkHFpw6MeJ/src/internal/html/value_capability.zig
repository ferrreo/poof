const std = @import("std");

pub fn carries(comptime T: type) bool {
    return carriesInner(T, .{});
}

fn carriesInner(comptime T: type, comptime seen: anytype) bool {
    inline for (seen) |Seen| if (T == Seen) return false;
    if (T == anyopaque or T == std.Io.File or T == std.Io.Dir) return true;
    if (capabilityMarker(T)) return true;
    const next = seen ++ .{T};
    return switch (@typeInfo(T)) {
        .pointer => |pointer| !pointer.is_const or pointer.is_volatile or
            pointer.address_space != .generic or carriesInner(pointer.child, next),
        .error_union => |error_union| carriesInner(error_union.payload, next),
        .optional => |optional| carriesInner(optional.child, next),
        .array => |array| carriesInner(array.child, next),
        .vector => |vector| carriesInner(vector.child, next),
        .@"struct" => |info| fieldsCarry(info.fields, next),
        .@"union" => |info| fieldsCarry(info.fields, next),
        .@"fn" => true,
        else => false,
    };
}

fn fieldsCarry(comptime fields: anytype, comptime seen: anytype) bool {
    inline for (fields) |field| {
        if (carriesInner(field.type, seen)) return true;
    }
    return false;
}

fn capabilityMarker(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => marker: {
            if (!@hasDecl(T, "ploof_template_helper_capability")) break :marker false;
            const value = @field(T, "ploof_template_helper_capability");
            break :marker @TypeOf(value) != bool or value;
        },
        else => false,
    };
}

pub fn hasComptimeParameter(comptime Function: type) bool {
    // Zig 0.16 Fn.Param does not expose comptime; @typeName is the exact source.
    const name = @typeName(Function);
    const start = std.mem.indexOf(u8, name, "fn (") orelse return false;
    var cursor = start + "fn (".len;
    var depth: usize = 1;
    var parameter_start = true;
    while (cursor < name.len and depth != 0) : (cursor += 1) {
        if (parameter_start) {
            while (cursor < name.len and name[cursor] == ' ') cursor += 1;
            if (std.mem.startsWith(u8, name[cursor..], "comptime ")) return true;
            parameter_start = false;
        }
        switch (name[cursor]) {
            '(' => depth += 1,
            ')' => depth -= 1,
            ',' => if (depth == 1) {
                parameter_start = true;
            },
            else => {},
        }
    }
    return false;
}

test "volatile and non-generic const pointers remain capabilities" {
    try std.testing.expect(carries(*const volatile u32));
    try std.testing.expect(carries(*addrspace(.gs) const u32));
    try std.testing.expect(!carries(*const u32));
}

test {
    std.testing.refAllDecls(@This());
}
