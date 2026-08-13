const split = @import("worker_file_sink_io_uring_runtime_test_support.zig");
pub const std = @import("std");
pub const linux = std.os.linux;

pub const application = @import("../../../../src/application.zig");
pub const endpoint = @import("../../../../src/endpoint.zig");
pub const multipart = @import("../../../../src/multipart.zig");
pub const response = @import("../../../../src/response.zig");
pub const route = @import("../../../../src/route.zig");
pub const buffer_ring = @import("../../../../src/internal/runtime/buffer_ring.zig");
pub const config = @import("../../../../src/internal/runtime/config.zig");
pub const connection_body_transport = @import(
    "../../../../src/internal/runtime/connection/body_transport.zig",
);
pub const connection_driver = @import("../../../../src/internal/runtime/connection/driver.zig");
pub const gzip_encoder = @import("../../../../src/internal/runtime/gzip/encoder.zig");
pub const io_uring_backend = @import("../../../../src/internal/runtime/io_uring/backend.zig");
pub const listener_runtime = @import("../../../../src/internal/runtime/listener.zig");
pub const reactor = @import("../../../../src/internal/runtime/reactor.zig");
pub const worker_runtime = @import("../../../../src/internal/runtime/worker.zig");
pub const worker_storage = @import("../../../../src/internal/runtime/worker/storage.zig");
pub const upload_metrics = @import("../../../../src/internal/runtime/worker/upload_metrics.zig");
pub const request_head = @import("../../../../src/internal/http1/request_head.zig");

pub const epoch_second: i64 = 1_784_030_400;
pub const completion_limit: u16 = 1_024;
pub const completion_wait_ns: u64 = 2 * std.time.ns_per_s;
pub const boundary = "FS";
pub const first_bytes = "alpha";
pub const second_bytes = "beta";
pub const first_part =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=first; filename=first.bin\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++ first_bytes ++ "\r\n";
pub const second_part =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=second; filename=second.bin\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++ second_bytes ++ "\r\n";
pub const valid_body = first_part ++ second_part ++ "--" ++ boundary ++ "--";
pub const failed_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=first; filename=fail.bin\r\n\r\n" ++
    first_bytes ++ "\r\n" ++ second_part ++ "--" ++ boundary ++ "--";
pub const rejected_body = first_part ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=second; filename=reject.bin\r\n\r\n" ++
    second_bytes ++ "\r\n--" ++ boundary ++ "--";
pub const missing_required_body = first_part ++ "--" ++ boundary ++ "--";
pub const invalid_after_first_body =
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=first; filename=first.bin\r\n" ++
    "Content-Type: application/octet-stream\r\n\r\n" ++
    "abcdefghijklmnopqrst\r\n" ++
    "--" ++ boundary ++ "\r\n" ++
    "Content-Disposition: form-data; name=unknown\r\n\r\nx\r\n" ++
    "--" ++ boundary ++ "--" ++ ("x" ** 300);
pub const success_response =
    "HTTP/1.1 200 OK\r\n" ++
    "content-type: text/plain; charset=utf-8\r\n" ++
    "content-length: 6\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n\r\n" ++
    "stored";
pub const failure_response =
    "HTTP/1.1 500 Internal Server Error\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";
pub const bad_request_response =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";
pub const too_large_response =
    "HTTP/1.1 413 Payload Too Large\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";
pub const unsupported_response =
    "HTTP/1.1 415 Unsupported Media Type\r\n" ++
    "content-length: 0\r\n" ++
    "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n" ++
    "connection: close\r\n\r\n";
pub const forbidden_status = "HTTP/1.1 403 Forbidden\r\n";

pub const Sink = multipart.FileSink(.{
    .root = "uploads",
    .durability = .buffered,
});
pub const Body = multipart.decode(.{
    .first = multipart.file(Sink, multipart.required),
    .second = multipart.file(Sink, multipart.required),
}, .{
    .limits = multipart.Limits.validate(.{
        .encoded_wire_bytes_max = 1_024,
        .total_body_bytes_max = 1_024,
        .file_bytes_max = 64,
        .field_bytes_max = 64,
        .parts_max = 2,
        .files_max = 2,
        .part_headers_max = 2,
        .part_header_bytes_max = 192,
        .disposition_parameters_max = 3,
        .delimiter_transport_padding_bytes_max = 8,
        .name_bytes_max = 16,
        .filename_bytes_max = 32,
        .boundary_bytes_max = 8,
    }),
    .upload = multipart.UploadProfile.validate(.{ .window = 4, .chunk_bytes = 4 }),
});
pub const Definition = endpoint.Endpoint(.{ .body = Body });
pub const Spec = @TypeOf(Body);

pub const AppState = struct {
    decisions: u16 = 0,
    after_calls: u16 = 0,
    completed: u16 = 0,
    aborted: u16 = 0,
    order_valid: bool = true,
    summaries_valid: bool = true,
};
pub const Context = application.Context(AppState, response.standard_head_limits);

pub const Consumer = struct {
    pub const State = struct {
        starts: u8 = 0,
        order_valid: bool = true,
    };

    pub fn init(_: Consumer, _: *Context) State {
        return .{};
    }

    pub fn fileStart(
        _: Consumer,
        context: *Context,
        state: *State,
        event: Spec.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        return switch (event) {
            .first => |metadata| firstAdmission(state, metadata),
            .second => |metadata| secondAdmission(context, state, metadata),
        };
    }

    pub fn firstAdmission(state: *State, metadata: multipart.FileStart) Spec.FileAdmission(
        Context.ResponseType,
    ) {
        recordStart(state, 0);
        const filename = metadata.client_filename orelse unreachable;
        const key = if (std.mem.eql(u8, filename.bytes, "fail.bin"))
            "missing/fail.bin"
        else
            "first.bin";
        return .{ .accept = .{ .first = Sink.Key.init(key) catch unreachable } };
    }

    pub fn secondAdmission(
        context: *Context,
        state: *State,
        metadata: multipart.FileStart,
    ) Spec.FileAdmission(Context.ResponseType) {
        recordStart(state, 1);
        const filename = metadata.client_filename orelse unreachable;
        if (std.mem.eql(u8, filename.bytes, "reject.bin")) {
            return .{ .reject = context.textStatic(.forbidden, "rejected") };
        }
        return .{ .accept = .{
            .second = Sink.Key.init("second.bin") catch unreachable,
        } };
    }

    pub fn recordStart(state: *State, expected: u8) void {
        state.order_valid = state.order_valid and state.starts == expected;
        state.starts += 1;
    }

    pub fn complete(
        _: Consumer,
        context: *Context,
        state: *State,
        _: Definition.InputType,
        summaries: Spec.Summaries,
    ) multipart.Decision(Context.ResponseType) {
        const first = summaries.first.slice();
        const second = summaries.second.slice();
        context.state.decisions += 1;
        context.state.order_valid = context.state.order_valid and state.order_valid;
        context.state.summaries_valid = context.state.summaries_valid and
            first.len == 1 and second.len == 1 and
            first[0].bytes == first_bytes.len and second[0].bytes == second_bytes.len and
            std.mem.eql(u8, first[0].storage_key, "first.bin") and
            std.mem.eql(u8, second[0].storage_key, "second.bin");
        return multipart.commit(context.textStatic(.ok, "stored"));
    }
};

pub const Observe = struct {
    pub const State = void;

    pub fn init(_: Observe) void {}

    pub fn after(
        _: Observe,
        context: *const Context,
        _: *void,
        outcome: application.Outcome,
    ) void {
        context.state.after_calls += 1;
        switch (outcome.transport) {
            .completed, .head_suppressed => context.state.completed += 1,
            else => context.state.aborted += 1,
        }
    }
};

pub const App = application.Application(.{
    .State = AppState,
    .middleware = .{Observe{}},
    .routes = .{route.post("/upload", Definition.handle(Consumer{}))},
});

pub const limits = config.Limits.validate(.{
    .connection_slots = 1,
    .request_slots = 1,
    .body_workspace_slots = 1,
    .chunked_workspace_slots = 1,
    .receive_buffers = 4,
    .receive_buffer_bytes = 256,
    .pipeline_bytes_per_connection = 512,
    .response_bytes_per_request = 1_024,
    .submission_entries = 32,
    .completion_entries = 64,
    .gzip = .{
        .decoder_slots = 1,
        .input_chunks_per_slot = 4,
        .members_max = 1,
        .thread_stack_bytes = 128 * 1_024,
    },
    .timeouts = .{
        .first_head_ns = 2 * std.time.ns_per_s,
        .keepalive_idle_ns = 2 * std.time.ns_per_s,
        .reused_head_progress_ns = 2 * std.time.ns_per_s,
        .body_inactivity_ns = 2 * std.time.ns_per_s,
        .write_stall_ns = 2 * std.time.ns_per_s,
    },
});
pub const ReceiveBuffers = buffer_ring.BufferRing(4, 256, 76);
pub const Backend = io_uring_backend.IoUringBackendWithUploads(
    limits,
    ReceiveBuffers,
    .{
        .connection_slots = limits.connection_slots,
        .body_workspace_slots = limits.body_workspace_slots,
        .upload_window_max = App.upload_window_max,
        .request_handles_max = App.upload_request_handles_max,
        .runtime_handles_max = App.upload_runtime_handles_max,
        .async_sink_present = App.upload_async_sink_present,
    },
);
pub const Storage = worker_storage.Storage(App, limits);
pub const Worker = worker_runtime.Worker(App, Storage, Backend);
pub const BodyTransport = connection_body_transport.Transport(
    App,
    Storage,
    connection_driver.Error,
);

pub const deadline_limits = deadline_limits: {
    var value = limits;
    value.timeouts.startup_io_ns = 1;
    break :deadline_limits config.Limits.validate(value);
};
pub const DeadlineBackend = io_uring_backend.IoUringBackendWithUploads(
    deadline_limits,
    ReceiveBuffers,
    .{
        .connection_slots = deadline_limits.connection_slots,
        .body_workspace_slots = deadline_limits.body_workspace_slots,
        .upload_window_max = App.upload_window_max,
        .request_handles_max = App.upload_request_handles_max,
        .runtime_handles_max = App.upload_runtime_handles_max,
        .async_sink_present = App.upload_async_sink_present,
    },
);
pub const DeadlineStorage = worker_storage.Storage(App, deadline_limits);
pub const DeadlineWorker = worker_runtime.Worker(App, DeadlineStorage, DeadlineBackend);

pub const HalfSubmitBackend = struct {
    pub const file_handle_capacity = Backend.file_handle_capacity;
    pub const file_target_capacity = Backend.file_target_capacity;

    submit_attempts: u8 = 0,
    retained_target: ?reactor.Submission = null,
    aborted: bool = false,

    pub fn submit(self: *@This(), submission: reactor.Submission) error{Full}!void {
        self.submit_attempts += 1;
        if (self.submit_attempts == 2) return error.Full;
        if (self.retained_target != null) return error.Full;
        self.retained_target = submission;
    }

    pub fn flush(_: *@This()) error{SubmissionRetry}!u32 {
        return 0;
    }

    pub fn abort(self: *@This()) error{}!reactor.AbortStatus {
        self.retained_target = null;
        self.aborted = true;
        return .{ .ownership_proven = true, .accepted_sockets_discarded = 0 };
    }

    pub fn queuedCount(self: *const @This()) u32 {
        return @intFromBool(self.retained_target != null);
    }

    pub fn activeCount(_: *@This()) u32 {
        return 0;
    }

    pub fn borrowedCount(_: *const @This()) u16 {
        return 0;
    }

    pub fn discard(_: *@This(), _: reactor.Socket) error{}!void {}
};
pub const HalfSubmitWorker = worker_runtime.Worker(App, Storage, HalfSubmitBackend);

pub const ActiveGzipUpload = struct {
    connection_index: u16,
    request_index: u16,
};

pub const Runtime = split.Runtime;

pub const Encoding = split.Encoding;

pub const CloseOrder = split.CloseOrder;
pub const DrainGoal = split.DrainGoal;

pub const exerciseActiveGzipResponse = split.exerciseActiveGzipResponse;

pub const exerciseActiveGzipClose = split.exerciseActiveGzipClose;

pub const forceActiveParserRejection = split.forceActiveParserRejection;

pub const drainOrdered = split.drainOrdered;

pub const deliverCompletion = split.deliverCompletion;

pub const flushBackend = split.flushBackend;

pub const expectClientClosedWithoutResponse = split.expectClientClosedWithoutResponse;

pub const expectParserRejectionMetrics = split.expectParserRejectionMetrics;

pub const exercisePublication = split.exercisePublication;

pub const sendMultipart = split.sendMultipart;

pub const expectStoredFiles = split.expectStoredFiles;

pub const expectFile = split.expectFile;

pub const expectFileAbsent = split.expectFileAbsent;

pub const fileExists = split.fileExists;

pub const discardLiveSockets = split.discardLiveSockets;

pub const resolveStep = split.resolveStep;

pub const waitCompletion = split.waitCompletion;

pub const clientReady = split.clientReady;

pub const connectClient = split.connectClient;

pub const sendAll = split.sendAll;

pub const receiveExact = split.receiveExact;

pub const enterTemporary = split.enterTemporary;

pub const restoreCwd = split.restoreCwd;

pub const monotonicNow = split.monotonicNow;

test {
    _ = @import("worker_file_sink_io_uring_integration_test_part_1.zig");
}
