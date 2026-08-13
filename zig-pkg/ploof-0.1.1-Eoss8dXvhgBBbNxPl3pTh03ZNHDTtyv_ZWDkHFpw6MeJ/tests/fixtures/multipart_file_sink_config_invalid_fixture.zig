const multipart = @import("ploof_compile").multipart;

export fn forceMissingFileSinkDurability() void {
    _ = multipart.FileSink(.{ .root = "uploads" });
}
