const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    pub fn jsonParse(_: anytype) ploof.Json.ParseError!u8 {
        return 0;
    }
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonParsePayload() void {
    _ = @sizeOf(BrokenDecoder);
}
