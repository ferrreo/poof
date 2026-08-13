const ploof = @import("ploof_compile").ploof;

const FileHandler = struct {
    pub const ploof_multipart_endpoint = true;
    pub const definition = struct {
        pub const MultipartBodySpec = struct {
            pub const File = u8;
        };
    };
};

const file_1 = ploof.post("/upload", FileHandler{});
const file_2 = ploof.group("", .{}, .{ file_1, file_1 });
const file_4 = ploof.group("", .{}, .{ file_2, file_2 });
const file_8 = ploof.group("", .{}, .{ file_4, file_4 });
const file_16 = ploof.group("", .{}, .{ file_8, file_8 });
const file_32 = ploof.group("", .{}, .{ file_16, file_16 });
const file_64 = ploof.group("", .{}, .{ file_32, file_32 });
const file_128 = ploof.group("", .{}, .{ file_64, file_64 });
const file_256 = ploof.group("", .{}, .{ file_128, file_128 });
const file_512 = ploof.group("", .{}, .{ file_256, file_256 });
const file_513 = ploof.group("", .{}, .{ file_512, file_1 });

fn brokenApplication() type {
    return ploof.Application(.{
        .State = void,
        .routes = .{file_513},
    });
}

const BrokenApplication = brokenApplication();

export fn forceMultipartFileRouteCount() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
