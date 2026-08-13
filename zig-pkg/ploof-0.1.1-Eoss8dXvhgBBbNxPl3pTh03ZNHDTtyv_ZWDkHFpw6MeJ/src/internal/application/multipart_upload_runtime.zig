const std = @import("std");

const endpoint = @import("../../endpoint.zig");
const multipart = @import("../../multipart.zig");
const application_csrf = @import("csrf.zig");
const csrf_request = @import("../csrf/request.zig");
const events = @import("../multipart/events.zig");
const multipart_parser = @import("../multipart/parser.zig");
const multipart_plan = @import("multipart_plan.zig");
const registry_view = @import("../multipart/upload_registry_view.zig");
const text_scalar = @import("../text/scalar.zig");
const transaction_module = @import("../multipart/upload_transaction.zig");
const upload_finalizer = @import("../upload/finalizer.zig");

pub const TerminalSource = enum(u8) {
    none,
    parser,
    application,
    rejection,
    sink,
    fatal,
};

pub const ControlError = error{
    FileRejected,
    InvalidField,
    RuntimeMoved,
    Terminal,
};

/// Must be initialized in its final request-workspace address and never moved.
pub fn Runtime(comptime Handler: type) type {
    const Contract = endpoint.MultipartFileStartContract(
        Handler.definition,
        Handler.MultipartConsumer,
    );
    const Context = Contract.ContextType;
    const Response = Contract.ResponseType;
    const Spec = Handler.definition.MultipartBodySpec;
    const Registry = registry_view.RegistryView(Spec);
    const Transaction = transaction_module.Transaction(Spec, Registry);
    const Adapter = ConsumerAdapter(
        Handler,
        Context,
        Response,
        Contract.ReturnType,
        Transaction,
    );
    const Parser = multipart_parser.Parser(
        multipart_plan.compiledPlan(Spec),
        Adapter,
    );

    return struct {
        const Self = @This();

        pub const Error = Parser.ProgressFeedError || ControlError;
        pub const ApplicationError = Adapter.ApplicationError;
        pub const MultipartSpec = Spec;
        pub const Progress = multipart_parser.Progress;
        pub const Submission = Transaction.Submission;
        pub const Lane = Transaction.Lane;
        pub const FinalizationFlow = Transaction.FinalizationFlow;
        pub const Report = Transaction.Report;
        pub const ReportRecord = Transaction.ReportRecord;
        pub const report_record_capacity = Transaction.report_record_capacity;

        parser: Parser,
        registry: Registry,
        transaction: Transaction,
        adapter: Adapter,
        anchor: *Self,

        pub fn initInPlace(
            self: *Self,
            boundary: []const u8,
            context: *Context,
            source_registry: anytype,
        ) (multipart_parser.Error || registry_view.Error)!void {
            self.parser = Parser.init(boundary) catch |problem| return problem;
            self.registry = try Registry.init(source_registry);
            self.transaction = Transaction.init(&self.registry);
            self.adapter = .{
                .context = context,
                .state = undefined,
                .transaction = &self.transaction,
                .csrf_request = csrfState(context),
            };
            self.adapter.initializeIfAdmitted();
            self.anchor = self;
        }

        pub fn state(self: *Self) Error!*Handler.MultipartState {
            try self.requireParserReady();
            if (!self.adapter.state_initialized) return error.Terminal;
            return &self.adapter.state;
        }

        pub fn stateInitialized(self: *const Self) bool {
            return self.adapter.state_initialized;
        }

        pub fn feedProgress(self: *Self, input: []const u8) Error!Progress {
            try self.requireParserOpen();
            const progress = self.parser.feedProgress(&self.adapter, input) catch |problem| {
                self.latchParserFailure(problem);
                return problem;
            };
            try self.completeIfFinished(progress);
            return progress;
        }

        pub fn finishProgress(self: *Self) Error!Progress {
            try self.requireParserOpen();
            const progress = self.parser.finishProgress(&self.adapter) catch |problem| {
                self.latchParserFailure(problem);
                return problem;
            };
            try self.completeIfFinished(progress);
            return progress;
        }

        pub fn resumeParser(self: *Self) Error!Progress {
            try self.requireParserReady();
            const progress = self.parser.@"resume"(&self.adapter) catch |problem| {
                self.latchParserFailure(problem);
                return problem;
            };
            try self.completeIfFinished(progress);
            return progress;
        }

        pub fn peekSubmission(self: *Self) Error!?Submission {
            try self.guard();
            return self.transaction.peekSubmission() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn markSubmitted(self: *Self, lane: Lane) Error!void {
            try self.guard();
            self.transaction.markSubmitted(lane) catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn completeSubmission(
            self: *Self,
            lane: Lane,
            completion: multipart.IoCompletion,
        ) Error!void {
            try self.guard();
            self.transaction.complete(lane, completion) catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn completeCanceledSubmission(self: *Self, lane: Lane) Error!void {
            try self.guard();
            self.transaction.completeCanceled(lane) catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn summaries(self: *Self) Error!Spec.Summaries {
            try self.guard();
            return self.transaction.summaries() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn markCommitReady(self: *Self) Error!void {
            try self.requireParserReady();
            if (!self.parser.isComplete()) return error.Terminal;
            self.transaction.markCommitReady() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn startCommit(self: *Self) Error!FinalizationFlow {
            try self.guard();
            return self.transaction.startCommit() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn startAbort(
            self: *Self,
            cause: ?upload_finalizer.UpstreamFailure,
        ) Error!FinalizationFlow {
            try self.guard();
            return self.transaction.startAbort(cause) catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn finalizationFlow(self: *Self) Error!FinalizationFlow {
            try self.guard();
            return self.transaction.finalizationFlow() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn report(self: *Self) Error!?*const Report {
            try self.guard();
            return self.transaction.report() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn reportRecordCount(self: *Self) Error!?u16 {
            try self.guard();
            return self.transaction.reportRecordCount() catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn reportRecord(self: *Self, index: usize) Error!?ReportRecord {
            try self.guard();
            return self.transaction.reportRecord(index) catch |problem| {
                return self.transactionFailure(problem);
            };
        }

        pub fn terminalSource(self: *const Self) TerminalSource {
            return self.adapter.terminal;
        }

        pub fn rejection(self: *Self) ?*const Response {
            if (self.adapter.rejected) |*response| return response;
            return null;
        }

        pub fn applicationFailure(self: *const Self) ?ApplicationError {
            return self.adapter.application_error;
        }

        fn requireParserReady(self: *Self) Error!void {
            try self.guard();
            if (self.adapter.terminal != .none) return error.Terminal;
        }

        fn completeIfFinished(self: *Self, progress: Progress) Error!void {
            if (progress.flow != .complete) return;
            try self.adapter.completeRequestBody();
        }

        fn requireParserOpen(self: *Self) Error!void {
            try self.requireParserReady();
            if (self.parser.isComplete()) return error.Terminal;
        }

        fn guard(self: *Self) Error!void {
            if (self.anchor == self) return;
            self.adapter.terminal = .fatal;
            return error.RuntimeMoved;
        }

        fn latchParserFailure(self: *Self, problem: Parser.ProgressFeedError) void {
            if (self.adapter.terminal != .none) return;
            self.adapter.terminal = if (problem == error.ConsumerInvariant)
                .fatal
            else
                .parser;
        }

        fn transactionFailure(self: *Self, problem: Transaction.Error) Error {
            self.adapter.latchTransactionFailure(problem);
            return problem;
        }
    };
}

fn ConsumerAdapter(
    comptime Handler: type,
    comptime Context: type,
    comptime Response: type,
    comptime FileStartReturn: type,
    comptime Transaction: type,
) type {
    const Spec = Handler.definition.MultipartBodySpec;
    const Admission = Spec.FileAdmission(Response);
    const FileStartError = returnErrorSet(FileStartReturn);

    return struct {
        const Self = @This();

        pub const Error = FileStartError || Transaction.Error || ControlError;
        pub const ApplicationError = FileStartError;

        context: *Context,
        state: Handler.MultipartState,
        state_initialized: bool = false,
        transaction: *Transaction,
        csrf_request: ?*csrf_request.State,
        rejected: ?Response = null,
        application_error: ?FileStartError = null,
        terminal: TerminalSource = .none,

        pub fn field(self: *Self, event: events.Field) Error!void {
            inline for (
                @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields,
                0..,
            ) |schema_field, index| {
                if (event.entry_index == index) {
                    const Part = @TypeOf(@field(
                        Spec.configured_schema,
                        schema_field.name,
                    ));
                    if (comptime multipart.isCsrfField(Part)) {
                        return self.observeCsrf(event.bytes);
                    }
                    if (comptime Part.kind == .file) return error.InvalidField;
                    try self.beforeApplicationData();
                    const state = self.applicationState();
                    const value = if (comptime Part.kind == .field)
                        text_scalar.parse(Part.Target, event.bytes) catch
                            return error.InvalidField
                    else
                        event.bytes;
                    Handler.handler_fn.field(
                        state,
                        @unionInit(Spec.Field, schema_field.name, value),
                    );
                    return;
                }
            }
            return error.InvalidField;
        }

        fn observeCsrf(self: *Self, token: []const u8) Error!void {
            const state = self.csrf_request orelse return self.rejectCsrf();
            if (state.observe(.multipart, token)) return;
            return self.rejectCsrf();
        }

        pub fn fileStartProgress(
            self: *Self,
            event: events.FileStart,
        ) Error!multipart_parser.CallbackFlow {
            try self.beforeApplicationData();
            const public_event = try publicFileStart(Spec, event);
            const admission = self.callFileStart(public_event) catch |problem| {
                self.application_error = problem;
                self.terminal = .application;
                return problem;
            };
            return switch (admission) {
                .accept => |input| self.transaction.fileStartProgress(
                    event,
                    input,
                ) catch |problem| {
                    self.latchTransactionFailure(problem);
                    return problem;
                },
                .reject => |response| {
                    self.rejected = response;
                    self.terminal = .rejection;
                    return error.FileRejected;
                },
            };
        }

        pub fn fileChunkProgress(
            self: *Self,
            event: events.FileChunk,
        ) Error!multipart_parser.ChunkProgress {
            return self.transaction.fileChunkProgress(event) catch |problem| {
                self.latchTransactionFailure(problem);
                return problem;
            };
        }

        pub fn fileEndProgress(
            self: *Self,
            event: events.FileEnd,
        ) Error!multipart_parser.CallbackFlow {
            return self.transaction.fileEndProgress(event) catch |problem| {
                self.latchTransactionFailure(problem);
                return problem;
            };
        }

        pub fn multipartResume(
            self: *Self,
            wait: multipart_parser.Wait,
        ) Error!multipart_parser.CallbackFlow {
            return self.transaction.multipartResume(wait) catch |problem| {
                self.latchTransactionFailure(problem);
                return problem;
            };
        }

        fn callFileStart(
            self: *Self,
            event: Spec.FileStart,
        ) FileStartError!Admission {
            const state = self.applicationState();
            if (comptime @typeInfo(FileStartReturn) == .error_union) {
                return try Handler.handler_fn.fileStart(self.context, state, event);
            }
            return Handler.handler_fn.fileStart(self.context, state, event);
        }

        fn beforeApplicationData(self: *Self) Error!void {
            const state = self.csrf_request orelse return;
            if (state.beforeFile()) return;
            return self.rejectCsrf();
        }

        fn completeRequestBody(self: *Self) Error!void {
            if (self.csrf_request) |state| {
                if (!state.completeBody()) return self.rejectCsrf();
            }
            _ = self.applicationState();
        }

        fn initializeIfAdmitted(self: *Self) void {
            const state = self.csrf_request orelse {
                _ = self.applicationState();
                return;
            };
            if (state.status == .safe or state.status == .accepted) {
                _ = self.applicationState();
            }
        }

        fn applicationState(self: *Self) *Handler.MultipartState {
            if (!self.state_initialized) {
                self.state = initialState(Handler, self.context);
                self.state_initialized = true;
            }
            return &self.state;
        }

        fn rejectCsrf(self: *Self) Error {
            if (comptime @hasField(Context, "csrf_request")) {
                self.rejected = application_csrf.forbidden(self.context);
            }
            self.terminal = .rejection;
            return error.FileRejected;
        }

        fn latchTransactionFailure(self: *Self, problem: Transaction.Error) void {
            self.terminal = switch (self.transaction.failureKind(problem)) {
                .sink => .sink,
                .fatal => .fatal,
            };
        }
    };
}

fn publicFileStart(comptime Spec: type, event: events.FileStart) ControlError!Spec.FileStart {
    inline for (
        @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields,
        0..,
    ) |field, index| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (comptime Part.kind != .file) continue;
        if (event.entry_index == index) {
            const metadata = event.metadata;
            return @unionInit(Spec.FileStart, field.name, multipart.FileStart{
                .part_name = metadata.name,
                .occurrence = event.occurrence,
                .client_filename = if (metadata.filename) |filename| .{
                    .bytes = filename.bytes,
                    .source = switch (filename.source) {
                        .filename => .filename,
                        .filename_star => .filename_star,
                    },
                } else null,
                .claimed_media_type = if (metadata.content_type) |media| .{
                    .raw = media.raw,
                    .type = media.type,
                    .subtype = media.subtype,
                } else null,
            });
        }
    }
    return error.InvalidField;
}

fn returnErrorSet(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |value| value.error_set,
        else => error{},
    };
}

fn initialState(comptime Handler: type, context: anytype) Handler.MultipartState {
    if (comptime Handler.MultipartState == void) return {};
    return Handler.handler_fn.init(context);
}

fn csrfState(context: anytype) ?*csrf_request.State {
    const Context = @typeInfo(@TypeOf(context)).pointer.child;
    if (comptime @hasField(Context, "csrf_request")) return context.csrf_request;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
