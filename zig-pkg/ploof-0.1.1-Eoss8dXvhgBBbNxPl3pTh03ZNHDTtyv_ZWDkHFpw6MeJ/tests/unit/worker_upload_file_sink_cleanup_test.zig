const split = @import("worker_upload_file_sink_cleanup_support.zig");
pub const std = @import("std");

pub const application = @import("../../src/application.zig");
pub const endpoint = @import("../../src/endpoint.zig");
pub const multipart = @import("../../src/multipart.zig");
pub const parser = @import("../../src/internal/multipart/parser.zig");
pub const reactor = @import("../../src/internal/runtime/reactor.zig");
pub const response = @import("../../src/response.zig");
pub const route = @import("../../src/route.zig");
pub const upload = @import("../../src/multipart/upload.zig");
pub const upload_finalizer = @import("../../src/internal/upload/finalizer.zig");
pub const worker_upload = @import("../../src/internal/runtime/worker/upload_transport.zig");
pub const worker_upload_metrics = @import("../../src/internal/runtime/worker/upload_metrics.zig");

pub const Sink = multipart.FileSink(.{
    .root = "uploads",
    .durability = .buffered,
});
pub const AsyncFinishSink = struct {
    pub const ploof_multipart_sink = true;
    pub const State = struct { opened: ?upload.FileHandle = null };
    pub const WriteState = void;
    pub const Summary = void;
    pub const BeginInput = void;
    pub const Runtime = struct { directory: upload.FileHandle };
    pub const StartupState = void;
    pub const Error = error{UnexpectedCompletion};
    pub const io_requirements = upload.IoRequirements{ .open = true, .close = true };
    pub const request_handles_max: u8 = 1;
    pub const runtime_handles_max: u8 = 1;
    pub const initial_state: State = .{};
    pub const initial_write_state: WriteState = {};
    pub const initial_startup_state: StartupState = {};

    pub fn runtimeStart(
        _: *StartupState,
        event: upload.PollEvent(upload.RuntimeStartInput),
    ) Error!upload.Poll(Runtime) {
        return switch (event) {
            .start => .{ .request = .{ .open = .{
                .base = .working_directory,
                .path = ".",
                .access = .read_only,
                .kind = .directory,
            } } },
            .completion => |completion| switch (completion) {
                .success => |success| switch (success) {
                    .open => |directory| .{ .done = .{ .directory = directory } },
                    else => error.UnexpectedCompletion,
                },
                .failure => error.UnexpectedCompletion,
            },
        };
    }

    pub fn runtimeStop(
        runtime: *Runtime,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .request = .{ .close = .{ .file = runtime.directory } } },
            .completion => |completion| switch (completion) {
                .success => |success| switch (success) {
                    .close => .{ .done = {} },
                    else => error.UnexpectedCompletion,
                },
                .failure => error.UnexpectedCompletion,
            },
        };
    }

    pub fn begin(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(BeginInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn write(
        _: *Runtime,
        _: *State,
        _: *WriteState,
        event: upload.PollEvent(upload.WriteInput),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn finish(
        runtime: *Runtime,
        state: *State,
        event: upload.PollEvent(upload.FinishInput),
    ) Error!upload.Poll(Summary) {
        return switch (event) {
            .start => .{ .request = .{ .open = .{
                .base = .{ .handle = runtime.directory },
                .path = ".",
                .access = .read_only,
                .kind = .directory,
            } } },
            .completion => |completion| switch (completion) {
                .success => |success| switch (success) {
                    .open => |opened| done: {
                        state.opened = opened;
                        break :done .{ .done = {} };
                    },
                    else => error.UnexpectedCompletion,
                },
                .failure => error.UnexpectedCompletion,
            },
        };
    }

    pub fn commit(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn abort(
        _: *Runtime,
        _: *State,
        event: upload.PollEvent(void),
    ) Error!upload.Poll(void) {
        return synchronous(event);
    }

    pub fn synchronous(event: anytype) Error!upload.Poll(void) {
        return switch (event) {
            .start => .{ .done = {} },
            .completion => error.UnexpectedCompletion,
        };
    }
};
pub const Body = multipart.decode(.{
    .upload = multipart.file(Sink, multipart.required),
    .token = multipart.field([]const u8, multipart.required),
}, .{
    .limits = multipart.Limits.validate(.{
        .encoded_wire_bytes_max = 512,
        .total_body_bytes_max = 512,
        .file_bytes_max = 64,
        .field_bytes_max = 64,
        .parts_max = 2,
        .files_max = 1,
        .part_headers_max = 2,
        .part_header_bytes_max = 192,
        .disposition_parameters_max = 3,
        .delimiter_transport_padding_bytes_max = 8,
        .name_bytes_max = 16,
        .filename_bytes_max = 16,
        .boundary_bytes_max = 8,
    }),
    .upload = multipart.UploadProfile.validate(.{ .window = 4, .chunk_bytes = 4 }),
});
pub const Definition = endpoint.Endpoint(.{ .body = Body });
pub const Spec = @TypeOf(Body);
pub const Context = application.Context(void, response.standard_head_limits);

pub const Consumer = struct {
    pub const State = void;

    pub fn init(_: Consumer, _: *Context) State {}

    pub fn fileStart(
        _: Consumer,
        _: *Context,
        _: *State,
        _: Spec.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{
            .upload = Sink.Key.init("stage.bin") catch unreachable,
        } };
    }

    pub fn field(_: Consumer, _: *State, _: Spec.Field) void {}

    pub fn complete(
        _: Consumer,
        context: *Context,
        _: *State,
        _: Definition.InputType,
        _: Spec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};

pub const App = application.Application(.{
    .State = void,
    .routes = .{route.post("/upload", Definition.handle(Consumer{}))},
});
pub const AsyncBody = multipart.decode(.{
    .upload = multipart.file(AsyncFinishSink, multipart.required),
    .token = multipart.field([]const u8, multipart.required),
}, .{ .limits = multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 512,
    .total_body_bytes_max = 512,
    .file_bytes_max = 64,
    .field_bytes_max = 64,
    .parts_max = 2,
    .files_max = 1,
    .part_headers_max = 2,
    .part_header_bytes_max = 192,
    .disposition_parameters_max = 3,
    .delimiter_transport_padding_bytes_max = 8,
    .name_bytes_max = 16,
    .filename_bytes_max = 16,
    .boundary_bytes_max = 8,
}) });
pub const AsyncDefinition = endpoint.Endpoint(.{ .body = AsyncBody });
pub const AsyncSpec = @TypeOf(AsyncBody);
pub const AsyncConsumer = struct {
    pub const State = void;

    pub fn init(_: AsyncConsumer, _: *Context) State {}

    pub fn field(_: AsyncConsumer, _: *State, _: AsyncSpec.Field) void {}

    pub fn fileStart(
        _: AsyncConsumer,
        _: *Context,
        _: *State,
        _: AsyncSpec.FileStart,
    ) AsyncSpec.FileAdmission(Context.ResponseType) {
        return .{ .accept = .{ .upload = {} } };
    }

    pub fn complete(
        _: AsyncConsumer,
        context: *Context,
        _: *State,
        _: AsyncDefinition.InputType,
        _: AsyncSpec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        return multipart.commit(context.empty(.no_content));
    }
};
pub const AsyncApp = application.Application(.{
    .State = void,
    .routes = .{route.post("/async-upload", AsyncDefinition.handle(AsyncConsumer{}))},
});
pub const workspace_bytes: usize = @intCast(App.body_workspace_bytes_max);
pub const async_workspace_bytes: usize = @intCast(AsyncApp.body_workspace_bytes_max);
pub const wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n\r\n" ++
    "abcdefghijklmnop\r\n--B\r\n" ++
    "Content-Disposition: form-data; name=token\r\n\r\n" ++
    "ok\r\n--B--";
pub const async_missing_required_wire = "--B\r\n" ++
    "Content-Disposition: form-data; name=upload; filename=x\r\n\r\n" ++
    "data\r\n--B--";

pub const Storage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    const Phase = enum(u8) { free, live };
    pub const Connection = struct { active_request: ?u16 = 0 };
    const Flags = packed struct(u8) {
        response_dirty_full: bool = false,
        upload_inflight: bool = false,
        upload_parser_paused: bool = false,
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
        upload_cancel_requested: bool = false,
        upload_cancel_peer: bool = false,
        upload_rejection_pending: bool = false,
    };
    pub const Request = struct {
        phase: Phase = .live,
        generation: u16 = 4,
        sequence: u16 = 20,
        connection_index: u16 = 0,
        flags: Flags = .{},
        workspace: App.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    upload_registry: App.UploadRegistry = .{},
    body: [workspace_bytes]u8 align(App.body_workspace_alignment) = undefined,

    pub fn bodyWorkspace(self: *Storage, index: u16) error{Invalid}![]u8 {
        if (index != 0) return error.Invalid;
        return &self.body;
    }
};

pub const AsyncStorage = struct {
    pub const runtime_limits = .{
        .request_slots = 1,
        .timeouts = .{ .startup_io_ns = 10 * std.time.ns_per_s },
    };
    const Phase = enum(u8) { free, live };
    pub const Connection = struct { active_request: ?u16 = 0 };
    const Flags = packed struct(u8) {
        response_dirty_full: bool = false,
        upload_inflight: bool = false,
        upload_parser_paused: bool = false,
        upload_finalizing: bool = false,
        upload_response_failed: bool = false,
        upload_cancel_requested: bool = false,
        upload_cancel_peer: bool = false,
        upload_rejection_pending: bool = false,
    };
    pub const Request = struct {
        phase: Phase = .live,
        generation: u16 = 5,
        sequence: u16 = 30,
        connection_index: u16 = 0,
        flags: Flags = .{},
        workspace: AsyncApp.Workspace = .{},
    };

    connections: [1]Connection = .{.{}},
    requests: [1]Request = .{.{}},
    upload_registry: AsyncApp.UploadRegistry = .{},
    body: [async_workspace_bytes]u8 align(AsyncApp.body_workspace_alignment) = undefined,

    pub fn bodyWorkspace(self: *AsyncStorage, index: u16) error{Invalid}![]u8 {
        if (index != 0) return error.Invalid;
        return &self.body;
    }
};

pub const TestReactor = split.TestReactor;

pub const Controller = split.Controller;
pub const AsyncController = split.AsyncController;

pub const beginFourWrites = split.beginFourWrites;

pub const completeCanceled = split.completeCanceled;

pub const completeCancel = split.completeCancel;

pub const exerciseAsyncFinishCancellation = split.exerciseAsyncFinishCancellation;

pub const exerciseFileSinkOpenCancellation = split.exerciseFileSinkOpenCancellation;

pub const expectCleanPeerCancellation = split.expectCleanPeerCancellation;

pub const beginFileSinkOpen = split.beginFileSinkOpen;

pub const beginAsyncFinishOpen = split.beginAsyncFinishOpen;

pub const startRegistry = split.startRegistry;

pub const startAsyncRegistry = split.startAsyncRegistry;

pub const startRegistryWith = split.startRegistryWith;

pub const completeTimedRuntimeTarget = split.completeTimedRuntimeTarget;

pub const prepareMultipart = split.prepareMultipart;

pub const prepareAsyncMultipart = split.prepareAsyncMultipart;

pub const driveBody = split.driveBody;

pub const driveParserWork = split.driveParserWork;

pub const driveParserForRejection = split.driveParserForRejection;

pub const sinkReport = split.sinkReport;

pub const requestInput = split.requestInput;

pub const asyncRequestInput = split.asyncRequestInput;

test {
    _ = @import("worker_upload_file_sink_cleanup_test_part_1.zig");
}
