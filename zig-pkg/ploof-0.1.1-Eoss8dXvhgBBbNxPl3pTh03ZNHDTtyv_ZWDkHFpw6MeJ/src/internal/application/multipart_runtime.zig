const std = @import("std");
const application_multipart_plan = @import("multipart_plan.zig");
const csrf_request = @import("../csrf/request.zig");
const multipart_parser = @import("../multipart/parser.zig");
const multipart_events = @import("../multipart/events.zig");
const text_scalar = @import("../text/scalar.zig");
const upload_runtime = @import("multipart_upload_runtime.zig");

pub const TerminalSource = upload_runtime.TerminalSource;

pub const Error = error{
    FileRejected,
    InvalidField,
    InvalidMultipart,
    LimitExceeded,
    UnsupportedMedia,
};

pub fn Runtime(comptime Handler: type) type {
    const Spec = Handler.definition.MultipartBodySpec;
    const selected = application_multipart_plan.compiledPlan(Spec);
    const Adapter = ConsumerAdapter(Handler, Spec);
    const Parser = multipart_parser.Parser(selected, Adapter);

    comptime validateDiscardSinks(Spec);

    return struct {
        const Self = @This();

        parser: Parser,
        adapter: Adapter,

        pub fn init(boundary: []const u8, context: anytype) Error!Self {
            var self = Self{
                .parser = Parser.init(boundary) catch |problem| return mapParserError(problem),
                .adapter = .{
                    .state = undefined,
                    .context = @ptrCast(context),
                    .initialize = stateInitializer(Handler, context),
                    .csrf_request = csrfState(context),
                },
            };
            self.adapter.initializeIfAdmitted();
            return self;
        }

        pub fn state(self: *Self) *Handler.MultipartState {
            std.debug.assert(self.adapter.state_initialized);
            std.debug.assert(self.adapter.terminal == .none);
            return &self.adapter.state;
        }

        pub fn stateInitialized(self: *const Self) bool {
            return self.adapter.state_initialized;
        }

        pub fn feed(self: *Self, input: []const u8) Error!void {
            self.parser.feed(&self.adapter, input) catch |problem| {
                self.adapter.latchFailure(problem);
                return mapFeedError(problem);
            };
        }

        pub fn finish(self: *Self) Error!void {
            self.parser.finish(&self.adapter) catch |problem| {
                self.adapter.latchFailure(problem);
                return mapFeedError(problem);
            };
            self.adapter.completeRequestBody() catch |problem| {
                self.adapter.latchFailure(problem);
                return problem;
            };
        }

        pub fn terminalSource(self: *const Self) TerminalSource {
            return self.adapter.terminal;
        }
    };
}

pub fn decoderIndex(comptime Handler: type) u8 {
    const Definition = Handler.definition;
    const BodySpec = @TypeOf(Definition.body_spec);
    if (comptime @import("../../input_body.zig").isDecoder(BodySpec)) return 0;
    const configured = BodySpec.configured_decoders;
    inline for (@typeInfo(@TypeOf(configured)).@"struct".fields, 0..) |field, index| {
        const Spec = @TypeOf(@field(configured, field.name));
        if (Spec.decoder_kind == .multipart) return @intCast(index);
    }
    unreachable;
}

fn ConsumerAdapter(comptime Handler: type, comptime Spec: type) type {
    const MultipartSpec = Spec;
    return struct {
        pub const CallbackError = error{ InvalidField, FileRejected };
        pub const Error = CallbackError;

        state: Handler.MultipartState,
        state_initialized: bool = false,
        context: *anyopaque,
        initialize: *const fn (*anyopaque) Handler.MultipartState,
        csrf_request: ?*csrf_request.State,
        terminal: TerminalSource = .none,

        pub fn field(self: *@This(), event: multipart_events.Field) CallbackError!void {
            inline for (
                @typeInfo(@TypeOf(MultipartSpec.configured_schema)).@"struct".fields,
                0..,
            ) |schema_field, index| {
                if (event.entry_index == index) {
                    const Part = @TypeOf(@field(
                        MultipartSpec.configured_schema,
                        schema_field.name,
                    ));
                    if (comptime @import("../../multipart.zig").isCsrfField(Part)) {
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
                    const typed = @unionInit(MultipartSpec.Field, schema_field.name, value);
                    Handler.handler_fn.field(state, typed);
                    return;
                }
            }
            return error.InvalidField;
        }

        fn observeCsrf(self: *@This(), token: []const u8) CallbackError!void {
            const state = self.csrf_request orelse return self.rejectCsrf();
            if (state.observe(.multipart, token)) return;
            return self.rejectCsrf();
        }

        fn beforeApplicationData(self: *@This()) CallbackError!void {
            const state = self.csrf_request orelse return;
            if (state.beforeFile()) return;
            return self.rejectCsrf();
        }

        fn completeRequestBody(self: *@This()) CallbackError!void {
            if (self.csrf_request) |state| {
                if (!state.completeBody()) return self.rejectCsrf();
            }
            _ = self.applicationState();
        }

        fn initializeIfAdmitted(self: *@This()) void {
            const state = self.csrf_request orelse {
                _ = self.applicationState();
                return;
            };
            if (state.status == .safe or state.status == .accepted) {
                _ = self.applicationState();
            }
        }

        fn applicationState(self: *@This()) *Handler.MultipartState {
            if (!self.state_initialized) {
                self.state = self.initialize(self.context);
                self.state_initialized = true;
            }
            return &self.state;
        }

        fn rejectCsrf(self: *@This()) CallbackError {
            self.terminal = .rejection;
            return error.FileRejected;
        }

        fn latchFailure(self: *@This(), problem: anytype) void {
            if (self.terminal != .none) return;
            self.terminal = if (problem == error.FileRejected) .rejection else .parser;
        }

        pub fn fileStart(self: *@This(), event: multipart_events.FileStart) CallbackError!void {
            if (!fileEntry(MultipartSpec, event.entry_index)) return error.InvalidField;
            try self.beforeApplicationData();
        }

        pub fn fileChunk(_: *@This(), event: multipart_events.FileChunk) CallbackError!void {
            if (!fileEntry(MultipartSpec, event.entry_index)) return error.InvalidField;
        }

        pub fn fileEnd(_: *@This(), event: multipart_events.FileEnd) CallbackError!void {
            if (!fileEntry(MultipartSpec, event.entry_index)) return error.InvalidField;
        }
    };
}

fn initialState(comptime Handler: type, context: anytype) Handler.MultipartState {
    if (comptime Handler.MultipartState == void) return {};
    return Handler.handler_fn.init(context);
}

fn stateInitializer(
    comptime Handler: type,
    context: anytype,
) *const fn (*anyopaque) Handler.MultipartState {
    const Context = @typeInfo(@TypeOf(context)).pointer.child;
    return struct {
        fn initialize(raw: *anyopaque) Handler.MultipartState {
            const typed: *Context = @ptrCast(@alignCast(raw));
            return initialState(Handler, typed);
        }
    }.initialize;
}

fn csrfState(context: anytype) ?*csrf_request.State {
    const Context = @typeInfo(@TypeOf(context)).pointer.child;
    if (comptime @hasField(Context, "csrf_request")) return context.csrf_request;
    return null;
}

fn fileEntry(comptime Spec: type, entry_index: u16) bool {
    inline for (
        @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields,
        0..,
    ) |schema_field, index| {
        if (entry_index == index) {
            const Part = @TypeOf(@field(Spec.configured_schema, schema_field.name));
            return comptime Part.kind == .file;
        }
    }
    return false;
}

fn validateDiscardSinks(comptime Spec: type) void {
    inline for (@typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (comptime Part.kind != .file) continue;
        const Sink = Part.SinkType;
        if (!@hasDecl(Sink, "ploof_multipart_discard_sink") or
            !Sink.ploof_multipart_discard_sink)
        {
            @compileError("PLOOF-E3522 custom multipart sinks require the M9 sink contract");
        }
    }
}

fn mapFeedError(problem: anytype) Error {
    return switch (problem) {
        error.Malformed => error.InvalidMultipart,
        error.LimitExceeded => error.LimitExceeded,
        error.UnsupportedMedia => error.UnsupportedMedia,
        error.InvalidField => error.InvalidField,
        error.FileRejected => error.FileRejected,
    };
}

fn mapParserError(problem: multipart_parser.Error) Error {
    return switch (problem) {
        error.Malformed => error.InvalidMultipart,
        error.LimitExceeded => error.LimitExceeded,
        error.UnsupportedMedia => error.UnsupportedMedia,
    };
}

test {
    std.testing.refAllDecls(@This());
}
