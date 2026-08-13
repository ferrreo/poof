const std = @import("std");

pub fn validateSubset(comptime subset: type, comptime superset: type) void {
    const subset_info = @typeInfo(subset).error_set orelse {
        @compileError("PLOOF-E3074 middleware and handler errors must be finite");
    };
    const superset_info = @typeInfo(superset).error_set.?;
    for (subset_info) |candidate| {
        var found = false;
        for (superset_info) |allowed| {
            if (std.mem.eql(u8, candidate.name, allowed.name)) {
                found = true;
                break;
            }
        }
        if (!found) @compileError("PLOOF-E3075 undeclared Application error");
    }
}

test {
    std.testing.refAllDecls(@This());
}
