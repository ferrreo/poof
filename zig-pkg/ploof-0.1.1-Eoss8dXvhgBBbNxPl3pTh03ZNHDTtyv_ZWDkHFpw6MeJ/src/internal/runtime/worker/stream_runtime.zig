const reactor = @import("../reactor.zig");
const worker_stream_lifecycle = @import("stream_lifecycle.zig");

pub fn handle(
    comptime RuntimeError: type,
    storage: anytype,
    io: anytype,
    completion: reactor.Completion,
    context: anytype,
    comptime callback: fn (@TypeOf(context), u16) RuntimeError!void,
) RuntimeError!void {
    const event = storage.stream_wakes.handle(io, completion) catch |problem| {
        return if (problem == error.InvalidCompletion)
            error.InvalidCompletion
        else
            error.StreamFailure;
    };
    for (event.ready.nonempty_words, 0..) |summary_word, summary_index| {
        var nonempty = summary_word;
        while (nonempty != 0) {
            const word_bit: u6 = @intCast(@ctz(nonempty));
            const word_index = summary_index * 64 + word_bit;
            var ready = event.ready.words[word_index];
            while (ready != 0) {
                const ready_bit: u6 = @intCast(@ctz(ready));
                const request_index: u16 = @intCast(word_index * 64 + ready_bit);
                try callback(context, request_index);
                ready &= ready - 1;
            }
            nonempty &= nonempty - 1;
        }
    }
}

pub fn beginStop(storage: anytype, io: anytype) worker_stream_lifecycle.Error!void {
    return switch (storage.stream_wakes.status().phase) {
        .disabled, .stopping, .stopped => {},
        .initialized, .running => {
            try storage.stream_wakes.confirmPublishersJoined();
            try storage.stream_wakes.beginStop(io);
        },
        .fatal, .failed => error.InvalidPhase,
    };
}
