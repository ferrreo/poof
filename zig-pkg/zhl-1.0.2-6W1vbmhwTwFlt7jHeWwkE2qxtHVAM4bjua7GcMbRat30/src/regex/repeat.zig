pub const ParseError = error{
    InvalidRange,
    UnsupportedRegex,
};

pub const Repeat = struct {
    min: usize,
    max: usize,
    open: bool = false,
};

pub fn parse(pattern: []const u8, index: *usize) ParseError!Repeat {
    index.* += 1;
    const omitted_min = index.* < pattern.len and pattern[index.*] == ',';
    const min: usize = if (omitted_min) 0 else try parseNumber(pattern, index);
    var max = min;
    var open = false;
    if (index.* < pattern.len and pattern[index.*] == ',') {
        index.* += 1;
        if (index.* < pattern.len and pattern[index.*] == '}') {
            if (omitted_min) return error.UnsupportedRegex;
            open = true;
        } else {
            max = try parseNumber(pattern, index);
            if (max < min) return error.InvalidRange;
        }
    }
    if (index.* >= pattern.len or pattern[index.*] != '}') return error.UnsupportedRegex;
    index.* += 1;
    return .{ .min = min, .max = max, .open = open };
}

fn parseNumber(pattern: []const u8, index: *usize) ParseError!usize {
    const start = index.*;
    var value: usize = 0;
    while (index.* < pattern.len and pattern[index.*] >= '0' and pattern[index.*] <= '9') : (index.* += 1) {
        value = value * 10 + pattern[index.*] - '0';
        if (value > 255) return error.UnsupportedRegex;
    }
    if (index.* == start) return error.UnsupportedRegex;
    return value;
}
