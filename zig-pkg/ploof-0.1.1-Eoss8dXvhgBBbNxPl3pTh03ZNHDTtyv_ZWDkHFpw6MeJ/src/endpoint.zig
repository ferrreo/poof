const std = @import("std");

const body = @import("body.zig");
const input_body = @import("input_body.zig");
const json = @import("json.zig");
const query = @import("query.zig");

pub fn Endpoint(comptime config: anytype) type {
    comptime validateConfig(config);
    const has_query = @hasField(@TypeOf(config), "query");
    const has_body = @hasField(@TypeOf(config), "body");
    const QuerySpec = if (has_query) @TypeOf(config.query) else void;
    const BodySpec = if (has_body) @TypeOf(config.body) else void;
    const MultipartSpec = multipartSpec(BodySpec);
    const Input = inputType(has_query, QuerySpec, has_body, BodySpec);
    const response_bytes_max = if (@hasField(
        @TypeOf(config),
        "response_json_bytes_max",
    ))
        validateResponseJsonBytesMax(config.response_json_bytes_max)
    else
        json.standard_encoded_bytes_max;

    return struct {
        const Self = @This();

        pub const InputType = Input;
        pub const query_enabled = has_query;
        pub const body_enabled = has_body;
        pub const query_spec = if (has_query) config.query else {};
        pub const body_spec = if (has_body) config.body else {};
        pub const multipart_enabled = MultipartSpec != void;
        pub const MultipartBodySpec = MultipartSpec;
        pub const response_json_bytes_max = response_bytes_max;

        pub fn handle(comptime handler: anytype) Handler(Self, handler) {
            return .{};
        }
    };
}

fn Handler(comptime Definition: type, comptime handler: anytype) type {
    comptime validateMultipartConsumer(Definition, handler);
    return struct {
        pub const ploof_input_endpoint = true;
        pub const ploof_multipart_endpoint = Definition.multipart_enabled;
        pub const definition = Definition;
        pub const handler_fn = handler;
        pub const Input = Definition.InputType;
        pub const MultipartConsumer = if (Definition.multipart_enabled)
            @TypeOf(handler)
        else
            void;
        pub const MultipartState = if (Definition.multipart_enabled)
            MultipartConsumer.State
        else
            void;

        pub fn invoke(
            _: @This(),
            context: anytype,
            input: Input,
        ) if (Definition.multipart_enabled) noreturn else @TypeOf(handler(context, input)) {
            if (comptime Definition.multipart_enabled) unreachable;
            return handler(context, input);
        }

        pub fn invokeMultipart(
            _: @This(),
            context: anytype,
            state: *MultipartState,
            input: Input,
            summaries: if (Definition.multipart_enabled)
                Definition.MultipartBodySpec.Summaries
            else
                void,
        ) if (Definition.multipart_enabled)
            @TypeOf(handler.complete(context, state, input, summaries))
        else
            noreturn {
            if (comptime !Definition.multipart_enabled) unreachable;
            return handler.complete(context, state, input, summaries);
        }
    };
}

fn multipartSpec(comptime BodySpec: type) type {
    if (BodySpec == void) return void;
    if (input_body.isDecoder(BodySpec)) {
        return if (BodySpec.decoder_kind == .multipart) BodySpec else void;
    }
    if (!input_body.isAlternatives(BodySpec)) return void;
    const configured = BodySpec.configured_decoders;
    inline for (@typeInfo(@TypeOf(configured)).@"struct".fields) |field| {
        const Spec = @TypeOf(@field(configured, field.name));
        if (Spec.decoder_kind == .multipart) return Spec;
    }
    return void;
}

fn validateMultipartConsumer(comptime Definition: type, comptime consumer: anytype) void {
    if (!Definition.multipart_enabled) return;
    const Consumer = @TypeOf(consumer);
    if (@typeInfo(Consumer) != .@"struct") {
        @compileError("PLOOF-E3450 multipart endpoint handler must be a consumer struct");
    }
    if (!@hasDecl(Consumer, "State") or @TypeOf(Consumer.State) != type) {
        @compileError("PLOOF-E3451 multipart consumer must declare State");
    }
    if (Consumer.State != void and !@hasDecl(Consumer, "init")) {
        @compileError("PLOOF-E3452 non-void multipart consumer State requires init");
    }
    if (Definition.MultipartBodySpec.Field != void and !@hasDecl(Consumer, "field")) {
        @compileError("PLOOF-E3453 multipart consumer must handle declared fields");
    }
    if (!@hasDecl(Consumer, "complete")) {
        @compileError("PLOOF-E3454 multipart consumer must declare complete");
    }
    if (Definition.MultipartBodySpec.FileStart != void and
        !@hasDecl(Consumer, "fileStart"))
    {
        @compileError("PLOOF-E3458 multipart consumer must declare fileStart");
    }
    if (Definition.MultipartBodySpec.FileStart != void) {
        _ = MultipartFileStartContract(Definition, Consumer);
    }
}

pub fn MultipartFileStartContract(
    comptime Definition: type,
    comptime Consumer: type,
) type {
    const message = "PLOOF-E3459 invalid multipart consumer fileStart signature";
    if (!@hasDecl(Consumer, "fileStart")) @compileError(message);
    const function = switch (@typeInfo(@TypeOf(Consumer.fileStart))) {
        .@"fn" => |value| value,
        else => @compileError(message),
    };
    if (function.params.len != 4) @compileError(message);
    const Spec = Definition.MultipartBodySpec;
    if (function.params[0].type == null or function.params[0].type.? != Consumer or
        function.params[2].type == null or function.params[2].type.? != *Consumer.State or
        function.params[3].type == null or function.params[3].type.? != Spec.FileStart)
    {
        @compileError(message);
    }
    const ContextPointer = function.params[1].type orelse @compileError(message);
    const Context = switch (@typeInfo(ContextPointer)) {
        .pointer => |pointer| pointer.child,
        else => @compileError(message),
    };
    if (ContextPointer != *Context) @compileError(message);
    switch (@typeInfo(Context)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => @compileError(message),
    }
    if (!@hasDecl(Context, "ResponseType")) @compileError(message);
    if (@TypeOf(Context.ResponseType) != type) @compileError(message);
    const Return = function.return_type orelse @compileError(message);
    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
    if (Payload != Spec.FileAdmission(Context.ResponseType)) @compileError(message);
    return struct {
        pub const ContextType = Context;
        pub const ResponseType = Context.ResponseType;
        pub const ReturnType = Return;
    };
}

fn inputType(
    comptime has_query: bool,
    comptime QuerySpec: type,
    comptime has_body: bool,
    comptime BodySpec: type,
) type {
    if (has_query and has_body) return struct {
        query: QuerySpec.Target,
        body: input_body.Input(BodySpec),
    };
    if (has_query) return struct { query: QuerySpec.Target };
    if (has_body) return struct { body: input_body.Input(BodySpec) };
    return body.None;
}

fn validateConfig(comptime config: anytype) void {
    const info = switch (@typeInfo(@TypeOf(config))) {
        .@"struct" => |value| value,
        else => @compileError("PLOOF-E3244 Endpoint config must be a struct literal"),
    };
    if (info.is_tuple) @compileError("PLOOF-E3529 Endpoint config must use named fields");
    inline for (info.fields) |field| {
        if (comptime !allowedField(field.name)) {
            @compileError("PLOOF-E3245 unknown Endpoint config field");
        }
    }
    if (@hasField(@TypeOf(config), "query") and !query.isSpec(@TypeOf(config.query))) {
        @compileError("PLOOF-E3246 Endpoint query must be a Query declaration");
    }
    if (@hasField(@TypeOf(config), "body")) {
        const T = @TypeOf(config.body);
        if (!input_body.isDecoder(T) and !input_body.isAlternatives(T)) {
            @compileError("PLOOF-E3247 Endpoint body must be a body decoder declaration");
        }
    }
}

fn allowedField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "query") or
        std.mem.eql(u8, name, "body") or
        std.mem.eql(u8, name, "response_json_bytes_max");
}

fn validateResponseJsonBytesMax(comptime value: anytype) usize {
    switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => {},
        else => @compileError(
            "PLOOF-E3530 Endpoint response_json_bytes_max must be a positive integer",
        ),
    }
    if (value <= 0 or value > std.math.maxInt(usize)) {
        @compileError(
            "PLOOF-E3248 Endpoint response_json_bytes_max must fit a positive usize",
        );
    }
    return @intCast(value);
}

test "endpoint exposes exact query and tagged body input" {
    const Form = @import("form.zig");
    const Query = @import("query.zig");
    const Page = struct { page: u16 = 1 };
    const Payload = struct { name: []const u8 };
    const Definition = Endpoint(.{
        .query = Query.typed(Page, .{}),
        .body = body.oneOf(.{ .form = Form.typed(Payload, .{}) }),
        .response_json_bytes_max = json.standard_encoded_bytes_max,
    });
    const handler = Definition.handle(struct {
        fn call(_: *u8, input: Definition.InputType) u16 {
            return input.query.page + @as(u16, @intCast(input.body.form.name.len));
        }
    }.call);
    const input = Definition.InputType{
        .query = .{ .page = 4 },
        .body = .{ .form = .{ .name = "zig" } },
    };
    var state: u8 = 0;
    try std.testing.expectEqual(@as(u16, 7), handler.invoke(&state, input));
}

test "multipart invocation forwards typed summaries and decision" {
    const multipart = @import("multipart.zig");
    const spec = multipart.decode(.{
        .upload = multipart.file(multipart.DiscardSink, multipart.required),
    }, .{});
    const Spec = @TypeOf(spec);
    const Definition = Endpoint(.{ .body = spec });
    const Context = struct {
        pub const ResponseType = u16;

        value: u8 = 0,
    };
    const Consumer = struct {
        pub const State = u8;

        pub fn init(_: @This(), _: *Context) State {
            return 0;
        }

        pub fn fileStart(
            _: @This(),
            _: *Context,
            _: *State,
            _: Spec.FileStart,
        ) Spec.FileAdmission(Context.ResponseType) {
            return .{ .accept = .{ .upload = {} } };
        }

        pub fn complete(
            _: @This(),
            context: *Context,
            state: *State,
            _: Definition.InputType,
            summaries: Spec.Summaries,
        ) multipart.Decision(Context.ResponseType) {
            context.value += 1;
            state.* = @intCast(summaries.upload.slice().len);
            return multipart.commit(@as(u16, 204));
        }
    };
    const handler = Definition.handle(Consumer{});
    const summary_values = [_]void{{}};
    const summaries = Spec.Summaries{
        .upload = .{ .values = &summary_values, .len = 1 },
    };
    var context = Context{};
    var state: Consumer.State = 0;
    const decision = handler.invokeMultipart(&context, &state, .{ .body = .{} }, summaries);

    try std.testing.expectEqual(@as(u16, 204), decision.commit);
    try std.testing.expectEqual(@as(u8, 1), context.value);
    try std.testing.expectEqual(@as(u8, 1), state);
}
