const ploof = @import("ploof");

pub fn main() void {
    _ = ploof.version;
    const directory = comptime ploof.StaticDir.init("/public", ".", .{});
    _ = directory.selectPath("/app.css", "/app.css");
    const validators = ploof.Static.buildValidators(.{
        .device_major = 1,
        .device_minor = 2,
        .inode = 3,
        .size = 4,
        .mtime_seconds = 0,
        .mtime_nanoseconds = 5,
    }, 1_784_032_496) catch unreachable;
    _ = ploof.Static.evaluateRange(.get, &validators, "bytes=0-1", null);
    _ = ploof.AssetRef(.css);
    _ = ploof.Asset.mediaType(.css);
}
