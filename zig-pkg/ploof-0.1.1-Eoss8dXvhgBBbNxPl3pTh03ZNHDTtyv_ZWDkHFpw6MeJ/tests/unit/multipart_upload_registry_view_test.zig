const std = @import("std");

const multipart = @import("../../src/multipart.zig");
const transaction_module = @import("../../src/internal/multipart/upload_transaction.zig");
const registry_view = @import("../../src/internal/multipart/upload_registry_view.zig");

const Alpha = struct {
    pub const Runtime = struct { value: u32 };
};
const Beta = struct {
    pub const Runtime = struct { value: u16 };
};

fn FilePart(comptime Sink: type) type {
    return struct {
        pub const kind: multipart.PartKind = .file;
        pub const SinkType = Sink;
    };
}

fn FieldPart() type {
    return struct {
        pub const kind: multipart.PartKind = .field;
    };
}

const MixedSpec = struct {
    pub const configured_schema = .{
        .first = FilePart(Alpha){},
        .text = FieldPart(){},
        .again = FilePart(Alpha){},
        .discard = FilePart(multipart.DiscardSink){},
        .second = FilePart(Beta){},
    };
};

const DiscardSpec = struct {
    pub const configured_schema = .{
        .discard = FilePart(multipart.DiscardSink){},
    };
};

const FileSink = multipart.FileSink(.{
    .root = "root",
    .durability = .buffered,
});
const FileSpec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(FileSink, multipart.required),
}, .{}));

test "registry view dedupes schema runtimes and preserves typed pointers" {
    const View = registry_view.RegistryView(MixedSpec);
    const Source = struct {
        alpha: Alpha.Runtime = .{ .value = 11 },
        beta: Beta.Runtime = .{ .value = 22 },
        alpha_gets: u8 = 0,
        beta_gets: u8 = 0,

        pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
            if (Sink == Alpha) {
                self.alpha_gets += 1;
                return &self.alpha;
            }
            if (Sink == Beta) {
                self.beta_gets += 1;
                return &self.beta;
            }
            unreachable;
        }
    };
    var source = Source{};
    var view = try View.init(&source);

    try std.testing.expectEqual(@as(usize, 2), View.sink_count);
    try std.testing.expect(View.sink_types[0] == Alpha);
    try std.testing.expect(View.sink_types[1] == Beta);
    try std.testing.expectEqual(@as(u8, 1), source.alpha_gets);
    try std.testing.expectEqual(@as(u8, 1), source.beta_gets);
    try std.testing.expectEqual(@intFromPtr(&source.alpha), @intFromPtr(view.get(Alpha)));
    try std.testing.expectEqual(@intFromPtr(&source.beta), @intFromPtr(view.get(Beta)));
    view.get(Alpha).value = 91;
    try std.testing.expectEqual(@as(u32, 91), source.alpha.value);
}

test "discard-only registry view owns no runtime pointers" {
    const View = registry_view.RegistryView(DiscardSpec);
    const Source = struct {
        pub fn get(_: *@This(), comptime Sink: type) *Sink.Runtime {
            unreachable;
        }
    };
    var source = Source{};
    _ = try View.init(&source);
    try std.testing.expectEqual(@as(usize, 0), View.sink_count);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(View));
}

test "registry view is the exact typed Transaction registry" {
    const View = registry_view.RegistryView(FileSpec);
    const Transaction = transaction_module.Transaction(FileSpec, View);
    const Source = struct {
        runtime: FileSink.Runtime = undefined,

        pub fn get(self: *@This(), comptime Sink: type) *Sink.Runtime {
            if (Sink == FileSink) return &self.runtime;
            unreachable;
        }
    };
    var source = Source{};
    var view = try View.init(&source);
    var transaction = Transaction.init(&view);

    try std.testing.expectEqual(@as(usize, 1), View.sink_count);
    try std.testing.expectEqual(
        @intFromPtr(&source.runtime),
        @intFromPtr(view.get(FileSink)),
    );
    try std.testing.expect((try transaction.peekSubmission()) == null);
}

test "registry view rejects an unavailable started runtime without trapping" {
    const View = registry_view.RegistryView(FileSpec);
    const Source = struct {
        pub fn get(_: *@This(), comptime Sink: type) ?*Sink.Runtime {
            return null;
        }
    };
    var source = Source{};
    try std.testing.expectError(error.RuntimeUnavailable, View.init(&source));
}
