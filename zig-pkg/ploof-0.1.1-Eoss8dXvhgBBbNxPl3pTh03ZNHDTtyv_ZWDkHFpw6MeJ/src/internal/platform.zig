const std = @import("std");
const builtin = @import("builtin");
const x86 = std.Target.x86;

pub fn requireSupported() void {
    if (builtin.os.tag != .linux) {
        @compileError("Ploof requires Linux");
    }

    if (builtin.cpu.arch != .x86_64) {
        @compileError("Ploof requires x86_64");
    }

    const required = requiredCpuFeatures();
    if (!builtin.target.cpu.features.isSuperSetOf(required)) {
        @compileError("Ploof requires x86-64-v3 or newer");
    }
}

fn requiredCpuFeatures() std.Target.Cpu.Feature.Set {
    var features = x86.featureSet(&.{
        .@"64bit",
        .avx2,
        .bmi,
        .bmi2,
        .cmov,
        .cx16,
        .f16c,
        .fma,
        .fxsr,
        .lzcnt,
        .mmx,
        .movbe,
        .popcnt,
        .sahf,
        .x87,
        .xsave,
    });
    features.populateDependencies(&x86.all_features);
    return features;
}

fn modelFeatures(model: *const std.Target.Cpu.Model) std.Target.Cpu.Feature.Set {
    var features = model.features;
    features.populateDependencies(&x86.all_features);
    return features;
}

test "accepts Intel, AMD, and x86-64-v4 feature sets" {
    try std.testing.expect(modelFeatures(&x86.cpu.haswell).isSuperSetOf(requiredCpuFeatures()));
    try std.testing.expect(modelFeatures(&x86.cpu.znver1).isSuperSetOf(requiredCpuFeatures()));
    try std.testing.expect(modelFeatures(&x86.cpu.x86_64_v4).isSuperSetOf(requiredCpuFeatures()));
}

test "rejects x86-64-v2 feature set" {
    const features = modelFeatures(&x86.cpu.x86_64_v2);
    try std.testing.expect(!features.isSuperSetOf(requiredCpuFeatures()));
}
