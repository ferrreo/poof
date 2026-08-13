const options = @import("harness_options");
const target = @import("fuzz/targets.zig").select(options.target);

comptime {
    _ = target;
}

test {
    _ = target;
}
