const std = @import("std");
const upload_io = @import("../../../upload_io.zig");

pub fn Types(comptime OperationToken: type) type {
    return struct {
        pub const Descriptor = struct {
            value: i32,

            pub fn valid(descriptor: @This()) bool {
                return descriptor.value >= 0;
            }
        };

        pub const OpenBase = union(enum) {
            working_directory,
            directory: Descriptor,
        };

        pub const Open = struct {
            base: OpenBase,
            /// Borrowed through the matching completion.
            path: [:0]const u8,
            access: upload_io.Access,
            create: upload_io.Create = .none,
            kind: upload_io.OpenKind = .file,
            no_follow: bool = true,
            non_blocking: bool = false,
            mode: u16 = 0,
            resolve: upload_io.Resolve = .{},
        };

        pub const Write = struct {
            file: Descriptor,
            /// Borrowed through every short-write retry and final completion.
            bytes: []const u8,
            offset: u64,
        };

        pub const Read = struct {
            file: Descriptor,
            /// Borrowed and mutated through matching completion.
            bytes: []u8,
            offset: u64,
        };

        pub const Stat = struct {
            file: Descriptor,
            /// Borrowed and mutated through matching completion.
            output: *std.os.linux.Statx,
        };

        pub const Close = struct { file: Descriptor };

        pub const Link = struct {
            source: Descriptor,
            target_directory: Descriptor,
            /// Borrowed through matching completion.
            target_path: [:0]const u8,
        };

        pub const Unlink = struct {
            directory: Descriptor,
            /// Borrowed through matching completion.
            path: [:0]const u8,
        };

        pub const RenameNoReplace = struct {
            source_directory: Descriptor,
            /// Both paths are borrowed through matching completion.
            source_path: [:0]const u8,
            target_directory: Descriptor,
            target_path: [:0]const u8,
        };

        pub const Sync = struct { file: Descriptor };
        pub const UploadCancel = struct { target: OperationToken };
        pub const Cancel = struct { target: OperationToken };
    };
}

test {
    _ = std.testing.refAllDecls(@This());
}
