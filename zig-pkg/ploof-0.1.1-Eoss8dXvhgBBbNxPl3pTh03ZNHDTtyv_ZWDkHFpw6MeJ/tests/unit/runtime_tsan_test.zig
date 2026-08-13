const std = @import("std");

const access_log = @import("../../src/access_log.zig");
const application = @import("../../src/application.zig");

test {
    _ = @import("gzip_runtime_tsan_test.zig");
    _ = @import("json_parse_hook_stack_test.zig");
    _ = @import("../../src/lifecycle.zig");
    _ = @import("../../src/metrics.zig");
    _ = @import("access_logger_test.zig");
    _ = @import("server_metrics_claim_race_test.zig");
}

test "SPSC access ring remains ordered under producer-consumer pressure" {
    const attempts: u64 = 100_000;
    const Ring = access_log.Ring(256);
    const State = struct {
        ring: Ring = .{},
        producer_done: std.atomic.Value(bool) = .init(false),
        produced: u64 = 0,
        consumed: u64 = 0,
        ordered: bool = true,

        fn produce(state: *@This()) void {
            for (1..attempts + 1) |sequence| {
                if (state.ring.push(event(sequence))) state.produced += 1;
            }
            state.producer_done.store(true, .release);
        }

        fn consume(state: *@This()) void {
            var previous: u64 = 0;
            while (!state.producer_done.load(.acquire) or state.ring.count() != 0) {
                const next = state.ring.pop() orelse {
                    std.Thread.yield() catch {};
                    continue;
                };
                state.ordered = state.ordered and next.duration_ns > previous;
                previous = next.duration_ns;
                state.consumed += 1;
            }
        }

        fn event(sequence: u64) access_log.AccessEvent {
            return access_log.AccessEvent.init(
                .get,
                0,
                .{
                    .status = .ok,
                    .mapped_error = false,
                    .transport = application.TransportOutcome.completed,
                },
                sequence,
                .{},
            );
        }
    };

    var state = State{};
    const producer = try std.Thread.spawn(.{}, State.produce, .{&state});
    const consumer = try std.Thread.spawn(.{}, State.consume, .{&state});
    producer.join();
    consumer.join();
    try std.testing.expect(state.ordered);
    try std.testing.expectEqual(state.produced, state.consumed);
    try std.testing.expectEqual(attempts, state.produced + state.ring.dropped());
}
