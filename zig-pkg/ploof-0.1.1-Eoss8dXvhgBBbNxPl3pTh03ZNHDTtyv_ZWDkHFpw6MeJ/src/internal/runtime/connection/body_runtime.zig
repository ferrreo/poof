const std = @import("std");
const application = @import("../../../application.zig");
const application_chunk_output = @import("../../application/chunk_output.zig");
const body = @import("../../../body.zig");
const connection_body = @import("body.zig");
const body_finalization = @import("body_finalization.zig");
const body_types = @import("body_types.zig");
const connection_chunked_body = @import("chunked_body.zig");
const request_head = @import("../../http1/request_head.zig");
const worker_response_staging = @import("../worker/response_staging.zig");

pub const Error = body_types.Error;
pub const Event = body_types.Event;
pub const FeedResult = body_types.FeedResult;
pub const finalizationMatchesUpstream = body_finalization.matchesUpstream;
pub const stageRejection = body_finalization.stageRejection;
pub const stageRejectionNow = body_finalization.stageRejectionNow;

pub fn startFixed(
    storage: anytype,
    request_index: u16,
    receiver: connection_body.FixedIdentity,
    kind: body.Kind,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const committed = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        if (committed.len != 0 or receiver.progress() != 0) {
            return error.StateInvariant;
        }
        if (receiver.expected() > Storage.body_workspace_bytes_per_slot) {
            return error.StateInvariant;
        }
        request.body.receiver = receiver;
        request.body.kind = kind;
        return;
    }
    return error.StateInvariant;
}

pub fn startMultipartFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    receiver: connection_body.FixedIdentity,
    boundary: []const u8,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const workspace = storage.bodyWorkspace(request_index) catch {
            return error.StateInvariant;
        };
        const request = &storage.requests[request_index];
        if (request.body.used != 0 or receiver.progress() != 0 or request.body.multipart) {
            return error.StateInvariant;
        }
        App.__beginMultipart(
            &request.workspace,
            workspace,
            boundary,
            &storage.upload_registry,
        ) catch {
            return error.StateInvariant;
        };
        request.body.receiver = receiver;
        request.body.multipart = true;
        return;
    }
    return error.StateInvariant;
}

pub fn startGzipFixed(
    storage: anytype,
    request_index: u16,
    receiver: connection_body.FixedIdentity,
    kind: body.Kind,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const committed = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        if (request.gzip_lease == null or committed.len != 0 or receiver.progress() != 0) {
            return error.StateInvariant;
        }
        request.body.receiver = receiver;
        request.body.kind = kind;
        return;
    }
    return error.StateInvariant;
}

pub fn startMultipartGzipFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    receiver: connection_body.FixedIdentity,
    boundary: []const u8,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const workspace = storage.bodyWorkspace(request_index) catch {
            return error.StateInvariant;
        };
        const request = &storage.requests[request_index];
        if (request.gzip_lease == null or
            request.body.used != 0 or
            receiver.progress() != 0 or
            request.body.multipart)
        {
            return error.StateInvariant;
        }
        App.__beginMultipart(
            &request.workspace,
            workspace,
            boundary,
            &storage.upload_registry,
        ) catch {
            return error.StateInvariant;
        };
        request.body.receiver = receiver;
        request.body.multipart = true;
        return;
    }
    return error.StateInvariant;
}

pub fn feedFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    input: []const u8,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const output = storage.bodyWritable(request_index) catch {
            return error.StateInvariant;
        };
        const request = &storage.requests[request_index];
        if (request.body.receiver.progress() != request.body.used) {
            return error.StateInvariant;
        }
        const result = request.body.receiver.feed(input) catch {
            return error.StateInvariant;
        };
        if (result.body.len > output.len) return error.StateInvariant;
        @memcpy(output[0..result.body.len], result.body);
        storage.commitBody(request_index, result.body.len) catch {
            return error.StateInvariant;
        };
        if (!result.complete) return .{
            .consumed = result.body.len,
            .event = .need_more,
        };
        const finished = try finish(App, storage, request_index);
        return .{
            .consumed = result.body.len,
            .event = finished.event,
            .close_connection = finished.close_connection,
        };
    }
    return error.StateInvariant;
}

pub fn feedMultipartFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    input: []const u8,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        if (!request.body.multipart) return error.StateInvariant;
        if (comptime asyncUploads(App)) {
            return feedMultipartFixedProgress(App, storage, request_index, input);
        }
        const result = request.body.receiver.feed(input) catch return error.StateInvariant;
        const parsed = try feedMultipart(App, storage, request_index, result.body);
        if (parsed.event != .need_more) return parsed;
        if (!result.complete) return .{ .consumed = result.body.len, .event = .need_more };
        const finished = try finishMultipart(App, storage, request_index, .{});
        return .{
            .consumed = result.body.len,
            .event = finished.event,
            .close_connection = finished.close_connection,
        };
    }
    return error.StateInvariant;
}

pub fn finishMultipartFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        if (!request.body.multipart or !request.body.receiver.complete()) {
            return error.StateInvariant;
        }
        if (comptime asyncUploads(App)) {
            return finishMultipartProgress(App, storage, request_index, .{});
        }
        return finishMultipart(App, storage, request_index, .{});
    }
    return error.StateInvariant;
}

pub fn startChunked(
    storage: anytype,
    request_index: u16,
    kind: body.Kind,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.chunkedState(request_index) catch return error.StateInvariant;
        _ = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        if (request.body.used != 0) return error.StateInvariant;
        request.body.kind = kind;
        return;
    }
    return error.StateInvariant;
}

pub fn startMultipartChunked(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    boundary: []const u8,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.chunkedState(request_index) catch return error.StateInvariant;
        const workspace = storage.bodyWorkspace(request_index) catch {
            return error.StateInvariant;
        };
        const request = &storage.requests[request_index];
        if (request.body.used != 0 or request.body.multipart) return error.StateInvariant;
        App.__beginMultipart(
            &request.workspace,
            workspace,
            boundary,
            &storage.upload_registry,
        ) catch {
            return error.StateInvariant;
        };
        request.body.multipart = true;
        return;
    }
    return error.StateInvariant;
}

pub fn appendChunk(
    storage: anytype,
    request_index: u16,
    data: []const u8,
) Error!void {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.chunkedState(request_index) catch return error.StateInvariant;
        const output = storage.bodyWritable(request_index) catch {
            return error.StateInvariant;
        };
        if (data.len > output.len) return error.StateInvariant;
        @memcpy(output[0..data.len], data);
        storage.commitBody(request_index, data.len) catch return error.StateInvariant;
        return;
    }
    return error.StateInvariant;
}

pub fn appendMultipartChunk(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    data: []const u8,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        if (!request.body.multipart) return error.StateInvariant;
        return try feedMultipart(App, storage, request_index, data);
    }
    return error.StateInvariant;
}

pub fn appendMultipartProgress(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    data: []const u8,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        if (!request.body.multipart or !asyncUploads(App)) return error.StateInvariant;
        return feedMultipartProgress(App, storage, request_index, data);
    }
    return error.StateInvariant;
}

pub fn finish(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        if (!request.body.receiver.complete()) return error.StateInvariant;
        if (request.body.used != request.body.receiver.expected()) {
            return error.StateInvariant;
        }
        return prepare(App, storage, request_index, .{});
    }
    return error.StateInvariant;
}

pub fn finishGzipFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        _ = storage.bodyReadable(request_index) catch return error.StateInvariant;
        const request = &storage.requests[request_index];
        if (request.gzip_lease != null or !request.body.receiver.complete()) {
            return error.StateInvariant;
        }
        return prepare(App, storage, request_index, .{});
    }
    return error.StateInvariant;
}

pub fn finishMultipartGzipFixed(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const request = &storage.requests[request_index];
        if (request.gzip_lease != null or
            !request.body.receiver.complete() or
            !request.body.multipart)
        {
            return error.StateInvariant;
        }
        if (comptime asyncUploads(App)) {
            return finishMultipartProgress(App, storage, request_index, .{});
        }
        return finishMultipart(App, storage, request_index, .{});
    }
    return error.StateInvariant;
}

pub fn finishChunked(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    ready: connection_chunked_body.ReadyTrailers,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const trailers = try finalTrailers(storage, request_index, ready);
        return prepare(App, storage, request_index, trailers);
    }
    return error.StateInvariant;
}

pub fn finishMultipartChunked(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    ready: connection_chunked_body.ReadyTrailers,
) Error!FeedResult {
    const Storage = @TypeOf(storage.*);
    if (comptime Storage.body_workspace_bytes_per_slot != 0) {
        const trailers = try finalTrailers(storage, request_index, ready);
        if (comptime asyncUploads(App)) {
            return finishMultipartProgress(App, storage, request_index, trailers);
        }
        return finishMultipart(App, storage, request_index, trailers);
    }
    return error.StateInvariant;
}

fn prepare(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    trailers: application.RequestTrailers,
) Error!FeedResult {
    const request = &storage.requests[request_index];
    const decoded = storage.finishBody(request_index, request.body.kind) catch |problem| {
        return switch (problem) {
            error.InvalidUtf8 => .{ .consumed = 0, .event = .invalid_utf8 },
            else => error.StateInvariant,
        };
    };
    return prepareDecoded(App, storage, request_index, trailers, decoded);
}

fn prepareDecoded(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    trailers: application.RequestTrailers,
    decoded: body.Decoded,
) Error!FeedResult {
    const request = &storage.requests[request_index];
    const request_workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const prepared = prepareApplicationBody(
        App,
        storage,
        request_index,
        decoded,
        trailers,
        request_workspace,
    ) catch |problem| return switch (problem) {
        error.InvalidRequestInput => .{ .consumed = 0, .event = .invalid_input },
        error.RequestInputTooLarge => .{ .consumed = 0, .event = .input_too_large },
        else => if (body_finalization.required(request))
            body_finalization.failedResponse(App, storage, request_index)
        else
            error.ApplicationFailure,
    };
    const committed = if (comptime @hasField(@TypeOf(prepared), "source")) modern: {
        defer worker_response_staging.scrub(App, &request.workspace, prepared);
        var release_chain = prepared.source == .finite_chain;
        defer if (release_chain) switch (prepared.source) {
            .finite_chain => |finite| storage.discardResponseChunks(finite.body),
            .contiguous_wire, .borrowed_static, .live_static, .live_static_file => unreachable,
        };
        const result = switch (prepared.source) {
            .finite_chain => |finite| if (comptime @hasDecl(
                @TypeOf(storage.*),
                "commitResponseChunks",
            )) storage.commitResponseChunks(
                request_index,
                finite.head,
                finite.body,
            ) else false,
            .contiguous_wire => |wire| storage.commitResponse(request_index, wire) or
                storage.commitExternalResponse(request_index, wire),
            .borrowed_static => |borrowed| if (borrowed.body.len == 0)
                storage.commitResponse(request_index, borrowed.head)
            else
                storage.commitStaticResponse(request_index, borrowed.head, borrowed.body),
            .live_static, .live_static_file => false,
        };
        if (prepared.source == .finite_chain) release_chain = !result;
        break :modern result;
    } else storage.commitResponse(request_index, prepared.bytes) or
        storage.commitExternalResponse(request_index, prepared.bytes);
    if (!committed) {
        return error.StateInvariant;
    }
    const result = FeedResult{
        .consumed = 0,
        .event = .prepared,
        .close_connection = prepared.close_connection,
    };
    if (body_finalization.required(request)) {
        return body_finalization.begin(App, storage, request_index, result, false, null);
    }
    return result;
}

fn prepareApplicationBody(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    decoded: body.Decoded,
    trailers: application.RequestTrailers,
    request_workspace: []u8,
) application.PrepareError!prepareBodyPayload(App) {
    const request = &storage.requests[request_index];
    const finite_output = if (comptime @hasDecl(@TypeOf(storage.*), "finiteOutput"))
        storage.finiteOutput(request_index)
    else if (comptime @hasField(@TypeOf(request.*), "finite_output") and
        @TypeOf(request.finite_output) == @import("../../application/finite_output.zig").Plan)
        request.finite_output
    else
        @import("../../application/finite_output.zig").Plan.contiguous;
    return switch (finite_output) {
        .contiguous => App.__prepareBodyWithResponseGzip(
            &request.workspace,
            decoded,
            trailers,
            request_workspace,
            storage.json_hash_key,
            storage.responseWritable(request_index),
            &storage.response_gzip_workspace,
        ),
        .chunks => |plan| chunks: {
            var concrete = storage.responseChunkWriter(plan.encoded_bytes_max);
            defer concrete.abort();
            var writer = application_chunk_output.bind(&concrete);
            break :chunks App.__prepareBodyWithChunks(
                &request.workspace,
                decoded,
                trailers,
                request_workspace,
                storage.json_hash_key,
                &request.workspace.response_head_bytes,
                &writer,
                storage.htmlJsonScratch(plan.json_scratch_bytes_max),
                &storage.response_gzip_workspace,
            );
        },
    };
}

fn prepareBodyPayload(comptime App: type) type {
    const function = @typeInfo(@TypeOf(App.__prepareBodyWithResponseGzip)).@"fn";
    const result = @typeInfo(function.return_type.?).error_union;
    return result.payload;
}

fn feedMultipartFixedProgress(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    input: []const u8,
) Error!FeedResult {
    const request = &storage.requests[request_index];
    if (request.body.receiver.complete()) return error.StateInvariant;
    const remaining = request.body.receiver.expected() - request.body.receiver.progress();
    const body_length = @min(input.len, @as(usize, remaining));
    const parsed = try feedMultipartProgress(
        App,
        storage,
        request_index,
        input[0..body_length],
    );
    if (parsed.consumed > body_length) return error.StateInvariant;
    if (parsed.consumed != 0) {
        const advanced = request.body.receiver.feed(input[0..parsed.consumed]) catch {
            return error.StateInvariant;
        };
        if (advanced.body.len != parsed.consumed or advanced.tail.len != 0) {
            return error.StateInvariant;
        }
    }
    if (parsed.event != .need_more) return parsed;
    if (!request.body.receiver.complete()) return parsed;
    const finished = try finishMultipartProgress(App, storage, request_index, .{});
    return .{
        .consumed = parsed.consumed,
        .event = finished.event,
        .close_connection = finished.close_connection,
    };
}

fn feedMultipartProgress(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    data: []const u8,
) Error!FeedResult {
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const request = &storage.requests[request_index];
    const progress = App.__feedMultipartProgress(
        &request.workspace,
        workspace,
        data,
    ) catch |problem| return multipartProgressProblem(
        App,
        storage,
        request_index,
        problem,
    );
    if (progress.consumed > data.len) return error.StateInvariant;
    return .{
        .consumed = progress.consumed,
        .event = switch (progress.flow) {
            .ready => .need_more,
            .paused => .upload_paused,
            .complete => return error.StateInvariant,
        },
    };
}

fn finishMultipartProgress(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    trailers: application.RequestTrailers,
) Error!FeedResult {
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const request = &storage.requests[request_index];
    if (App.__multipartParserFinished(&request.workspace)) {
        return prepareDecoded(App, storage, request_index, trailers, .none);
    }
    const progress = App.__finishMultipartProgress(
        &request.workspace,
        workspace,
    ) catch |problem| return multipartProgressProblem(
        App,
        storage,
        request_index,
        problem,
    );
    if (progress.consumed != 0) return error.StateInvariant;
    return switch (progress.flow) {
        .paused => .{ .consumed = 0, .event = .upload_paused },
        .complete => prepareDecoded(App, storage, request_index, trailers, .none),
        .ready => error.StateInvariant,
    };
}

fn asyncUploads(comptime App: type) bool {
    return @hasDecl(App, "upload_async_sink_present") and App.upload_async_sink_present;
}

fn feedMultipart(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    data: []const u8,
) Error!FeedResult {
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const request = &storage.requests[request_index];
    App.__feedMultipart(&request.workspace, workspace, data) catch |problem| {
        var result = try multipartProgressProblem(App, storage, request_index, problem);
        result.consumed = data.len;
        return result;
    };
    return .{ .consumed = data.len, .event = .need_more };
}

fn finishMultipart(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    trailers: application.RequestTrailers,
) Error!FeedResult {
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const request = &storage.requests[request_index];
    App.__finishMultipart(&request.workspace, workspace) catch |problem| {
        return multipartProgressProblem(App, storage, request_index, problem);
    };
    return prepareDecoded(App, storage, request_index, trailers, .none);
}

fn multipartProblem(problem: anytype) Error!Event {
    if (problem == error.InvalidMultipart or problem == error.InvalidField) {
        return .invalid_input;
    }
    if (problem == error.LimitExceeded) return .input_too_large;
    if (problem == error.UnsupportedMedia) return .unsupported_media;
    if (problem == error.InvariantViolation) return error.StateInvariant;
    return error.ApplicationFailure;
}

fn multipartProgressProblem(
    comptime App: type,
    storage: anytype,
    request_index: u16,
    problem: anytype,
) Error!FeedResult {
    const request = &storage.requests[request_index];
    const workspace = storage.bodyWorkspace(request_index) catch {
        return error.StateInvariant;
    };
    const source = App.__multipartTerminalSource(
        &request.workspace,
        workspace,
    ) catch return error.StateInvariant;
    return switch (source) {
        .application, .rejection => selectedTerminalResponse(
            App,
            storage,
            request_index,
        ),
        .sink => body_finalization.failedResponse(App, storage, request_index),
        .fatal => error.StateInvariant,
        .parser, .none => .{
            .consumed = 0,
            .event = try multipartProblem(problem),
        },
    };
}

fn selectedTerminalResponse(
    comptime App: type,
    storage: anytype,
    request_index: u16,
) Error!FeedResult {
    var result = try prepareDecoded(App, storage, request_index, .{}, .none);
    result.close_connection = true;
    return result;
}

fn finalTrailers(
    storage: anytype,
    request_index: u16,
    ready: connection_chunked_body.ReadyTrailers,
) Error!application.RequestTrailers {
    const state = storage.chunkedState(request_index) catch return error.StateInvariant;
    const owned = state.trailers() orelse return error.StateInvariant;
    if (!sameSlice(ready.bytes, owned.bytes)) return error.StateInvariant;
    if (!sameSlice(ready.fields, owned.fields)) return error.StateInvariant;
    for (ready.fields) |field| {
        if (!validSpan(field.name, ready.bytes.len)) return error.StateInvariant;
        if (!validSpan(field.raw_value, ready.bytes.len)) return error.StateInvariant;
        if (!validSpan(field.value, ready.bytes.len)) return error.StateInvariant;
    }
    return .{ .section = ready.bytes };
}

fn sameSlice(left: anytype, right: @TypeOf(left)) bool {
    return left.len == right.len and
        @intFromPtr(left.ptr) == @intFromPtr(right.ptr);
}

fn validSpan(span: request_head.Span, bytes_len: usize) bool {
    const start: usize = span.offset;
    const length: usize = span.length;
    const end = std.math.add(usize, start, length) catch return false;
    return end <= bytes_len;
}
