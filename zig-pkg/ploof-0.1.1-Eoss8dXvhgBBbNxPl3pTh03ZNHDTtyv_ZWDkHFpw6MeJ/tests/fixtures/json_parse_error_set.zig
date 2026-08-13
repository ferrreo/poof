const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    pub fn jsonParse(_: anytype) error{Rejected}!@This() {
        return error.Rejected;
    }
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonParseErrorSet() void {
    _ = @sizeOf(BrokenDecoder);
}
