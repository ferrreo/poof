const application = @import("../../../application.zig");

const server_metrics_request = @import("../server/metrics_request.zig");
const worker_metrics_lease = @import("../worker/metrics_lease.zig");

pub fn Transport(
    comptime App: type,
    comptime Storage: type,
    comptime TransportError: type,
    comptime BodyTransport: type,
    comptime ResponseTransport: type,
) type {
    _ = Storage;
    const enabled = @hasDecl(App, "open_metrics_enabled") and App.open_metrics_enabled;
    return struct {
        pub fn begin(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            deferred: application.DeferredMetrics,
            unread_body: bool,
            close_connection: bool,
            tail: []const u8,
            source: anytype,
            now_ns: u64,
        ) TransportError!void {
            if (comptime !enabled) unreachable;
            if (!close_connection and
                !try BodyTransport.preserveTail(driver, connection_index, tail, source))
            {
                return;
            }
            const wake = driver.storage.stream_wakes.activate(request_index) catch {
                return resumeUnavailable(
                    driver,
                    connection_index,
                    request_index,
                    deferred,
                    unread_body,
                    now_ns,
                );
            };
            const request = &driver.storage.requests[request_index];
            const claim = driver.metrics_runtime.claimAt(now_ns, .{
                .worker_index = driver.operations.worker_index,
                .request_index = request_index,
                .request_generation = request.generation,
                .stream_generation = wake.generation(),
            });
            const ticket = switch (claim) {
                .accepted => |accepted| accepted,
                .busy, .stopping, .deadline_overflow => {
                    const invalidated = driver.storage.stream_wakes.invalidateBeforeAbort(wake);
                    if (invalidated != .invalidated) return error.StateInvariant;
                    return resumeUnavailable(
                        driver,
                        connection_index,
                        request_index,
                        deferred,
                        unread_body,
                        now_ns,
                    );
                },
            };
            request.metrics.start(ticket, wake.generation(), deferred.route_id);
            switch (driver.storage.stream_wakes.markPendingIdentity(
                request_index,
                wake.generation(),
            )) {
                .pending, .ready => {},
                .stale => return error.StateInvariant,
            }
            const connection = &driver.storage.connections[connection_index];
            connection.close_after_response = close_connection;
            connection.phase = .responding;
            try driver.operations.cancelReceive(driver.storage, connection_index);
            try driver.operations.cancelTimeout(driver.storage, connection_index);
        }

        pub fn handleReady(
            driver: anytype,
            request_index: u16,
            now_ns: u64,
        ) TransportError!void {
            if (comptime !enabled) return;
            if (request_index >= driver.storage.requests.len) return;
            const request = &driver.storage.requests[request_index];
            if (request.phase != .live or request.metrics.phase == .idle or
                request.metrics.phase == .responding)
            {
                return;
            }
            switch (driver.storage.stream_wakes.claimReadyIdentity(
                request_index,
                request.metrics.stream_generation,
            )) {
                .not_ready => return,
                .stale => return error.StateInvariant,
                .claimed => {},
            }
            switch (driver.metrics_runtime.poll(request.metrics.ticket())) {
                .pending => switch (driver.storage.stream_wakes.markPendingIdentity(
                    request_index,
                    request.metrics.stream_generation,
                )) {
                    .pending, .ready => return,
                    .stale => return error.StateInvariant,
                },
                .success => |body| try resumeReady(
                    driver,
                    request_index,
                    .{ .success = body },
                    now_ns,
                ),
                .unavailable => try resumeReady(driver, request_index, .unavailable, now_ns),
                .stale => {
                    if (request.metrics.phase != .canceling) return error.StateInvariant;
                    try invalidate(driver, request_index);
                    request.metrics.clear();
                    try driver.maybeRelease(request.connection_index);
                },
            }
        }

        pub fn cancelForClose(driver: anytype, connection_index: u16) TransportError!bool {
            if (comptime !enabled) return true;
            const request_index = driver.storage.connections[connection_index]
                .active_request orelse return true;
            const request = &driver.storage.requests[request_index];
            return switch (request.metrics.phase) {
                .idle, .responding => true,
                .canceling => false,
                .waiting => switch (driver.metrics_runtime.cancel(request.metrics.ticket())) {
                    .pending => pending: {
                        request.metrics.beginCancel();
                        break :pending false;
                    },
                    .cancelled, .stale => settled: {
                        try invalidate(driver, request_index);
                        request.metrics.clear();
                        break :settled true;
                    },
                },
            };
        }

        pub fn releaseAtTerminal(driver: anytype, request_index: u16) TransportError!void {
            if (comptime !enabled) return;
            const metrics = &driver.storage.requests[request_index].metrics;
            switch (metrics.phase) {
                .idle => {},
                .responding => {
                    if (!driver.metrics_runtime.release(metrics.ticket())) {
                        return error.StateInvariant;
                    }
                    metrics.clear();
                },
                .waiting, .canceling => return error.StateInvariant,
            }
        }

        pub fn requestReleaseReady(driver: anytype, connection_index: u16) bool {
            if (comptime !enabled) return true;
            const request_index = driver.storage.connections[connection_index]
                .active_request orelse return true;
            return switch (driver.storage.requests[request_index].metrics.phase) {
                .idle, .responding => true,
                .waiting, .canceling => false,
            };
        }

        pub fn prepareFatal(driver: anytype) bool {
            if (comptime !enabled) return true;
            for (driver.storage.requests, 0..) |*request, request_index| {
                if (request.phase != .live) continue;
                switch (request.metrics.phase) {
                    .idle, .responding => {},
                    .waiting, .canceling => {
                        if (driver.storage.stream_wakes.invalidateIdentityBeforeAbort(
                            @intCast(request_index),
                            request.metrics.stream_generation,
                        ) != .invalidated) return false;
                        _ = driver.metrics_runtime.cancel(request.metrics.ticket());
                        request.metrics.clear();
                    },
                }
            }
            return true;
        }

        pub fn finishFatal(driver: anytype) bool {
            if (comptime !enabled) return true;
            for (driver.storage.requests) |*request| {
                if (request.phase != .live or request.metrics.phase != .responding) continue;
                if (!driver.metrics_runtime.release(request.metrics.ticket())) return false;
                request.metrics.clear();
            }
            return true;
        }

        fn resumeReady(
            driver: anytype,
            request_index: u16,
            result: application.MetricsResult,
            now_ns: u64,
        ) TransportError!void {
            const request = &driver.storage.requests[request_index];
            if (request.metrics.phase != .waiting) return error.StateInvariant;
            try invalidate(driver, request_index);
            const deferred = application.DeferredMetrics{ .route_id = request.metrics.route_id };
            request.metrics.beginResponse();
            const prepared = App.__resumeMetrics(
                &request.workspace,
                deferred,
                result,
                driver.storage.responseWritable(request_index),
            ) catch {
                if (!driver.metrics_runtime.release(request.metrics.ticket())) {
                    return error.StateInvariant;
                }
                request.metrics.clear();
                try driver.beginClose(request.connection_index);
                return error.StateInvariant;
            };
            try ResponseTransport.begin(
                driver,
                request.connection_index,
                request_index,
                prepared,
                false,
                &.{},
                .pipeline,
                now_ns,
            );
        }

        fn resumeUnavailable(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            deferred: application.DeferredMetrics,
            unread_body: bool,
            now_ns: u64,
        ) TransportError!void {
            const request = &driver.storage.requests[request_index];
            const prepared = App.__resumeMetrics(
                &request.workspace,
                deferred,
                .unavailable,
                driver.storage.responseWritable(request_index),
            ) catch return error.StateInvariant;
            try ResponseTransport.begin(
                driver,
                connection_index,
                request_index,
                prepared,
                unread_body,
                &.{},
                .pipeline,
                now_ns,
            );
        }

        fn invalidate(driver: anytype, request_index: u16) TransportError!void {
            const request = &driver.storage.requests[request_index];
            if (driver.storage.stream_wakes.invalidateIdentityBeforeAbort(
                request_index,
                request.metrics.stream_generation,
            ) != .invalidated) return error.StateInvariant;
        }
    };
}

test {
    _ = server_metrics_request;
    _ = worker_metrics_lease;
}
