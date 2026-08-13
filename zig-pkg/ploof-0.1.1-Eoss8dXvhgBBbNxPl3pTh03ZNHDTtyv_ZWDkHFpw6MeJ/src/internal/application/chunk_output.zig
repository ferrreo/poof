const std = @import("std");
const gzip_encoder = @import("../runtime/gzip/encoder.zig");
const response_chunk_chain = @import("../response/chunk_chain.zig");

pub const WriteError = error{
    ResponseBodyTooLarge,
    ResponseChunksExhausted,
    SourceAliasesPool,
    WriterTerminal,
};

pub const Compression = union(enum) {
    success: u32,
    capacity_unavailable,
    failed,
};

pub const Failure = enum(u8) {
    none,
    rendering,
    capacity,
};

pub const Bound = struct {
    writer: *Writer,
    scratch: []u8,
    failure: Failure = .none,
};

pub const Writer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        write: *const fn (*anyopaque, []const u8) WriteError!void,
        reset: *const fn (*anyopaque) void,
        bytesWritten: *const fn (*const anyopaque) u32,
        finish: *const fn (*anyopaque) WriteError!response_chunk_chain.Chain,
        abort: *const fn (*anyopaque) void,
        compress: *const fn (
            *anyopaque,
            *gzip_encoder.Workspace,
            gzip_encoder.Level,
        ) Compression,
        restoreIdentity: *const fn (*anyopaque) bool,
    };

    pub fn write(self: *Writer, bytes: []const u8) WriteError!void {
        return self.vtable.write(self.context, bytes);
    }

    pub fn reset(self: *Writer) void {
        self.vtable.reset(self.context);
    }

    pub fn bytesWritten(self: *const Writer) u32 {
        return self.vtable.bytesWritten(self.context);
    }

    pub fn finish(self: *Writer) WriteError!response_chunk_chain.Chain {
        return self.vtable.finish(self.context);
    }

    pub fn abort(self: *Writer) void {
        self.vtable.abort(self.context);
    }

    pub fn compress(
        self: *Writer,
        workspace: *gzip_encoder.Workspace,
        level: gzip_encoder.Level,
    ) Compression {
        return self.vtable.compress(self.context, workspace, level);
    }

    pub fn restoreIdentity(self: *Writer) bool {
        return self.vtable.restoreIdentity(self.context);
    }
};

pub fn bind(concrete: anytype) Writer {
    const Pointer = @TypeOf(concrete);
    const info = @typeInfo(Pointer);
    if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) {
        @compileError("chunk output binding requires one mutable writer pointer");
    }
    const Concrete = info.pointer.child;
    const Adapter = struct {
        fn write(context: *anyopaque, bytes: []const u8) WriteError!void {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            return writer.write(bytes);
        }

        fn reset(context: *anyopaque) void {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            writer.reset();
        }

        fn bytesWritten(context: *const anyopaque) u32 {
            const writer: *const Concrete = @ptrCast(@alignCast(context));
            return writer.bytesWritten();
        }

        fn finish(context: *anyopaque) WriteError!response_chunk_chain.Chain {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            return writer.finish();
        }

        fn abort(context: *anyopaque) void {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            writer.abort();
        }

        fn compress(
            context: *anyopaque,
            workspace: *gzip_encoder.Workspace,
            level: gzip_encoder.Level,
        ) Compression {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            return writer.compress(workspace, level);
        }

        fn restoreIdentity(context: *anyopaque) bool {
            const writer: *Concrete = @ptrCast(@alignCast(context));
            return writer.restoreIdentity();
        }

        const vtable = Writer.VTable{
            .write = write,
            .reset = reset,
            .bytesWritten = bytesWritten,
            .finish = finish,
            .abort = abort,
            .compress = compress,
            .restoreIdentity = restoreIdentity,
        };
    };
    return .{ .context = concrete, .vtable = &Adapter.vtable };
}

pub fn Binding(comptime enabled: bool) type {
    return if (enabled) struct {
        bound: ?Bound = null,

        pub fn bind(self: *@This(), writer: *Writer, scratch: []u8) void {
            std.debug.assert(self.bound == null);
            self.bound = .{ .writer = writer, .scratch = scratch };
        }

        pub fn clear(self: *@This()) void {
            self.bound = null;
        }

        pub fn get(self: *@This()) ?*Bound {
            return if (self.bound) |*bound| bound else null;
        }
    } else struct {
        pub fn bind(_: *@This(), _: *Writer, _: []u8) void {}
        pub fn clear(_: *@This()) void {}
        pub fn get(_: *@This()) ?*Bound {
            return null;
        }
    };
}
