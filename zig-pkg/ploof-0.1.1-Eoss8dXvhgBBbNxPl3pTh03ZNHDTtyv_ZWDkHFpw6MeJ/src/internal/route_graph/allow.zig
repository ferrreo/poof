const route = @import("../../route.zig");

pub const Allow = struct {
    mask: u8 = 0,

    pub const options_bit: u8 = 1 << 6;
    const names = [_][]const u8{
        "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
    };

    pub fn isEmpty(allow: Allow) bool {
        return allow.mask == 0;
    }

    pub fn contains(allow: Allow, method: route.Method) bool {
        return allow.mask & (@as(u8, 1) << @intCast(@intFromEnum(method))) != 0;
    }

    pub fn containsOptions(allow: Allow) bool {
        return allow.mask & options_bit != 0;
    }

    pub fn wireLength(allow: Allow) usize {
        var length: usize = 0;
        for (names, 0..) |name, index| {
            if (allow.mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (length != 0) length += 2;
            length += name.len;
        }
        return length;
    }

    pub fn write(allow: Allow, output: []u8) error{NoSpace}![]const u8 {
        const needed = allow.wireLength();
        if (output.len < needed) return error.NoSpace;
        var written: usize = 0;
        for (names, 0..) |name, index| {
            if (allow.mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
            if (written != 0) {
                output[written] = ',';
                output[written + 1] = ' ';
                written += 2;
            }
            @memcpy(output[written..][0..name.len], name);
            written += name.len;
        }
        return output[0..written];
    }
};
