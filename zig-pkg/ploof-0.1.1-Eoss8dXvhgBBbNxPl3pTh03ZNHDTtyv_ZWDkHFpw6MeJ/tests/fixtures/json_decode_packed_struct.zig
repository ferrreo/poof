const ploof = @import("ploof_compile").ploof;

const Broken = packed struct {
    value: u8,
};

const BrokenDecoder = @TypeOf(ploof.Json.typed(Broken, .{}));

export fn forceJsonDecodePackedStruct() void {
    _ = @sizeOf(BrokenDecoder);
}
