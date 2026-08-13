const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    pub fn jsonParse(_: u8) ploof.Json.ParseError!@This() {
        return .{};
    }
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonParseParameter() void {
    _ = @sizeOf(BrokenDecoder);
}
