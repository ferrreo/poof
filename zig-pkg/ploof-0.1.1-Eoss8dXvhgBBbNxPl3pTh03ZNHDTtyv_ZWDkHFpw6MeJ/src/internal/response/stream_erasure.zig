const std = @import("std");
const response_stream = @import("../../response/stream.zig");
const producer_compile = @import("stream_producer_compile.zig");

pub const DriveError = response_stream.PollError || error{
    OutputTooSmall,
    EmptyProgress,
    ProgressOutOfBounds,
    ExactOverrun,
    ExactUnderrun,
    ExactTrailers,
    LengthOverflow,
    InvalidLifecycle,
};

pub const LifecycleError = error{InvalidLifecycle};

pub const Phase = enum(u8) {
    polling,
    canary,
    failed,
    done,
    aborted,
    joined,
};

const PollFn = *const fn (
    *anyopaque,
    []u8,
    response_stream.Wake,
) response_stream.PollError!response_stream.PollResult;
const LifecycleFn = *const fn (*anyopaque) void;

const Window = struct {
    length: usize,
    exact_boundary: bool,
    canary: bool,
};

/// Fixed-size producer erasure owned by request workspace. No pointer to source is retained.
pub fn Erased(
    comptime requested_bytes_max: usize,
    comptime requested_alignment_max: comptime_int,
) type {
    const bytes_max = comptime validateBytes(requested_bytes_max);
    const alignment_max = comptime validateAlignment(requested_alignment_max);

    return struct {
        const Self = @This();

        producer_bytes: [bytes_max]u8 align(alignment_max) = undefined,
        poll_fn: PollFn,
        abort_fn: LifecycleFn,
        join_fn: LifecycleFn,
        framing: response_stream.Framing,
        trailer_names: []const []const u8,
        produced: u64,
        poll_started: bool,
        state: Phase,

        /// Copies a safely relocatable producer. Keep this address stable after its first poll.
        pub fn init(self: *Self, stream: anytype) void {
            const Descriptor = @TypeOf(stream);
            const Producer = comptime descriptorProducer(Descriptor);
            comptime producer_compile.validateWorkspace(Producer, bytes_max, alignment_max);

            self.* = .{
                .producer_bytes = undefined,
                .poll_fn = Callbacks(Producer).poll,
                .abort_fn = Callbacks(Producer).abort,
                .join_fn = Callbacks(Producer).join,
                .framing = stream.framing,
                .trailer_names = stream.trailer_names,
                .produced = 0,
                .poll_started = false,
                .state = initialPhase(stream.framing),
            };
            producerPointer(Producer, @ptrCast(&self.producer_bytes)).* = stream.producer;
        }

        /// Polls once with a nonempty bounded slice and validates the closed result protocol.
        pub fn poll(
            self: *Self,
            output: []u8,
            wake: response_stream.Wake,
        ) DriveError!response_stream.PollResult {
            if (self.state != .polling and self.state != .canary) {
                return error.InvalidLifecycle;
            }
            self.poll_started = true;
            const window = try self.outputWindow(output);
            const result = self.poll_fn(
                @ptrCast(&self.producer_bytes),
                output[0..window.length],
                wake,
            ) catch |problem| {
                self.state = .failed;
                return problem;
            };
            return self.acceptResult(result, window);
        }

        /// Cancels an active or failed producer once. `join` is the only valid next operation.
        pub fn abort(self: *Self) LifecycleError!void {
            switch (self.state) {
                .polling, .canary, .failed => {},
                else => return error.InvalidLifecycle,
            }
            self.abort_fn(@ptrCast(&self.producer_bytes));
            self.state = .aborted;
        }

        /// Joins a producer whose representation is suppressed before its first poll.
        pub fn suppress(self: *Self) LifecycleError!void {
            if (self.poll_started or
                (self.state != .polling and self.state != .canary))
            {
                return error.InvalidLifecycle;
            }
            self.finishJoin();
        }

        /// Joins once after normal completion or abort.
        pub fn join(self: *Self) LifecycleError!void {
            if (self.state != .done and self.state != .aborted) {
                return error.InvalidLifecycle;
            }
            self.finishJoin();
        }

        fn finishJoin(self: *Self) void {
            self.join_fn(@ptrCast(&self.producer_bytes));
            std.crypto.secureZero(u8, &self.producer_bytes);
            self.trailer_names = &.{};
            self.state = .joined;
        }

        pub fn phase(self: *const Self) Phase {
            return self.state;
        }

        pub fn producedBytes(self: *const Self) u64 {
            return self.produced;
        }

        pub fn trailerNames(self: *const Self) []const []const u8 {
            return self.trailer_names;
        }

        fn outputWindow(self: *const Self, output: []u8) DriveError!Window {
            if (output.len == 0) return error.OutputTooSmall;
            if (self.state == .canary) {
                return .{ .length = 1, .exact_boundary = true, .canary = true };
            }
            return switch (self.framing) {
                .unknown => .{
                    .length = output.len,
                    .exact_boundary = false,
                    .canary = false,
                },
                .exact => |expected| exactWindow(expected, self.produced, output.len),
            };
        }

        fn acceptResult(
            self: *Self,
            result: response_stream.PollResult,
            window: Window,
        ) DriveError!response_stream.PollResult {
            return switch (result) {
                .progress => |count| self.acceptProgress(count, window),
                .done => |fields| self.acceptDone(fields),
                .pending => .pending,
            };
        }

        fn acceptProgress(
            self: *Self,
            count: usize,
            window: Window,
        ) DriveError!response_stream.PollResult {
            if (count == 0) return self.fail(error.EmptyProgress);
            if (window.canary) return self.fail(error.ExactOverrun);
            if (count > window.length) {
                if (window.exact_boundary) return self.fail(error.ExactOverrun);
                return self.fail(error.ProgressOutOfBounds);
            }
            const count_u64: u64 = @intCast(count);
            self.produced = std.math.add(u64, self.produced, count_u64) catch {
                return self.fail(error.LengthOverflow);
            };
            switch (self.framing) {
                .unknown => {},
                .exact => |expected| {
                    if (self.produced == expected) self.state = .canary;
                },
            }
            return .{ .progress = count };
        }

        fn acceptDone(
            self: *Self,
            fields: []const response_stream.TrailerField,
        ) DriveError!response_stream.PollResult {
            switch (self.framing) {
                .unknown => {},
                .exact => {
                    if (self.state != .canary) return self.fail(error.ExactUnderrun);
                    if (fields.len != 0) return self.fail(error.ExactTrailers);
                },
            }
            self.state = .done;
            return .{ .done = fields };
        }

        fn fail(self: *Self, problem: DriveError) DriveError {
            self.state = .failed;
            return problem;
        }
    };
}

fn exactWindow(expected: u64, produced: u64, output_len: usize) Window {
    std.debug.assert(produced < expected);
    const remaining = expected - produced;
    const available: u64 = @intCast(output_len);
    return .{
        .length = @intCast(@min(remaining, available)),
        .exact_boundary = remaining <= available,
        .canary = false,
    };
}

fn initialPhase(framing: response_stream.Framing) Phase {
    return switch (framing) {
        .unknown => .polling,
        .exact => |expected| if (expected == 0) .canary else .polling,
    };
}

fn validateBytes(comptime bytes: usize) usize {
    if (bytes == 0) {
        @compileError("PLOOF-E3100 stream producer workspace must contain at least one byte");
    }
    return bytes;
}

fn validateAlignment(comptime alignment: comptime_int) comptime_int {
    if (alignment <= 0 or alignment & (alignment - 1) != 0) {
        @compileError("PLOOF-E3101 stream producer workspace alignment must be a power of two");
    }
    return alignment;
}

fn descriptorProducer(comptime Descriptor: type) type {
    if (@typeInfo(Descriptor) != .@"struct" or !@hasDecl(Descriptor, "ProducerType")) {
        @compileError("PLOOF-E3102 invalid streaming response descriptor");
    }
    const Producer = Descriptor.ProducerType;
    if (Descriptor != response_stream.Response(Producer)) {
        @compileError("PLOOF-E3102 invalid streaming response descriptor");
    }
    return Producer;
}

fn producerPointer(comptime Producer: type, context: *anyopaque) *Producer {
    return @ptrCast(@alignCast(context));
}

fn Callbacks(comptime Producer: type) type {
    return struct {
        fn poll(
            context: *anyopaque,
            output: []u8,
            wake: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            return producerPointer(Producer, context).poll(output, wake);
        }

        fn abort(context: *anyopaque) void {
            if (@hasDecl(Producer, "abort")) producerPointer(Producer, context).abort();
        }

        fn join(context: *anyopaque) void {
            if (@hasDecl(Producer, "join")) producerPointer(Producer, context).join();
        }
    };
}

const WakeState = struct {
    notifications: u32 = 0,
    generation_sum: u64 = 0,

    fn notify(context: *anyopaque, generation: u64) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.notifications += 1;
        self.generation_sum += generation;
    }
};

fn wakeFor(state: *WakeState) response_stream.Wake {
    return response_stream.Wake.init(state, 11, WakeState.notify);
}

const Step = union(enum) {
    progress: usize,
    done: []const response_stream.TrailerField,
    pending,
    fail,
};

const ScriptProducer = struct {
    steps: []const Step,
    index: usize = 0,
    lengths: *[8]usize,

    pub fn poll(
        self: *@This(),
        output: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.lengths[self.index] = output.len;
        const step = self.steps[self.index];
        self.index += 1;
        return switch (step) {
            .progress => |count| .{ .progress = count },
            .done => |fields| .{ .done = fields },
            .pending => .pending,
            .fail => error.ProducerFailed,
        };
    }
};

const LifecycleCounts = struct { polls: u8 = 0, aborts: u8 = 0, joins: u8 = 0 };

const LifecycleProducer = struct {
    counts: *LifecycleCounts,
    secret: [8]u8 = [_]u8{0xa5} ** 8,

    pub fn poll(
        self: *@This(),
        _: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        self.counts.polls += 1;
        return .pending;
    }

    pub fn abort(self: *@This()) void {
        self.counts.aborts += 1;
    }

    pub fn join(self: *@This()) void {
        self.counts.joins += 1;
    }
};

fn expectSuppression(framing: response_stream.Framing, poll_first: bool) !void {
    const declarations = [_][]const u8{"digest"};
    const trailer_names: []const []const u8 = switch (framing) {
        .unknown => &declarations,
        .exact => &.{},
    };
    var counts = LifecycleCounts{};
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.Response(LifecycleProducer){
        .framing = framing,
        .trailer_names = trailer_names,
        .producer = .{ .counts = &counts },
    });
    var wakes = WakeState{};
    var output: [1]u8 = undefined;

    if (poll_first) {
        try std.testing.expect((try erased.poll(&output, wakeFor(&wakes))) == .pending);
        try std.testing.expectError(error.InvalidLifecycle, erased.suppress());
        try erased.abort();
        try erased.join();
    } else {
        try erased.suppress();
    }
    try std.testing.expectEqual(LifecycleCounts{
        .polls = @intFromBool(poll_first),
        .aborts = @intFromBool(poll_first),
        .joins = 1,
    }, counts);
    try std.testing.expectEqual(Phase.joined, erased.phase());
    try std.testing.expectEqual(@as(u64, 0), erased.producedBytes());
    try std.testing.expectEqual(@as(usize, 0), erased.trailerNames().len);
    for (erased.producer_bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.InvalidLifecycle, erased.suppress());
    try std.testing.expectError(error.InvalidLifecycle, erased.abort());
    try std.testing.expectError(error.InvalidLifecycle, erased.join());
    try std.testing.expectError(
        error.InvalidLifecycle,
        erased.poll(&output, wakeFor(&wakes)),
    );
}

test "producer value is copied into aligned workspace" {
    const Producer = struct {
        value: u8,
        source_address: usize,
        polled_address: *usize,

        pub fn poll(
            self: *@This(),
            output: []u8,
            _: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            self.polled_address.* = @intFromPtr(self);
            output[0] = self.value;
            return .{ .progress = 1 };
        }
    };

    var polled_address: usize = 0;
    var source = Producer{ .value = 7, .source_address = 0, .polled_address = &polled_address };
    source.source_address = @intFromPtr(&source);
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.unknown(source, &.{}));
    source.value = 99;

    var output: [4]u8 = undefined;
    var wakes = WakeState{};
    const result = try erased.poll(&output, wakeFor(&wakes));
    try std.testing.expectEqual(@as(usize, 1), result.progress);
    try std.testing.expectEqual(@as(u8, 7), output[0]);
    try std.testing.expectEqual(@as(u64, 1), erased.producedBytes());
    try std.testing.expect(polled_address != source.source_address);
}

test "progress must be nonzero and within unknown output" {
    var wakes = WakeState{};
    var output: [4]u8 = undefined;

    var zero_lengths = [_]usize{0} ** 8;
    const zero_steps = [_]Step{.{ .progress = 0 }};
    var zero: Erased(64, 16) = undefined;
    zero.init(response_stream.unknown(
        ScriptProducer{ .steps = &zero_steps, .lengths = &zero_lengths },
        &.{},
    ));
    try std.testing.expectError(error.EmptyProgress, zero.poll(&output, wakeFor(&wakes)));

    var large_lengths = [_]usize{0} ** 8;
    const large_steps = [_]Step{.{ .progress = 5 }};
    var large: Erased(64, 16) = undefined;
    large.init(response_stream.unknown(
        ScriptProducer{ .steps = &large_steps, .lengths = &large_lengths },
        &.{},
    ));
    try std.testing.expectError(
        error.ProgressOutOfBounds,
        large.poll(&output, wakeFor(&wakes)),
    );

    var overflow_lengths = [_]usize{0} ** 8;
    const overflow_steps = [_]Step{.{ .progress = 1 }};
    var overflow: Erased(64, 16) = undefined;
    overflow.init(response_stream.unknown(
        ScriptProducer{ .steps = &overflow_steps, .lengths = &overflow_lengths },
        &.{},
    ));
    overflow.produced = std.math.maxInt(u64);
    try std.testing.expectError(
        error.LengthOverflow,
        overflow.poll(&output, wakeFor(&wakes)),
    );
}

test "pending retains live wake and ordered borrowed trailers" {
    const Producer = struct {
        fields: []const response_stream.TrailerField,
        pending: bool = true,

        pub fn poll(
            self: *@This(),
            _: []u8,
            wake: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            if (self.pending) {
                self.pending = false;
                wake.notify();
                return .pending;
            }
            return .{ .done = self.fields };
        }
    };

    const fields = [_]response_stream.TrailerField{
        .{ .name = "digest", .value = "first" },
        .{ .name = "x-stats", .value = "second" },
    };
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.unknown(
        Producer{ .fields = &fields },
        &.{ "digest", "x-stats" },
    ));
    var wakes = WakeState{};
    var output: [4]u8 = undefined;

    try std.testing.expectEqualStrings("digest", erased.trailerNames()[0]);
    try std.testing.expectEqualStrings("x-stats", erased.trailerNames()[1]);
    try std.testing.expect((try erased.poll(&output, wakeFor(&wakes))) == .pending);
    try std.testing.expectEqual(@as(u32, 1), wakes.notifications);
    const result = try erased.poll(&output, wakeFor(&wakes));
    try std.testing.expectEqualStrings("digest", result.done[0].name);
    try std.testing.expectEqualStrings("x-stats", result.done[1].name);
    try erased.join();
    try std.testing.expectEqual(@as(usize, 0), erased.trailerNames().len);
}

test "producer failure requires abort before join" {
    var lengths = [_]usize{0} ** 8;
    const steps = [_]Step{.fail};
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.unknown(
        ScriptProducer{ .steps = &steps, .lengths = &lengths },
        &.{},
    ));
    var wakes = WakeState{};
    var output: [4]u8 = undefined;

    try std.testing.expectError(
        error.ProducerFailed,
        erased.poll(&output, wakeFor(&wakes)),
    );
    try std.testing.expectEqual(Phase.failed, erased.phase());
    try std.testing.expectError(error.InvalidLifecycle, erased.join());
    try erased.abort();
    try erased.join();
    try std.testing.expectEqual(Phase.joined, erased.phase());
}

test "abort and join callbacks run once in order" {
    const Producer = struct {
        trace: *[2]u8,
        count: *usize,

        pub fn poll(
            _: *@This(),
            _: []u8,
            _: response_stream.Wake,
        ) response_stream.PollError!response_stream.PollResult {
            return .pending;
        }

        pub fn abort(self: *@This()) void {
            self.trace[self.count.*] = 1;
            self.count.* += 1;
        }

        pub fn join(self: *@This()) void {
            self.trace[self.count.*] = 2;
            self.count.* += 1;
        }
    };

    var trace = [_]u8{ 0, 0 };
    var count: usize = 0;
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.unknown(
        Producer{ .trace = &trace, .count = &count },
        &.{},
    ));
    var wakes = WakeState{};
    var output: [4]u8 = undefined;

    try erased.abort();
    try std.testing.expectError(error.InvalidLifecycle, erased.abort());
    try std.testing.expectError(
        error.InvalidLifecycle,
        erased.poll(&output, wakeFor(&wakes)),
    );
    try erased.join();
    try std.testing.expectError(error.InvalidLifecycle, erased.join());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &trace);
    for (erased.producer_bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "suppression joins unpolled producer and rejects every later transition" {
    const framings = [_]response_stream.Framing{
        .unknown,
        .{ .exact = 0 },
        .{ .exact = 9 },
    };
    for (framings) |framing| try expectSuppression(framing, false);
    try expectSuppression(.unknown, true);
}

test "suppression lifecycle fuzz" {
    try std.testing.fuzz({}, fuzzSuppression, .{ .corpus = &suppression_fuzz_corpus });
}

fn fuzzSuppression(_: void, smith: *std.testing.Smith) !void {
    const selector = smith.value(u8) % 3;
    const length = smith.value(u8);
    const framing: response_stream.Framing = switch (selector) {
        0 => .unknown,
        1 => .{ .exact = 0 },
        else => .{ .exact = length },
    };
    try expectSuppression(framing, smith.value(u8) & 1 != 0);
}

const suppression_fuzz_corpus = [_][]const u8{
    "\x00\x00\x00",
    "\x01\x00\x00",
    "\x02\x09\x00",
    "\x00\x00\x01",
};

test "exact stream counts progress then requires done canary" {
    var lengths = [_]usize{0} ** 8;
    const steps = [_]Step{
        .{ .progress = 2 },
        .{ .progress = 1 },
        .{ .done = &.{} },
    };
    var erased: Erased(64, 16) = undefined;
    erased.init(response_stream.exact(
        3,
        ScriptProducer{ .steps = &steps, .lengths = &lengths },
    ));
    var wakes = WakeState{};
    var output: [8]u8 = undefined;

    const first = try erased.poll(&output, wakeFor(&wakes));
    const second = try erased.poll(&output, wakeFor(&wakes));
    try std.testing.expectEqual(@as(usize, 2), first.progress);
    try std.testing.expectEqual(@as(usize, 1), second.progress);
    try std.testing.expectEqual(@as(u64, 3), erased.producedBytes());
    try std.testing.expectEqual(Phase.canary, erased.phase());
    const terminal = try erased.poll(&output, wakeFor(&wakes));
    try std.testing.expectEqual(@as(usize, 0), terminal.done.len);
    try std.testing.expectEqualSlices(usize, &.{ 3, 1, 1 }, lengths[0..3]);
    try erased.join();
}

test "exact stream rejects overrun underrun and trailers" {
    var wakes = WakeState{};
    var output: [8]u8 = undefined;

    var over_lengths = [_]usize{0} ** 8;
    const over_steps = [_]Step{.{ .progress = 3 }};
    var over: Erased(64, 16) = undefined;
    over.init(response_stream.exact(
        2,
        ScriptProducer{ .steps = &over_steps, .lengths = &over_lengths },
    ));
    try std.testing.expectError(error.ExactOverrun, over.poll(&output, wakeFor(&wakes)));

    var under_lengths = [_]usize{0} ** 8;
    const under_steps = [_]Step{.{ .done = &.{} }};
    var under: Erased(64, 16) = undefined;
    under.init(response_stream.exact(
        2,
        ScriptProducer{ .steps = &under_steps, .lengths = &under_lengths },
    ));
    try std.testing.expectError(error.ExactUnderrun, under.poll(&output, wakeFor(&wakes)));

    const fields = [_]response_stream.TrailerField{.{ .name = "digest", .value = "x" }};
    var trailer_lengths = [_]usize{0} ** 8;
    const trailer_steps = [_]Step{.{ .done = &fields }};
    var trailers: Erased(64, 16) = undefined;
    trailers.init(response_stream.exact(
        0,
        ScriptProducer{ .steps = &trailer_steps, .lengths = &trailer_lengths },
    ));
    try std.testing.expectError(
        error.ExactTrailers,
        trailers.poll(&output, wakeFor(&wakes)),
    );
}

test "exact canary remains live across pending and detects progress" {
    var wakes = WakeState{};
    var output: [8]u8 = undefined;

    var pending_lengths = [_]usize{0} ** 8;
    const pending_steps = [_]Step{
        .{ .progress = 1 },
        .pending,
        .{ .done = &.{} },
    };
    var pending: Erased(64, 16) = undefined;
    pending.init(response_stream.exact(
        1,
        ScriptProducer{ .steps = &pending_steps, .lengths = &pending_lengths },
    ));
    _ = try pending.poll(&output, wakeFor(&wakes));
    try std.testing.expect((try pending.poll(&output, wakeFor(&wakes))) == .pending);
    try std.testing.expectEqual(Phase.canary, pending.phase());
    _ = try pending.poll(&output, wakeFor(&wakes));
    try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, pending_lengths[0..3]);

    var over_lengths = [_]usize{0} ** 8;
    const over_steps = [_]Step{ .{ .progress = 1 }, .{ .progress = 1 } };
    var over: Erased(64, 16) = undefined;
    over.init(response_stream.exact(
        1,
        ScriptProducer{ .steps = &over_steps, .lengths = &over_lengths },
    ));
    _ = try over.poll(&output, wakeFor(&wakes));
    try std.testing.expectError(error.ExactOverrun, over.poll(&output, wakeFor(&wakes)));
}

test {
    std.testing.refAllDecls(@This());
}
