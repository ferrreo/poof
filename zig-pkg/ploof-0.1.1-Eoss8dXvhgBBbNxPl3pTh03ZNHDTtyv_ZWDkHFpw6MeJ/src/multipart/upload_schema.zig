const std = @import("std");

pub fn FileStartEvent(
    comptime schema: anytype,
    comptime FileTag: type,
    comptime Metadata: type,
) type {
    const count = fileCount(schema);
    if (count == 0) return void;
    var names: [count][]const u8 = undefined;
    var types: [count]type = @splat(Metadata);
    fillFileNames(schema, &names);
    return @Union(.auto, FileTag, &names, &types, &@splat(.{}));
}

pub fn BeginInput(comptime schema: anytype, comptime FileTag: type) type {
    const count = fileCount(schema);
    if (count == 0) return void;
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = Part.SinkType.BeginInput;
        index += 1;
    }
    return @Union(.auto, FileTag, &names, &types, &@splat(.{}));
}

pub fn Summaries(comptime schema: anytype) type {
    const count = fileCount(schema);
    if (count == 0) return struct {};
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = SummaryView(
            Part.SinkType.Summary,
            Part.cardinality.maximum(),
        );
        index += 1;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

pub fn SummaryView(comptime T: type, comptime maximum: u16) type {
    if (maximum == 0) @compileError("multipart summary maximum must be nonzero");
    const Length = std.math.IntFittingRange(0, maximum);
    return struct {
        values: *const [maximum]T,
        len: Length,

        pub fn slice(self: @This()) []const T {
            return self.values[0..@intCast(self.len)];
        }
    };
}

fn fillFileNames(comptime schema: anytype, names: anytype) void {
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        index += 1;
    }
}

fn fileCount(comptime schema: anytype) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        count += @intFromBool(Part.kind == .file);
    }
    return count;
}

test {
    std.testing.refAllDecls(@This());
}
