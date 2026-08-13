const std = @import("std");
const application = @import("../../../application.zig");
const body = @import("../../../body.zig");
const connection_body_feed = @import("body_feed.zig");
const connection_body_runtime = @import("body_runtime.zig");
const connection_chunked_body = @import("chunked_body.zig");
const request_content = @import("../../http1/request_content.zig");
const request_framing = @import("../../http1/request_framing.zig");

pub fn Bridge(
    comptime App: type,
    comptime Storage: type,
    comptime DriverError: type,
    comptime InputSource: type,
    comptime GzipTransport: type,
    comptime Parent: type,
) type {
    const runtime_limits = Storage.runtime_limits;
    const ChunkedState = connection_chunked_body.Receiver(runtime_limits.chunked);
    const TrailerDeclarations = ChunkedState.TrailerDeclarations;

    return struct {
        pub fn beginAfterHead(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            coding: request_content.Coding,
            multipart_boundary: ?[]const u8,
            framing: request_framing.BodyFraming,
            trailer_declarations: TrailerDeclarations,
            stable_head_bytes: []const u8,
            expect_continue: bool,
            tail: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            if (coding == .gzip) return GzipTransport.beginAfterHead(
                driver,
                connection_index,
                request_index,
                plan,
                multipart_boundary,
                framing,
                trailer_declarations,
                stable_head_bytes,
                expect_continue,
                tail,
                source,
                now_ns,
            );
            const requires_chunked = std.meta.activeTag(framing) == .chunked;
            if (!try connection_body_feed.acquireBody(
                App,
                DriverError,
                driver,
                connection_index,
                request_index,
                plan,
                requires_chunked,
                now_ns,
            )) return;
            return begin(
                driver,
                connection_index,
                request_index,
                plan,
                multipart_boundary,
                framing,
                trailer_declarations,
                stable_head_bytes,
                expect_continue,
                tail,
                source,
                now_ns,
            );
        }

        pub fn begin(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            framing: request_framing.BodyFraming,
            trailer_declarations: TrailerDeclarations,
            stable_head_bytes: []const u8,
            expect_continue: bool,
            tail: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const kind: body.Kind = switch (plan.kind) {
                .bytes => .bytes,
                .text => .text,
                .input => .none,
                .structured => switch (plan.decoderKind() orelse {
                    return error.StateInvariant;
                }) {
                    .text => .text,
                    .bytes, .json, .form, .multipart => .bytes,
                },
                .none => return error.StateInvariant,
            };
            return switch (framing) {
                .none => beginFixed(
                    driver,
                    connection_index,
                    request_index,
                    plan,
                    multipart_boundary,
                    0,
                    kind,
                    expect_continue,
                    tail,
                    source,
                    now_ns,
                ),
                .fixed => |length| beginFixed(
                    driver,
                    connection_index,
                    request_index,
                    plan,
                    multipart_boundary,
                    length,
                    kind,
                    expect_continue,
                    tail,
                    source,
                    now_ns,
                ),
                .chunked => beginChunked(
                    driver,
                    connection_index,
                    request_index,
                    plan,
                    multipart_boundary,
                    kind,
                    trailer_declarations,
                    stable_head_bytes,
                    expect_continue,
                    tail,
                    source,
                    now_ns,
                ),
            };
        }

        fn beginFixed(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            length: u64,
            kind: body.Kind,
            expect_continue: bool,
            tail: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const receiver = try connection_body_feed.startFixed(
                App,
                DriverError,
                driver,
                request_index,
                plan,
                multipart_boundary,
                length,
                kind,
            );
            driver.storage.connections[connection_index].phase = .receiving_body;
            if (receiver.complete()) {
                const finished = if (plan.decoderKind() == .multipart)
                    connection_body_runtime.finishMultipartFixed(
                        App,
                        driver.storage,
                        request_index,
                    )
                else
                    connection_body_runtime.finish(App, driver.storage, request_index);
                const resolved = finished catch |problem| {
                    try Parent.handleRuntimeError(driver, connection_index, problem, now_ns);
                    return;
                };
                try Parent.applyResult(
                    driver,
                    connection_index,
                    tail,
                    source,
                    resolved,
                    now_ns,
                );
            } else if (expect_continue and tail.len < receiver.expected()) {
                try Parent.beginContinue(driver, connection_index, now_ns);
                if (tail.len != 0) {
                    try Parent.consume(driver, connection_index, tail, source, now_ns);
                }
            } else {
                try driver.operations.retargetTimeout(
                    driver.storage,
                    connection_index,
                    now_ns,
                    runtime_limits.timeouts.body_inactivity_ns,
                );
                if (tail.len != 0) {
                    try Parent.consume(driver, connection_index, tail, source, now_ns);
                }
            }
        }

        fn beginChunked(
            driver: anytype,
            connection_index: u16,
            request_index: u16,
            plan: application.BodyPlan,
            multipart_boundary: ?[]const u8,
            kind: body.Kind,
            declarations: TrailerDeclarations,
            head_bytes: []const u8,
            expect_continue: bool,
            tail: []const u8,
            source: InputSource,
            now_ns: u64,
        ) DriverError!void {
            const state = driver.storage.chunkedState(request_index) catch {
                return error.StateInvariant;
            };
            state.* = ChunkedState.init(
                plan.encoded_wire_bytes_max,
                plan.decoded_bytes_max,
                declarations,
                head_bytes,
            );
            if (plan.decoderKind() == .multipart) {
                connection_body_runtime.startMultipartChunked(
                    App,
                    driver.storage,
                    request_index,
                    multipart_boundary orelse return error.StateInvariant,
                ) catch return error.StateInvariant;
            } else {
                connection_body_runtime.startChunked(
                    driver.storage,
                    request_index,
                    kind,
                ) catch return error.StateInvariant;
            }
            const connection = &driver.storage.connections[connection_index];
            connection.phase = .receiving_body;
            if (expect_continue and tail.len == 0) {
                try Parent.beginContinue(driver, connection_index, now_ns);
                return;
            }
            try driver.operations.retargetTimeout(
                driver.storage,
                connection_index,
                now_ns,
                runtime_limits.timeouts.body_inactivity_ns,
            );
            if (tail.len == 0) return;
            try Parent.consumeChunked(
                driver,
                connection_index,
                request_index,
                tail,
                source,
                now_ns,
            );
            if (expect_continue and connection.phase == .receiving_body) {
                try Parent.beginContinue(driver, connection_index, now_ns);
            }
        }
    };
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
