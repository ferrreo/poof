const std = @import("std");
const linux = std.os.linux;

/// Small allocation-free Linux mutex for infrequent server control calls.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(mutex: *Mutex) void {
        if (mutex.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (mutex.state.swap(2, .acquire) != 0) {
            switch (linux.errno(linux.futex_4arg(
                &mutex.state.raw,
                .{ .cmd = .WAIT, .private = true },
                2,
                null,
            ))) {
                .SUCCESS, .AGAIN, .INTR => {},
                else => @panic("server mutex futex wait failed"),
            }
        }
    }

    pub fn unlock(mutex: *Mutex) void {
        if (mutex.state.fetchSub(1, .release) == 1) return;
        mutex.state.store(0, .release);
        switch (linux.errno(linux.futex_3arg(
            &mutex.state.raw,
            .{ .cmd = .WAKE, .private = true },
            1,
        ))) {
            .SUCCESS => {},
            else => @panic("server mutex futex wake failed"),
        }
    }
};

test "server mutex serializes concurrent control calls" {
    const Harness = struct {
        mutex: *Mutex,
        value: *u32,

        fn run(harness: @This()) void {
            for (0..1_000) |_| {
                harness.mutex.lock();
                harness.value.* += 1;
                harness.mutex.unlock();
            }
        }
    };
    var mutex = Mutex{};
    var value: u32 = 0;
    const harness = Harness{ .mutex = &mutex, .value = &value };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Harness.run, .{harness});
    for (&threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 4_000), value);
}
