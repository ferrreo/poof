pub fn Bridge(
    comptime enabled: bool,
    comptime DriverError: type,
    comptime Event: type,
    comptime BodyTransport: type,
) type {
    return struct {
        pub fn beginRegistry(
            driver: anytype,
            entropy: *const [32]u8,
            now_ns: u64,
        ) DriverError!Event {
            return driver.uploads.beginRegistryStartAt(
                driver.storage,
                driver.operations.io,
                entropy,
                now_ns,
            ) catch return error.UploadFailure;
        }

        pub fn submitPaused(
            driver: anytype,
            request_index: u16,
            now_ns: u64,
        ) DriverError!void {
            if (comptime !enabled) return error.StateInvariant;
            const event = driver.uploads.submitParserWorkAt(
                driver.storage,
                driver.operations.io,
                request_index,
                now_ns,
            ) catch return error.UploadFailure;
            switch (event) {
                .none => {},
                .request_resumed => |resumed| try BodyTransport.resumeUpload(
                    driver,
                    resumed,
                    now_ns,
                ),
                .request_rejected => |rejected| try rejectParser(
                    driver,
                    rejected,
                    now_ns,
                ),
                .request_finalized => |finalized| {
                    const connection = &driver.storage.connections[
                        finalized.connection_index
                    ];
                    if (connection.phase != .closing) {
                        try BodyTransport.finishUploadFinalization(
                            driver,
                            finalized,
                            now_ns,
                        );
                    }
                    if (connection.phase == .closing) {
                        try driver.maybeRelease(finalized.connection_index);
                    }
                },
                .registry_ready, .registry_stopped => return error.UploadFailure,
            }
        }

        pub fn abortRequest(
            driver: anytype,
            connection_index: u16,
            outcome: anytype,
        ) DriverError!void {
            if (comptime !enabled) return;
            const connection = &driver.storage.connections[connection_index];
            const request_index = connection.active_request orelse return;
            if (!driver.storage.requests[request_index].body.multipart) return;
            const event = driver.uploads.beginRequestAbort(
                driver.storage,
                driver.operations.io,
                request_index,
                if (outcome == .peer_aborted) .peer_disconnect else .framework_canceled,
            ) catch return error.UploadFailure;
            switch (event) {
                .none, .request_finalized => {},
                .registry_ready, .registry_stopped, .request_resumed, .request_rejected => {
                    return error.UploadFailure;
                },
            }
        }

        pub fn stopRegistry(driver: anytype, now_ns: u64) DriverError!Event {
            return driver.uploads.beginRegistryStopAt(
                driver.storage,
                driver.operations.io,
                now_ns,
            ) catch return error.UploadFailure;
        }

        pub fn handle(
            driver: anytype,
            completion: anytype,
            now_ns: u64,
        ) DriverError!Event {
            if (comptime !enabled) return error.InvalidCompletion;
            const event = driver.uploads.completeAt(
                driver.storage,
                driver.operations.io,
                completion,
                now_ns,
            ) catch return error.UploadFailure;
            switch (event) {
                .request_resumed => |resumed| try BodyTransport.resumeUpload(
                    driver,
                    resumed,
                    now_ns,
                ),
                .request_rejected => |rejected| try rejectParser(
                    driver,
                    rejected,
                    now_ns,
                ),
                .request_finalized => |finalized| {
                    const connection = &driver.storage.connections[finalized.connection_index];
                    if (connection.phase != .closing) {
                        try BodyTransport.finishUploadFinalization(
                            driver,
                            finalized,
                            now_ns,
                        );
                    }
                    if (connection.phase == .closing) {
                        try driver.maybeRelease(finalized.connection_index);
                    }
                },
                else => {},
            }
            return event;
        }

        fn rejectParser(driver: anytype, rejected: anytype, now_ns: u64) DriverError!void {
            const connection = &driver.storage.connections[rejected.connection_index];
            if (connection.active_request != rejected.request_index or
                !connection.receive_flags.upload_paused or
                !connection.receive_flags.paused)
            {
                return error.StateInvariant;
            }
            return BodyTransport.rejectParser(
                driver,
                rejected.connection_index,
                switch (rejected.status) {
                    .bad_request => .bad_request,
                    .payload_too_large => .payload_too_large,
                    .unsupported_media_type => .unsupported_media_type,
                },
                now_ns,
            );
        }

        pub fn registryReady(driver: anytype) bool {
            return driver.uploads.registryReady();
        }

        pub fn registryStopped(driver: anytype) bool {
            return driver.uploads.registryStopped();
        }

        pub fn pending(driver: anytype) u32 {
            return driver.uploads.pending();
        }

        pub fn ownershipProven(driver: anytype) bool {
            return driver.uploads.ownershipProven();
        }

        pub fn activeHandles(driver: anytype) u32 {
            return driver.uploads.activeHandles();
        }

        pub fn metricsSnapshot(
            driver: anytype,
        ) @import("../worker/metrics.zig").UploadMetricsSnapshot {
            return driver.uploads.metricsSnapshot();
        }

        pub fn routeMetricsSnapshot(
            driver: anytype,
            route_id: u16,
        ) ?@import("../worker/upload_transport.zig").RouteMetricsSnapshot {
            return driver.uploads.routeMetricsSnapshot(route_id);
        }

        pub fn startupDiagnostic(
            driver: anytype,
        ) @TypeOf(driver.uploads.startupDiagnostic()) {
            return driver.uploads.startupDiagnostic();
        }

        pub fn recordFinalization(driver: anytype, request_index: u16) DriverError!void {
            driver.uploads.recordFinalizationIfTerminal(
                driver.storage,
                request_index,
            ) catch return error.UploadFailure;
        }

        pub fn retireRequest(driver: anytype, request_index: u16) DriverError!void {
            driver.uploads.retireRequest(
                driver.storage,
                request_index,
            ) catch return error.UploadFailure;
        }

        pub fn retireAllRequests(driver: anytype) DriverError!void {
            driver.uploads.retireAllRequests() catch return error.UploadFailure;
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
