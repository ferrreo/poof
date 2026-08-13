const config = @import("../config.zig");
const gzip_encoder = @import("../gzip/encoder.zig");

pub fn Configuration(comptime App: type, comptime limits: config.Limits) type {
    const encoded_bytes: u32 = if (@hasDecl(App, "html_encoded_bytes_max"))
        App.html_encoded_bytes_max
    else
        0;
    const json_scratch_bytes: u32 = if (@hasDecl(App, "html_json_scratch_bytes_max"))
        App.html_json_scratch_bytes_max
    else
        0;
    comptime validateChunkCapacity(App, limits, encoded_bytes);
    return struct {
        pub const encoded_bytes_max = encoded_bytes;
        pub const json_scratch_bytes_max = json_scratch_bytes;
    };
}

fn validateChunkCapacity(
    comptime App: type,
    comptime limits: config.Limits,
    comptime encoded_bytes: u32,
) void {
    if (encoded_bytes == 0) return;
    const source = chunksRequired(encoded_bytes);
    const gzip_enabled = @hasDecl(App, "response_gzip_enabled") and
        App.response_gzip_enabled;
    const destination = if (gzip_enabled) destination: {
        const bound = gzip_encoder.bound(encoded_bytes) catch {
            @compileError("HTML response gzip bound exceeds address space");
        };
        break :destination chunksRequired(bound);
    } else 0;
    if (source + destination > limits.response_chunk_count) {
        @compileError(
            "response chunk pool cannot hold maximum HTML response and gzip destination",
        );
    }
}

fn chunksRequired(comptime bytes: anytype) u64 {
    return (@as(u64, @intCast(bytes)) + config.response_chunk_bytes - 1) /
        config.response_chunk_bytes;
}
