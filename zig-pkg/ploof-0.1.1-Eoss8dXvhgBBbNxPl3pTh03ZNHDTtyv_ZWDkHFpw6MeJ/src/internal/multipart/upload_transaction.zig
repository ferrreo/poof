const std = @import("std");
const upload = @import("../../multipart/upload.zig");
const events = @import("events.zig");
const parser = @import("parser.zig");
const adapter = @import("upload_adapter.zig");
const layout = @import("upload_layout.zig");
const sink_driver = @import("../upload/sink_driver.zig");
const upload_finalizer = @import("../upload/finalizer.zig");
const transaction_lanes = @import("upload_transaction_lanes.zig");
const failure = @import("upload_transaction_failure.zig");
const transaction_schema = @import("upload_transaction_schema.zig");
const transaction_state = @import("upload_transaction_state.zig");
const transaction_types = @import("upload_transaction_types.zig");
const upload_window = @import("../upload/window.zig");

pub fn Transaction(comptime Spec: type, comptime Registry: type) type {
    const Storage = layout.Layout(Spec);
    const Mux = adapter.SinkMux(Spec, Registry);
    const Lifecycle = sink_driver.Lifecycle(Mux);
    const profile = Spec.resolved_options.upload;
    const Window = upload_window.Window(Mux, profile.chunk_bytes, profile.window);
    const Finalizer = upload_finalizer.Finalizer(Mux, Storage.non_discard_total_maximum);
    const Slot = @FieldType(Window.Submission, "slot");
    const Public = transaction_types.Types(Slot);
    const Lanes = transaction_lanes.Tracker(Slot, @as(usize, profile.window));
    const State = transaction_state.State(Spec);
    const schema_fields = @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields;

    return struct {
        const Self = @This();
        pub const Lane = Public.Lane;
        pub const FinalizationFlow = Public.FinalizationFlow;
        pub const Report = Finalizer.Report;
        pub const ReportRecord = struct {
            file: Spec.File,
            cleanup_failure: ?upload_finalizer.CleanupFailureClass,
        };
        pub const report_record_capacity: usize = Storage.non_discard_total_maximum;
        pub const FatalClass = Public.FatalClass;
        pub const Fatal = Public.Fatal;
        pub const FailureKind = transaction_types.FailureKind;
        pub const Error = Mux.Error || error{TransactionFatal};
        pub const Submission = transaction_state.Submission(Spec.File, Lane, upload.IoRequest);

        const Phase = State.Phase;
        const Active = State.Active;

        storage: Storage,
        runtime: Mux.Runtime,
        lifecycle: Lifecycle = .{},
        window: Window = .{},
        finalizer: Finalizer,
        records: [Storage.non_discard_total_maximum]Mux.State = undefined,
        occurrences: [schema_fields.len]u16 = @splat(0),
        record_count: usize = 0,
        active: ?Active = null,
        blocked_wait: ?parser.Wait = null,
        lanes: Lanes = .{},
        phase: Phase = .collecting,
        commit_ready: bool = false,
        abort_cause: ?upload_finalizer.UpstreamFailure = null,
        fatal_state: ?Fatal = null,
        anchor: ?*Self = null,

        pub fn init(registry: *Registry) Self {
            return .{
                .storage = Storage.init(),
                .runtime = .{ .registry = registry },
                .finalizer = Finalizer.init(),
            };
        }

        pub fn fileStartProgress(
            self: *Self,
            event: events.FileStart,
            begin_input: Spec.BeginInput,
        ) Error!parser.CallbackFlow {
            try self.guard();
            try self.requireStartReady(event.entry_index);
            const tag = transaction_schema.validateStart(
                Spec,
                &self.occurrences,
                event,
                begin_input,
            ) catch |problem| {
                const class: FatalClass = switch (problem) {
                    error.InvalidEntry => .invalid_entry,
                    error.InvalidOccurrence => .invalid_occurrence,
                    error.VariantMismatch => .variant_mismatch,
                };
                return self.fail(class, event.entry_index, null);
            };
            const discard = Mux.isDiscard(tag);
            const record_index = if (discard) null else try self.record(tag, event.occurrence);
            self.occurrences[event.entry_index] = event.occurrence;
            self.active = .{
                .tag = tag,
                .entry_index = event.entry_index,
                .occurrence = event.occurrence,
                .record_index = record_index,
                .discard = discard,
                .phase = if (discard) .body else .begin,
            };
            if (discard) return .ready;
            const state = self.activeState();
            const poll = self.lifecycle.startBegin(
                &self.runtime,
                state,
                begin_input,
            ) catch |problem| return self.lifecycleFailure(problem);
            return switch (poll) {
                .done => done: {
                    self.active.?.phase = .body;
                    break :done .ready;
                },
                .request => |request| paused: {
                    try self.putOutbox(.lifecycle, request);
                    self.blocked_wait = .file_start;
                    break :paused .paused;
                },
            };
        }

        pub fn fileChunkProgress(
            self: *Self,
            event: events.FileChunk,
        ) Error!parser.ChunkProgress {
            try self.guard();
            const active = try self.requireFileEvent(
                event.entry_index,
                event.occurrence,
                .body,
            );
            if (self.blocked_wait != null or self.lanes.peek() != null) {
                return self.fail(.phase_mismatch, event.entry_index, null);
            }
            if (event.offset != active.bytes) {
                return self.fail(.offset_mismatch, event.entry_index, null);
            }
            if (event.bytes.len == 0) {
                return self.fail(.byte_count_mismatch, event.entry_index, null);
            }
            if (active.discard) return self.discardChunk(event);
            const result = self.window.push(
                &self.runtime,
                self.activeState(),
                event.bytes,
                event.offset,
            ) catch |problem| return self.windowFailure(problem);
            self.active.?.bytes = std.math.add(
                u64,
                self.active.?.bytes,
                result.consumed,
            ) catch return self.fail(.byte_count_mismatch, event.entry_index, null);
            if (result.submission) |submission| {
                try self.putOutbox(
                    .{ .write = submission.slot },
                    submission.request,
                );
            }
            const flow: parser.CallbackFlow = if (result.consumed == event.bytes.len and
                self.lanes.peek() == null and self.window.canAccept()) .ready else .paused;
            if (flow == .paused) self.blocked_wait = .file_chunk;
            return .{ .consumed = result.consumed, .flow = flow };
        }

        pub fn fileEndProgress(
            self: *Self,
            event: events.FileEnd,
        ) Error!parser.CallbackFlow {
            try self.guard();
            const active = try self.requireFileEvent(
                event.entry_index,
                event.occurrence,
                .body,
            );
            if (self.blocked_wait != null or self.lanes.peek() != null) {
                return self.fail(.phase_mismatch, event.entry_index, null);
            }
            if (event.bytes != active.bytes) {
                return self.fail(.byte_count_mismatch, event.entry_index, null);
            }
            if (active.discard) {
                try self.storeDiscardSummary();
                self.active = null;
                return .ready;
            }
            self.window.drain() catch {
                return self.fail(.window_invariant, event.entry_index, null);
            };
            self.active.?.phase = .end_draining;
            const flow = try self.driveFileEnd();
            if (flow == .paused) self.blocked_wait = .file_end;
            return flow;
        }

        pub fn multipartResume(
            self: *Self,
            wait: parser.Wait,
        ) Error!parser.CallbackFlow {
            try self.guard();
            if (self.phase != .collecting or self.blocked_wait != wait) {
                return self.fail(.resume_mismatch, self.activeEntry(), null);
            }
            const flow = switch (wait) {
                .file_start => try self.resumeFileStart(),
                .file_chunk => self.resumeFileChunk(),
                .file_end => try self.driveFileEnd(),
            };
            if (flow == .ready) self.blocked_wait = null;
            return flow;
        }

        pub fn peekSubmission(self: *Self) Error!?Submission {
            try self.guard();
            if (self.phase == .abort_draining) return null;
            const pending = self.lanes.peek() orelse return null;
            const index = try self.pendingRecordIndex(pending.lane);
            return .{
                .lane = pending.lane,
                .request = pending.request,
                .file = std.meta.activeTag(self.records[index]),
                .instance_index = @intCast(index),
            };
        }

        pub fn markSubmitted(self: *Self, lane: Lane) Error!void {
            try self.guard();
            if (self.phase == .abort_draining) {
                return self.fail(.phase_mismatch, self.activeEntry(), lane);
            }
            self.lanes.mark(lane) catch |problem| {
                return self.laneFailure(problem, lane);
            };
        }

        pub fn complete(
            self: *Self,
            lane: Lane,
            completion: upload.IoCompletion,
        ) Error!void {
            return self.completeWith(lane, completion, false);
        }

        pub fn completeCanceled(self: *Self, lane: Lane) Error!void {
            return self.completeWith(lane, .{ .failure = .canceled }, true);
        }

        fn completeWith(
            self: *Self,
            lane: Lane,
            completion: upload.IoCompletion,
            cancel_requested: bool,
        ) Error!void {
            try self.guard();
            self.lanes.takeCompletion(lane) catch |problem| {
                return self.laneFailure(problem, lane);
            };
            try self.completeKnown(lane, completion, cancel_requested);
        }

        /// Call only after the body, application decision, and response are valid.
        pub fn markCommitReady(self: *Self) Error!void {
            try self.guard();
            if (self.commit_ready or !self.readyForCommit()) {
                return self.fail(.phase_mismatch, self.activeEntry(), null);
            }
            self.commit_ready = true;
        }

        pub fn startCommit(self: *Self) Error!FinalizationFlow {
            try self.guard();
            if (!self.commit_ready or !self.readyForCommit()) {
                return self.fail(.phase_mismatch, self.activeEntry(), null);
            }
            self.commit_ready = false;
            self.phase = .finalizing;
            const step = self.finalizer.startCommit(
                &self.runtime,
                &self.lifecycle,
            ) catch return self.fail(.finalizer_invariant, null, null);
            return self.acceptFinalizer(step);
        }

        pub fn startAbort(
            self: *Self,
            cause: ?upload_finalizer.UpstreamFailure,
        ) Error!FinalizationFlow {
            try self.guard();
            if (self.phase != .collecting or self.commit_ready) {
                return self.fail(.phase_mismatch, self.activeEntry(), null);
            }
            self.phase = .abort_draining;
            self.abort_cause = cause;
            self.blocked_wait = null;
            self.window.cancel();
            return self.driveAbortDrain();
        }

        pub fn finalizationFlow(self: *Self) Error!FinalizationFlow {
            try self.guard();
            return switch (self.phase) {
                .abort_draining => self.driveAbortDrain(),
                .finalizing => .paused,
                .done => .complete,
                .collecting, .fatal => self.fail(
                    .phase_mismatch,
                    self.activeEntry(),
                    null,
                ),
            };
        }

        pub fn report(self: *Self) Error!?*const Finalizer.Report {
            try self.guard();
            return if (self.phase == .done) &self.finalizer.report else null;
        }

        pub fn reportRecordCount(self: *Self) Error!?u16 {
            try self.guard();
            return if (self.phase == .done) @intCast(self.record_count) else null;
        }

        pub fn reportRecord(self: *Self, index: usize) Error!?ReportRecord {
            try self.guard();
            if (self.phase != .done or index >= self.record_count) return null;
            if (comptime report_record_capacity == 0) return null;
            return .{
                .file = std.meta.activeTag(self.records[index]),
                .cleanup_failure = self.finalizer.report.cleanupFailureClass(index),
            };
        }

        pub fn summaries(self: *Self) Error!Spec.Summaries {
            try self.guard();
            if (self.anchor == null) self.anchor = self;
            return self.storage.summaryViews();
        }

        pub fn fatal(self: *Self) ?Fatal {
            if (self.anchor) |anchor| {
                if (anchor != self) self.latch(.moved_after_record, null, null, null);
            }
            return self.fatal_state;
        }

        pub fn failureKind(self: *const Self, _: Error) FailureKind {
            return if (self.fatal_state == null) .sink else .fatal;
        }

        fn requireStartReady(self: *Self, entry_index: u16) Error!void {
            if (self.phase != .collecting or self.active != null or
                self.blocked_wait != null or self.lanes.peek() != null or
                self.lanes.hasSubmitted() or self.commit_ready or
                !self.lifecycle.quiescent() or !self.window.quiescent())
            {
                return self.fail(.phase_mismatch, entry_index, null);
            }
        }

        fn record(self: *Self, tag: Spec.File, occurrence: u16) Error!usize {
            if (comptime self.records.len == 0) return self.fail(.layout_invariant, null, null);
            const index = self.record_count;
            if (index == self.records.len) {
                return self.fail(.layout_invariant, null, null);
            }
            self.records[index] = self.storage.beginState(tag, occurrence) catch {
                return self.fail(.layout_invariant, null, null);
            };
            if (self.anchor == null) self.anchor = self;
            _ = self.finalizer.recordBegun(&self.records[index]) catch {
                return self.fail(.finalizer_invariant, null, null);
            };
            self.record_count += 1;
            return index;
        }

        fn discardChunk(
            self: *Self,
            event: events.FileChunk,
        ) Error!parser.ChunkProgress {
            self.active.?.bytes = std.math.add(
                u64,
                self.active.?.bytes,
                event.bytes.len,
            ) catch return self.fail(.byte_count_mismatch, event.entry_index, null);
            return .{ .consumed = event.bytes.len, .flow = .ready };
        }

        fn storeDiscardSummary(self: *Self) Error!void {
            const active = self.active.?;
            switch (active.tag) {
                inline else => |selected| {
                    const name = @tagName(selected);
                    const Sink = @TypeOf(
                        @field(Spec.configured_schema, name),
                    ).SinkType;
                    if (comptime Sink != upload.DiscardSink) {
                        return self.fail(.variant_mismatch, active.entry_index, null);
                    }
                    const summary = @unionInit(Mux.Summary, name, {});
                    self.storage.storeSummary(
                        active.tag,
                        active.occurrence,
                        summary,
                    ) catch return self.fail(
                        .layout_invariant,
                        active.entry_index,
                        null,
                    );
                },
            }
        }

        fn resumeFileStart(self: *Self) Error!parser.CallbackFlow {
            const active = self.active orelse {
                return self.fail(.phase_mismatch, null, null);
            };
            return switch (active.phase) {
                .begin => .paused,
                .body => .ready,
                .end_draining, .finish, .failed => self.fail(
                    .phase_mismatch,
                    active.entry_index,
                    null,
                ),
            };
        }

        fn resumeFileChunk(self: *Self) parser.CallbackFlow {
            const active = self.active orelse return .paused;
            if (active.phase != .body or self.lanes.peek() != null) return .paused;
            return if (active.discard or self.window.canAccept()) .ready else .paused;
        }

        fn driveFileEnd(self: *Self) Error!parser.CallbackFlow {
            const active = self.active orelse return .ready;
            return switch (active.phase) {
                .end_draining => if (self.window.quiescent())
                    self.startFinish()
                else
                    .paused,
                .finish => .paused,
                .begin, .body, .failed => self.fail(
                    .phase_mismatch,
                    active.entry_index,
                    null,
                ),
            };
        }

        fn startFinish(self: *Self) Error!parser.CallbackFlow {
            self.active.?.phase = .finish;
            const poll = self.lifecycle.startFinish(
                &self.runtime,
                self.activeState(),
                .{ .bytes = self.active.?.bytes },
            ) catch |problem| return self.lifecycleFailure(problem);
            return switch (poll) {
                .request => |request| paused: {
                    try self.putOutbox(.lifecycle, request);
                    break :paused .paused;
                },
                .done => |summary| done: {
                    try self.finishDone(summary);
                    break :done .ready;
                },
            };
        }

        fn finishDone(self: *Self, summary: Mux.Summary) Error!void {
            const active = self.active.?;
            if (self.phase == .collecting) {
                self.storage.storeSummary(
                    active.tag,
                    active.occurrence,
                    summary,
                ) catch return self.fail(
                    .layout_invariant,
                    active.entry_index,
                    null,
                );
                self.window.reset() catch return self.fail(
                    .window_invariant,
                    active.entry_index,
                    null,
                );
            } else if (self.phase != .abort_draining) {
                return self.fail(.phase_mismatch, active.entry_index, null);
            }
            self.active = null;
        }

        fn putOutbox(
            self: *Self,
            lane: Lane,
            request: upload.IoRequest,
        ) Error!void {
            self.lanes.put(lane, request) catch |problem| {
                return self.laneFailure(problem, lane);
            };
        }

        fn pendingRecordIndex(self: *Self, lane: Lane) Error!usize {
            if (self.phase == .collecting) {
                const active = self.active orelse {
                    return self.fail(.phase_mismatch, null, lane);
                };
                return active.record_index orelse {
                    return self.fail(.phase_mismatch, active.entry_index, lane);
                };
            }
            if (self.phase == .finalizing and lane == .lifecycle) {
                return self.finalizer.pendingEntryIndex() orelse {
                    return self.fail(.finalizer_invariant, null, lane);
                };
            }
            return self.fail(.phase_mismatch, self.activeEntry(), lane);
        }

        fn completeKnown(
            self: *Self,
            lane: Lane,
            completion: upload.IoCompletion,
            cancel_requested: bool,
        ) Error!void {
            if (self.phase == .finalizing) {
                if (lane != .lifecycle) {
                    return self.fail(.lane_mismatch, null, lane);
                }
                return self.completeFinalizer(completion);
            }
            if (self.phase != .collecting and self.phase != .abort_draining) {
                return self.fail(.phase_mismatch, self.activeEntry(), lane);
            }
            switch (lane) {
                .lifecycle => try self.completeActiveLifecycle(
                    completion,
                    cancel_requested,
                ),
                .write => |slot| try self.completeWrite(
                    slot,
                    completion,
                    cancel_requested,
                ),
            }
        }

        fn completeActiveLifecycle(
            self: *Self,
            completion: upload.IoCompletion,
            cancel_requested: bool,
        ) Error!void {
            const active = self.active orelse {
                return self.fail(.phase_mismatch, null, .lifecycle);
            };
            const state = self.activeState();
            if (cancel_requested) {
                if (completion != .failure or completion.failure != .canceled or
                    !self.lifecycle.cancelActive())
                {
                    return self.fail(.lifecycle_invariant, active.entry_index, .lifecycle);
                }
                return;
            }
            switch (active.phase) {
                .begin => {
                    const poll = self.lifecycle.resumeBegin(
                        &self.runtime,
                        state,
                        completion,
                    ) catch |problem| return self.lifecycleFailure(problem);
                    switch (poll) {
                        .request => |request| try self.putOutbox(.lifecycle, request),
                        .done => self.active.?.phase = .body,
                    }
                },
                .finish => {
                    const poll = self.lifecycle.resumeFinish(
                        &self.runtime,
                        state,
                        completion,
                    ) catch |problem| return self.lifecycleFailure(problem);
                    switch (poll) {
                        .request => |request| try self.putOutbox(.lifecycle, request),
                        .done => |summary| try self.finishDone(summary),
                    }
                },
                .body, .end_draining, .failed => return self.fail(
                    .phase_mismatch,
                    active.entry_index,
                    .lifecycle,
                ),
            }
        }

        fn completeWrite(
            self: *Self,
            slot: Slot,
            completion: upload.IoCompletion,
            cancel_requested: bool,
        ) Error!void {
            const state = self.activeState();
            const canceled = completion == .failure and completion.failure == .canceled;
            const poll = (if (cancel_requested and canceled)
                self.window.completeCanceled(&self.runtime, state, slot)
            else
                self.window.complete(
                    &self.runtime,
                    state,
                    slot,
                    completion,
                )) catch |problem| return self.windowFailure(problem);
            if (poll == .request) {
                try self.putOutbox(.{ .write = slot }, poll.request);
            }
        }

        fn completeFinalizer(self: *Self, completion: upload.IoCompletion) Error!void {
            const step = self.finalizer.complete(
                &self.runtime,
                &self.lifecycle,
                completion,
            ) catch return self.fail(.finalizer_invariant, null, .lifecycle);
            _ = try self.acceptFinalizer(step);
        }

        fn driveAbortDrain(self: *Self) Error!FinalizationFlow {
            if (self.lanes.peek() != null) {
                self.cancelUnsubmitted() catch {
                    if (self.fatal_state != null) return error.TransactionFatal;
                };
                if (self.lanes.hasUnsubmitted()) return .progress;
            }
            if (self.lanes.hasSubmitted()) return .paused;
            if (!self.window.quiescent() or !self.lifecycle.quiescent()) {
                return self.fail(.phase_mismatch, self.activeEntry(), null);
            }
            self.active = null;
            self.phase = .finalizing;
            const step = self.finalizer.startAbort(
                &self.runtime,
                &self.lifecycle,
                self.abort_cause,
            ) catch return self.fail(.finalizer_invariant, null, null);
            return self.acceptFinalizer(step);
        }

        fn cancelUnsubmitted(self: *Self) Error!void {
            const pending = self.lanes.takeUnsubmitted() orelse return;
            try self.completeKnown(pending.lane, .{ .failure = .canceled }, true);
        }

        fn acceptFinalizer(self: *Self, step: Finalizer.Step) Error!FinalizationFlow {
            return switch (step) {
                .request => |request| paused: {
                    try self.putOutbox(.lifecycle, request);
                    break :paused .paused;
                },
                .done => done: {
                    self.phase = .done;
                    break :done .complete;
                },
                .fatal => |value| {
                    self.latch(.finalizer_fatal, null, null, value);
                    return error.TransactionFatal;
                },
            };
        }

        fn lifecycleFailure(self: *Self, problem: Lifecycle.Error) Error {
            if (self.lifecycle.lastFailureSource() != .sink) {
                return self.fail(.lifecycle_invariant, self.activeEntry(), null);
            }
            self.noteActiveFailure() catch return error.TransactionFatal;
            const sink_problem: Mux.Error = @errorCast(problem);
            return sink_problem;
        }

        fn windowFailure(self: *Self, problem: Window.Error) Error {
            if (!transaction_types.recoverableWindowFailure(self.window.mode)) {
                return self.fail(.window_invariant, self.activeEntry(), null);
            }
            self.noteActiveFailure() catch return error.TransactionFatal;
            const sink_problem: Mux.Error = @errorCast(problem);
            return sink_problem;
        }

        fn noteActiveFailure(self: *Self) Error!void {
            const active = self.active orelse {
                return self.fail(.phase_mismatch, null, null);
            };
            const index = active.record_index orelse {
                return self.fail(.phase_mismatch, active.entry_index, null);
            };
            self.finalizer.noteSinkFailure(index) catch {
                return self.fail(.finalizer_invariant, active.entry_index, null);
            };
            self.active.?.phase = .failed;
        }

        fn requireFileEvent(
            self: *Self,
            entry_index: u16,
            occurrence: u16,
            expected: State.ActivePhase,
        ) Error!*Active {
            if (self.phase != .collecting) {
                return self.fail(.phase_mismatch, entry_index, null);
            }
            const active = self.active orelse {
                return self.fail(.event_mismatch, entry_index, null);
            };
            if (active.entry_index != entry_index or
                active.occurrence != occurrence or active.phase != expected)
            {
                return self.fail(.event_mismatch, entry_index, null);
            }
            return &self.active.?;
        }

        fn activeState(self: *Self) *Mux.State {
            if (comptime self.records.len == 0) unreachable;
            return &self.records[self.active.?.record_index.?];
        }

        const readyForCommit = failure.readyForCommit;
        const laneFailure = failure.laneFailure;
        const guard = failure.guard;
        const fail = failure.fail;
        const latch = failure.latch;
        const activeEntry = failure.activeEntry;
    };
}
