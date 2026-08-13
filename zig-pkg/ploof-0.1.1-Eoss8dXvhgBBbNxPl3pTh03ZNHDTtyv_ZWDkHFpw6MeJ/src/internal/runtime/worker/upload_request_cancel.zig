const reactor = @import("../reactor.zig");
const support = @import("upload_request_support.zig");
const upload_metrics = @import("upload_metrics.zig");

pub fn cancelApplicationTargets(
    comptime Error: type,
    transport: anytype,
    metrics: anytype,
    worker_index: u16,
    io: anytype,
    request: anytype,
    state: anytype,
    failure_identity: *?upload_metrics.Identity,
) Error!void {
    var cancelable = false;
    for (&state.entries) |*entry| {
        if (!entry.active or entry.mode != .application or entry.cancel_submitted) continue;
        cancelable = true;
        failure_identity.* = .{
            .registry_index = entry.registry_index,
            .instance_index = entry.instance_index,
        };
        const fields = entry.target.fields() catch {
            metrics.recordCancellation(.failed);
            return error.StateInvariant;
        };
        const cancel = support.requestToken(
            worker_index,
            fields.slot_index,
            request,
            .upload_cancel,
        ) catch {
            metrics.recordCancellation(.failed);
            return error.StateInvariant;
        };
        const prepared = transport.prepareCancel(entry.target, cancel) catch {
            metrics.recordCancellation(.failed);
            return error.TransportFailure;
        };
        io.submit(prepared) catch {
            const delivery = transport.rollback(cancel) catch {
                metrics.recordCancellation(.failed);
                return error.TransportFailure;
            };
            metrics.recordCancellation(.failed);
            if (delivery != null) return error.TransportFailure;
            return error.BackendFailure;
        };
        transport.markSubmitted(cancel) catch {
            metrics.recordCancellation(.failed);
            return error.TransportFailure;
        };
        request.sequence = reactor.nextSequence(request.sequence);
        entry.cancel_submitted = true;
        failure_identity.* = null;
    }
    if (!state.cancellation_decided) {
        state.cancellation_decided = true;
        if (!cancelable) metrics.recordCancellation(.not_required);
    }
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}
