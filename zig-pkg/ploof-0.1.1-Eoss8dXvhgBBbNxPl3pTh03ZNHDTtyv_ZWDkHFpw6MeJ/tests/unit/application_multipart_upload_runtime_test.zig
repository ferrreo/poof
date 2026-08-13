const std = @import("std");

const multipart = @import("../../src/multipart.zig");
const runtime_module = @import("../../src/internal/application/multipart_upload_runtime.zig");

const Sink = multipart.FileSink(.{
    .root = "uploads",
    .durability = .buffered,
});
const Spec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(Sink, multipart.required),
}, .{}));

const Mode = enum(u8) { accept, reject, fail };

const Context = struct {
    pub const ResponseType = u16;

    mode: Mode,
};

const Consumer = struct {
    pub const State = struct {
        starts: u8 = 0,
        metadata_valid: bool = false,
    };

    pub fn init(_: Consumer, _: *Context) State {
        return .{};
    }

    pub fn fileStart(
        _: Consumer,
        context: *Context,
        state: *State,
        event: Spec.FileStart,
    ) error{Denied}!Spec.FileAdmission(u16) {
        const metadata = switch (event) {
            .upload => |value| value,
        };
        state.starts += 1;
        state.metadata_valid = validMetadata(metadata);
        return switch (context.mode) {
            .accept => .{ .accept = .{
                .upload = Sink.Key.init("target") catch unreachable,
            } },
            .reject => .{ .reject = 403 },
            .fail => error.Denied,
        };
    }

    fn validMetadata(metadata: multipart.FileStart) bool {
        const filename = metadata.client_filename orelse return false;
        const media = metadata.claimed_media_type orelse return false;
        return std.mem.eql(u8, metadata.part_name, "upload") and
            metadata.occurrence == 1 and
            std.mem.eql(u8, filename.bytes, "photo.txt") and
            filename.source == .filename_star and
            std.mem.eql(u8, media.raw, "image/png") and
            std.mem.eql(u8, media.type, "image") and
            std.mem.eql(u8, media.subtype, "png");
    }
};

const Handler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = Spec;
    };
    pub const MultipartConsumer = Consumer;
    pub const MultipartState = Consumer.State;
    pub const handler_fn = Consumer{};
};

const Source = struct {
    runtime: Sink.Runtime = .{
        .root = multipart.FileHandle.init(7),
        .generator = undefined,
    },

    pub fn get(self: *Source, comptime Requested: type) *Requested.Runtime {
        if (Requested == Sink) return &self.runtime;
        unreachable;
    }
};

const Runtime = runtime_module.Runtime(Handler);
const prefix = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; " ++
    "filename*=UTF-8''photo.txt\r\n" ++
    "Content-Type: image/png\r\n\r\n";

const GuardSpec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{}));

const GuardConsumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: GuardConsumer,
        _: *Context,
        _: *State,
        _: GuardSpec.FileStart,
    ) GuardSpec.FileAdmission(u16) {
        return .{ .accept = .{ .upload = {} } };
    }
};

const GuardHandler = struct {
    pub const definition = struct {
        pub const MultipartBodySpec = GuardSpec;
    };
    pub const MultipartConsumer = GuardConsumer;
    pub const MultipartState = GuardConsumer.State;
    pub const handler_fn = GuardConsumer{};
};

const GuardRuntime = runtime_module.Runtime(GuardHandler);
const guard_prefix = "--C\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=file.txt\r\n\r\n";
const complete_body = guard_prefix ++ "data\r\n--C--";
const malformed_trailing_body = guard_prefix ++
    "data\r\n--C\r\nmalformed-header\r\n\r\n";

test "accepted file start exposes typed metadata and pauses on sink request" {
    var context = Context{ .mode = .accept };
    var source = Source{};
    var runtime: Runtime = undefined;
    try runtime.initInPlace("B", &context, &source);

    const progress = try runtime.feedProgress(prefix);
    try std.testing.expectEqual(prefix.len, progress.consumed);
    try std.testing.expectEqual(.paused, progress.flow);
    try std.testing.expectEqual(@as(u8, 1), (try runtime.state()).starts);
    try std.testing.expect((try runtime.state()).metadata_valid);
    try std.testing.expectEqual(runtime_module.TerminalSource.none, runtime.terminalSource());

    const submission = (try runtime.peekSubmission()).?;
    try std.testing.expectEqual(.lifecycle, submission.lane);
    try std.testing.expect(submission.request == .open);

    var moved = runtime;
    try std.testing.expectError(error.RuntimeMoved, moved.peekSubmission());
    try std.testing.expectEqual(runtime_module.TerminalSource.fatal, moved.terminalSource());
}

test "file-start rejection is explicit and leaves no sink submission" {
    var context = Context{ .mode = .reject };
    var source = Source{};
    var runtime: Runtime = undefined;
    try runtime.initInPlace("B", &context, &source);

    try std.testing.expectError(error.FileRejected, runtime.feedProgress(prefix));
    try std.testing.expectEqual(runtime_module.TerminalSource.rejection, runtime.terminalSource());
    try std.testing.expectEqual(@as(u16, 403), runtime.rejection().?.*);
    try std.testing.expect((try runtime.peekSubmission()) == null);
    try std.testing.expectEqual(.complete, try runtime.startAbort(null));
}

test "file-start application error preserves provenance and starts no sink" {
    var context = Context{ .mode = .fail };
    var source = Source{};
    var runtime: Runtime = undefined;
    try runtime.initInPlace("B", &context, &source);

    try std.testing.expectError(error.Denied, runtime.feedProgress(prefix));
    try std.testing.expectEqual(
        runtime_module.TerminalSource.application,
        runtime.terminalSource(),
    );
    try std.testing.expect(runtime.rejection() == null);
    try std.testing.expect((try runtime.peekSubmission()) == null);
    try std.testing.expectEqual(.complete, try runtime.startAbort(null));
}

test "commit requires complete body and completed parser calls are controlled" {
    var context = Context{ .mode = .accept };
    var source = struct {}{};
    var runtime: GuardRuntime = undefined;
    try runtime.initInPlace("C", &context, &source);

    try std.testing.expectError(error.Terminal, runtime.markCommitReady());
    try std.testing.expectEqual(runtime_module.TerminalSource.none, runtime.terminalSource());

    const fed = try runtime.feedProgress(complete_body);
    try std.testing.expectEqual(complete_body.len, fed.consumed);
    try std.testing.expectEqual(.ready, fed.flow);
    try std.testing.expectEqual(.complete, (try runtime.finishProgress()).flow);
    try std.testing.expectEqual(.complete, (try runtime.resumeParser()).flow);

    try std.testing.expectError(error.Terminal, runtime.feedProgress(""));
    try std.testing.expectError(error.Terminal, runtime.feedProgress("trailing"));
    try std.testing.expectError(error.Terminal, runtime.finishProgress());
    try std.testing.expectEqual(runtime_module.TerminalSource.none, runtime.terminalSource());
    try runtime.markCommitReady();
}

test "malformed trailing part seals parser and refuses commit" {
    var context = Context{ .mode = .accept };
    var source = struct {}{};
    var runtime: GuardRuntime = undefined;
    try runtime.initInPlace("C", &context, &source);

    try std.testing.expectError(error.Malformed, runtime.feedProgress(malformed_trailing_body));
    try std.testing.expectEqual(runtime_module.TerminalSource.parser, runtime.terminalSource());
    try std.testing.expectError(error.Terminal, runtime.markCommitReady());
    try std.testing.expectError(error.Terminal, runtime.feedProgress(""));
    try std.testing.expectError(error.Terminal, runtime.finishProgress());
    try std.testing.expectError(error.Terminal, runtime.resumeParser());
}
