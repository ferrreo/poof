const multipart = @import("ploof_compile").multipart;

export fn forceFileSinkStorageKeyMaximumOverflow() void {
    _ = multipart.FileSink(.{
        .root = "uploads",
        .storage_key_bytes_max = multipart.storage_key_bytes_hard_max + 1,
        .durability = .buffered,
    });
}
