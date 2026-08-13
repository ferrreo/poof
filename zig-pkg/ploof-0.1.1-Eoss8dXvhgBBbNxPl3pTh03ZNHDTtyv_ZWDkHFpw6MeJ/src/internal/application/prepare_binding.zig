const std = @import("std");
const body = @import("../../body.zig");
const chunk_output = @import("chunk_output.zig");
const application_types = @import("types.zig");

pub fn Configured(
    comptime State: type,
    comptime Workspace: type,
    comptime RequestTrailers: type,
    comptime Plan: type,
    comptime ResponseGzipWorkspace: type,
    comptime PrepareError: type,
    comptime HeadResult: type,
    comptime Prepared: type,
    comptime prepare_head: fn (
        *State,
        *Workspace,
        []u8,
        []u8,
        *const Plan,
        application_types.HeadPolicy,
    ) PrepareError!HeadResult,
    comptime prepare_body: fn (
        *Workspace,
        body.Decoded,
        RequestTrailers,
        []u8,
        [16]u8,
        []u8,
    ) PrepareError!Prepared,
) type {
    return struct {
        pub fn headGzip(
            state: *State,
            workspace: *Workspace,
            request_workspace: []u8,
            output: []u8,
            request_plan: *const Plan,
            policy: application_types.HeadPolicy,
            gzip: *ResponseGzipWorkspace,
        ) PrepareError!HeadResult {
            workspace.response_gzip.bind(gzip);
            defer workspace.response_gzip.clear();
            return prepare_head(
                state,
                workspace,
                request_workspace,
                output,
                request_plan,
                policy,
            );
        }

        pub fn bodyGzip(
            workspace: *Workspace,
            decoded: body.Decoded,
            trailers: RequestTrailers,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            output: []u8,
            gzip: *ResponseGzipWorkspace,
        ) PrepareError!Prepared {
            workspace.response_gzip.bind(gzip);
            defer workspace.response_gzip.clear();
            return prepare_body(
                workspace,
                decoded,
                trailers,
                request_workspace,
                json_hash_key,
                output,
            );
        }

        pub fn headChunks(
            state: *State,
            workspace: *Workspace,
            request_workspace: []u8,
            output: []u8,
            request_plan: *const Plan,
            policy: application_types.HeadPolicy,
            chunks: *chunk_output.Writer,
            scratch: []u8,
            gzip: *ResponseGzipWorkspace,
        ) PrepareError!HeadResult {
            workspace.finite_output.bind(chunks, scratch);
            defer workspace.finite_output.clear();
            return headGzip(
                state,
                workspace,
                request_workspace,
                output,
                request_plan,
                policy,
                gzip,
            );
        }

        pub fn bodyChunks(
            workspace: *Workspace,
            decoded: body.Decoded,
            trailers: RequestTrailers,
            request_workspace: []u8,
            json_hash_key: [16]u8,
            output: []u8,
            chunks: *chunk_output.Writer,
            scratch: []u8,
            gzip: *ResponseGzipWorkspace,
        ) PrepareError!Prepared {
            workspace.finite_output.bind(chunks, scratch);
            defer workspace.finite_output.clear();
            return bodyGzip(
                workspace,
                decoded,
                trailers,
                request_workspace,
                json_hash_key,
                output,
                gzip,
            );
        }
    };
}

pub fn scrubHead(workspace: anytype, head: []const u8) void {
    const output = workspace.response_head_bytes[0..];
    std.debug.assert(head.len <= output.len);
    std.debug.assert(head.len == 0 or @intFromPtr(head.ptr) == @intFromPtr(output.ptr));
    std.crypto.secureZero(u8, output);
}
