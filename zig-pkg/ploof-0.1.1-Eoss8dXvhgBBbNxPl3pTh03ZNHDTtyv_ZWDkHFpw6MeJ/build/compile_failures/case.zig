pub const CompileFailureCase = struct {
    name: []const u8,
    file: []const u8,
    message: []const u8,
    root: []const u8 = "tests/fixtures/",
};
