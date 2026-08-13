const ploof = @import("ploof_compile").ploof;

const Broken = struct {
    comptime value: u8 = 1,
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonDecodeComptimeField() void {
    _ = @sizeOf(BrokenDecoder);
}
