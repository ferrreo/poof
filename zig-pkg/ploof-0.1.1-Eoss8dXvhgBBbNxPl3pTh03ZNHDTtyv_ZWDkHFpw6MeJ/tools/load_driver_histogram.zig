const std = @import("std");

pub const bucket_count: usize = 65;

pub const Histogram = struct {
    buckets: [bucket_count]u64 = @splat(0),
    samples: u64 = 0,

    pub fn record(self: *Histogram, value_ns: u64) void {
        self.buckets[bucket(value_ns)] += 1;
        self.samples += 1;
    }

    pub fn percentile(self: *const Histogram, numerator: u16, denominator: u16) u64 {
        std.debug.assert(numerator > 0 and numerator <= denominator);
        if (self.samples == 0) return 0;
        const product = self.samples * numerator;
        const target = (product + denominator - 1) / denominator;
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            cumulative += count;
            if (cumulative >= target) return upperBound(index);
        }
        unreachable;
    }
};

fn bucket(value_ns: u64) usize {
    if (value_ns == 0) return 0;
    return @as(usize, 64 - @clz(value_ns));
}

fn upperBound(index: usize) u64 {
    if (index == 0) return 0;
    if (index == 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(index)) - 1;
}

test "histogram reports bounded percentile upper bounds" {
    var histogram = Histogram{};
    for (1..1001) |value| histogram.record(value);
    try std.testing.expectEqual(@as(u64, 511), histogram.percentile(50, 100));
    try std.testing.expectEqual(@as(u64, 1023), histogram.percentile(95, 100));
    try std.testing.expectEqual(@as(u64, 1023), histogram.percentile(99, 100));
    try std.testing.expectEqual(@as(u64, 1023), histogram.percentile(999, 1000));
}

test "histogram covers zero and maximum without overflow" {
    var histogram = Histogram{};
    histogram.record(0);
    histogram.record(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), histogram.percentile(1, 2));
    try std.testing.expectEqual(std.math.maxInt(u64), histogram.percentile(2, 2));
}
