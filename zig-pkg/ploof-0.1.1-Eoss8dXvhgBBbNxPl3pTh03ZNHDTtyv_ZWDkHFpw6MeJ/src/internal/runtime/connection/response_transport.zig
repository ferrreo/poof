const application = @import("../../../application.zig");
const connection_body_transport = @import("body_transport.zig");
const connection_response_stream = @import("response_stream.zig");
const reactor = @import("../reactor.zig");
const worker_response_staging = @import("../worker/response_staging.zig");

/// Owns prepared response staging and application completion boundaries.
pub fn Transport(
    comptime App: type,
    comptime Storage: type,
    comptime TransportError: type,
) type {
    return struct {
        const BodyTransport = connection_body_transport.Transport(
            App,
            Storage,
            TransportError,
        );
        const StreamTransport = connection_response_stream.Transport(
            App,
            Storage,
            TransportError,
        );
        const InputSource = connection_body_transport.InputSource;

        pub fn begin(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            prepared: application.Prepared,
            unread_body: bool,
            tail: []const u8,
            source: InputSource,
            now_ns: u64,
        ) TransportError!void {
            defer worker_response_staging.scrub(App, &driver.storage.requests[
                request_index
            ].workspace, prepared);
            var release_chain = prepared.source == .finite_chain;
            defer if (release_chain) switch (prepared.source) {
                .finite_chain => |finite| driver.storage.discardResponseChunks(finite.body),
                .contiguous_wire, .borrowed_static, .live_static, .live_static_file => unreachable,
            };
            if (unread_body and !prepared.close_connection) {
                try driver.beginClose(connection_index);
                return error.StateInvariant;
            }
            if (!prepared.close_connection) {
                if (!try BodyTransport.preserveTail(
                    driver,
                    connection_index,
                    tail,
                    source,
                )) return;
            }
            switch (prepared.source) {
                .live_static => |intent| if (comptime typeHasField(
                    @TypeOf(driver.*),
                    "live_static",
                )) return driver.live_static.beginRequest(
                    driver,
                    connection_index,
                    request_index,
                    intent,
                    now_ns,
                ) else return error.StateInvariant,
                .live_static_file => return error.StateInvariant,
                else => {},
            }
            switch (prepared.transmission) {
                .finite => {
                    if (!commitFinite(driver, request_index, prepared)) {
                        try driver.beginClose(connection_index);
                        return error.StateInvariant;
                    }
                    release_chain = false;
                    try BodyTransport.beginFinal(
                        driver,
                        connection_index,
                        prepared.close_connection,
                        now_ns,
                    );
                },
                .stream => {
                    if (prepared.source != .contiguous_wire) {
                        try driver.beginClose(connection_index);
                        return error.StateInvariant;
                    }
                    driver.storage.connections[connection_index].close_after_response =
                        prepared.close_connection;
                    try StreamTransport.begin(
                        driver,
                        connection_index,
                        request_index,
                        prepared,
                        now_ns,
                    );
                },
            }
        }

        fn commitFinite(
            driver: anytype,
            request_index: u16,
            prepared: application.Prepared,
        ) bool {
            return switch (prepared.source) {
                .finite_chain => |finite| driver.storage.commitResponseChunks(
                    request_index,
                    finite.head,
                    finite.body,
                ),
                .contiguous_wire => |wire| driver.storage.commitResponse(
                    request_index,
                    wire,
                ) or driver.storage.commitExternalResponse(request_index, wire),
                .borrowed_static => |borrowed| if (borrowed.body.len == 0)
                    driver.storage.commitResponse(request_index, borrowed.head)
                else
                    driver.storage.commitStaticResponse(
                        request_index,
                        borrowed.head,
                        borrowed.body,
                    ),
                .live_static, .live_static_file => false,
            };
        }

        pub fn complete(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) TransportError!void {
            if (comptime typeHasField(@TypeOf(driver.*), "live_static")) {
                if (try driver.live_static.responseBufferComplete(
                    driver,
                    connection_index,
                    now_ns,
                )) return;
            }
            return completeAfterLive(driver, connection_index, now_ns);
        }

        pub fn completeAfterLive(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) TransportError!void {
            if (try StreamTransport.completeBuffer(driver, connection_index, now_ns)) return;
            const connection = &driver.storage.connections[connection_index];
            if (try driver.completeObservedFallback(connection_index)) {
                connection.pipeline_read = connection.pipeline_write;
            } else if (connection.active_request) |request_index| {
                const request = &driver.storage.requests[request_index];
                const outcome = terminal: {
                    if (request.flags.upload_rejection_pending) {
                        request.flags.upload_rejection_pending = false;
                        break :terminal App.__abortWithTransport(
                            &request.workspace,
                            .completed,
                        ) catch return error.StateInvariant;
                    }
                    break :terminal App.complete(&request.workspace) catch
                        return error.StateInvariant;
                };
                driver.observation.finish(request_index, outcome) catch
                    return error.StateInvariant;
                try driver.releaseRequest(connection_index, request_index);
            } else {
                connection.pipeline_read = connection.pipeline_write;
            }
            if (connection.close_after_response) {
                try driver.beginClose(connection_index);
                return;
            }
            try driver.maybeContinue(connection_index, now_ns);
        }

        pub fn cancelLiveStatic(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
        ) TransportError!void {
            if (comptime typeHasField(@TypeOf(driver.*), "live_static")) {
                return driver.live_static.cancelConnection(
                    driver,
                    connection_index,
                    outcome,
                );
            }
        }

        pub fn liveStaticActive(driver: anytype, connection_index: u16) bool {
            if (comptime typeHasField(@TypeOf(driver.*), "live_static")) {
                return driver.live_static.activeForConnection(
                    driver.storage,
                    connection_index,
                );
            }
            return false;
        }

        pub fn settleLiveStaticSendDuringClose(
            driver: anytype,
            connection_index: u16,
            buffer_complete: bool,
            now_ns: u64,
        ) TransportError!bool {
            if (comptime typeHasField(@TypeOf(driver.*), "live_static")) {
                return driver.live_static.sendCompletedDuringClose(
                    driver,
                    connection_index,
                    buffer_complete,
                    now_ns,
                );
            }
            return false;
        }

        pub fn handleStreamReady(
            driver: anytype,
            request_index: u16,
            now_ns: u64,
        ) TransportError!void {
            return StreamTransport.handleReady(driver, request_index, now_ns);
        }

        pub fn pollDeferredStream(
            driver: anytype,
            connection_index: u16,
            now_ns: u64,
        ) TransportError!void {
            return StreamTransport.pollDeferred(driver, connection_index, now_ns);
        }

        pub fn cancelStream(
            driver: anytype,
            connection_index: u16,
            outcome: application.TransportOutcome,
            now_ns: u64,
        ) TransportError!void {
            return StreamTransport.cancelActive(driver, connection_index, outcome, now_ns);
        }

        pub fn streamActive(driver: anytype, connection_index: u16) bool {
            return StreamTransport.active(driver, connection_index);
        }

        pub fn streamBufferCompletionWinsClose(
            driver: anytype,
            connection_index: u16,
        ) bool {
            return StreamTransport.bufferCompletionWinsClose(driver, connection_index);
        }

        pub fn streamOperationCompleted(
            driver: anytype,
            connection_index: u16,
            kind: reactor.OperationKind,
            sequence: u16,
        ) void {
            StreamTransport.operationCompleted(driver, connection_index, kind, sequence);
        }
    };
}

fn typeHasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, name),
        else => false,
    };
}
