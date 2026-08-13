const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    pub fn jsonParse(comptime _: anytype) ploof.Json.ParseError!@This() {
        return .{};
    }
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonParseComptimeParameter() void {
    _ = @sizeOf(BrokenDecoder);
}
