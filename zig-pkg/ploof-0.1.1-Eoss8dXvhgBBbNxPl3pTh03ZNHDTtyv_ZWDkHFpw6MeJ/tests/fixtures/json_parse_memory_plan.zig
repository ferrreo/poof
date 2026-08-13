const ploof = @import("ploof_compile").ploof;

const BrokenDecoder = @TypeOf(ploof.Json.typed(
    []const u64,
    .{ .parse_memory_bytes_max = 16 },
));

export fn forceJsonParseMemoryPlan() void {
    _ = @sizeOf(BrokenDecoder);
}
