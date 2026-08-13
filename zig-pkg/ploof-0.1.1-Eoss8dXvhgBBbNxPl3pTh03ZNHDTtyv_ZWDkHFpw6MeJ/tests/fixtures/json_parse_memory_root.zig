const ploof = @import("ploof_compile").ploof;

const BrokenDecoder = @TypeOf(ploof.Json.typed(struct {
    bytes: [32]u8,
}, .{ .parse_memory_bytes_max = 8 }));

export fn forceJsonParseMemoryRoot() void {
    _ = @sizeOf(BrokenDecoder);
}
