const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    pub const jsonParse = 1;
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonParseNonFunction() void {
    _ = @sizeOf(BrokenDecoder);
}
