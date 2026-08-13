const multipart_fuzz = @import("internal/multipart/fuzz_check.zig");

test {
    _ = multipart_fuzz;
}
