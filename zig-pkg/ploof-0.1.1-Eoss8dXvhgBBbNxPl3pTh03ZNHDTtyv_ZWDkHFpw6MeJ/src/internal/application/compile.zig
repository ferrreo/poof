const std = @import("std");
const body = @import("../../body.zig");
const application_context = @import("../../application/context.zig");
const application_body = @import("body.zig");
const application_compile_errors = @import("compile_errors.zig");
const application_compile_multipart = @import("compile_multipart.zig");
const application_routes = @import("routes.zig");
const application_state_compile = @import("state_compile.zig");
const application_stream_compile = @import("stream_compile.zig");
const multipart = @import("../../multipart.zig");
const response = @import("../../response.zig");
const response_stream = @import("../../response/stream.zig");
const route = @import("../../route.zig");

const validateErrorSubset = application_compile_errors.validateSubset;

pub const Definition = application_routes.Definition;
pub const countRoutes = application_routes.count;
pub const makeDefinitions = application_routes.definitions;
pub const makeRouteTarget = application_routes.target;
pub const makeBodyPlans = application_routes.bodyPlans;
pub const makeFiniteOutputPlans = application_routes.finiteOutputPlans;
pub const hasBodyEndpoint = application_routes.hasBodyEndpoint;
pub const hasRequestBodyEndpoint = application_routes.hasRequestBodyEndpoint;
pub const hasMultipartEndpoint = application_routes.hasMultipartEndpoint;
pub const countOpenMetrics = application_routes.countOpenMetrics;
pub const maximumDecodedBodyBytes = application_routes.maximumDecodedBodyBytes;
pub const maximumWorkspaceAlignment = application_routes.maximumWorkspaceAlignment;
pub const StateTuple = application_state_compile.StateTuple;
pub const maximumStateBytes = application_state_compile.maximumStateBytes;
pub const maximumStateAlignment = application_state_compile.maximumStateAlignment;

pub const StreamLayout = application_stream_compile.Layout;
pub const StreamStorage = application_stream_compile.Storage;

pub fn streamLayout(
    comptime descriptors: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
) StreamLayout {
    var layout = StreamLayout{};
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => if (!route.isOpenMetricsHandler(descriptor.handler)) {
            layout.include(validateHandler(
                descriptor.handler,
                ContextType,
                Response,
                AppError,
                application_body.Input(descriptor.handler),
            ));
        },
        .static_dir, .static_file => {},
        .group => layout.include(streamLayout(
            descriptor.children,
            ContextType,
            Response,
            AppError,
        )),
    };
    return layout;
}

pub fn validateTuple(comptime value: anytype, comptime message: []const u8) void {
    const info = @typeInfo(@TypeOf(value));
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError(message);
}

pub fn validateApplicationError(comptime Error: type) void {
    const info = @typeInfo(Error);
    if (info != .error_set) {
        @compileError("PLOOF-E3056 Application Error must be an error set");
    }
    if (info.error_set == null) {
        @compileError("PLOOF-E3057 Application Error must be finite");
    }
}

pub fn validateLogicalMaximum(
    comptime maximum: response.HeadLimits,
    comptime logical: response.HeadLimits,
) void {
    _ = maximum.validate();
    _ = logical.validate();
    if (logical.head_bytes_max > maximum.head_bytes_max or
        logical.field_line_bytes_max > maximum.field_line_bytes_max or
        logical.fields_max > maximum.fields_max)
    {
        @compileError("PLOOF-E3058 response limits exceed Application workspace maximum");
    }
}

pub fn errorMapper(
    comptime config: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
) ?fn (*ContextType, AppError) Response {
    if (!@hasField(@TypeOf(config), "map_error")) return null;
    const expected = fn (*ContextType, AppError) Response;
    if (@TypeOf(config.map_error) != expected) {
        @compileError("PLOOF-E3059 map_error must be fn (*Context, Error) Response");
    }
    return config.map_error;
}

pub fn validateDescriptors(
    comptime descriptors: anytype,
    comptime inherited: anytype,
    comptime app_middleware: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime maximum: response.HeadLimits,
    comptime graph_limits: route.GraphLimits,
    comptime Outcome: type,
) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => {
            validateChildRoutePath(descriptor.path);
            const middleware = app_middleware ++ inherited ++ descriptor.middleware;
            validateMiddlewareBounds(middleware, graph_limits);
            if (route.isOpenMetricsHandler(descriptor.handler) and
                descriptor.method != .get)
            {
                @compileError("PLOOF-E3090 OpenMetrics route method must be GET");
            }
            const BodyInput = if (route.isOpenMetricsHandler(descriptor.handler))
                body.None
            else
                application_body.Input(descriptor.handler);
            const handler_layout = if (route.isOpenMetricsHandler(descriptor.handler))
                StreamLayout{}
            else
                validateHandler(
                    descriptor.handler,
                    ContextType,
                    Response,
                    AppError,
                    BodyInput,
                );
            validateMiddlewareTupleForHandler(
                middleware,
                ContextType,
                Response,
                AppError,
                BodyInput,
                Outcome,
                handler_layout.stream_enabled,
            );
            if (descriptor.response_head_limits) |selected| {
                validateLogicalMaximum(maximum, selected);
            }
        },
        .static_dir, .static_file => {
            const middleware = app_middleware ++ inherited ++ descriptor.middleware;
            validateMiddlewareBounds(middleware, graph_limits);
            validateMiddlewareTupleForHandler(
                middleware,
                ContextType,
                Response,
                AppError,
                body.None,
                Outcome,
                false,
            );
            if (descriptor.response_head_limits) |selected| {
                validateLogicalMaximum(maximum, selected);
            }
        },
        .group => {
            validateGroupPrefix(descriptor.prefix);
            validateDescriptors(
                descriptor.children,
                inherited ++ descriptor.middleware,
                app_middleware,
                ContextType,
                Response,
                AppError,
                maximum,
                graph_limits,
                Outcome,
            );
        },
    };
}

pub fn validateDescriptorShapes(comptime descriptors: anytype) void {
    inline for (descriptors) |descriptor| switch (descriptor.kind) {
        .route => validateChildRoutePath(descriptor.path),
        .static_dir => validateChildRoutePath(descriptor.mount_path),
        .static_file => validateChildRoutePath(descriptor.url_path),
        .group => {
            validateGroupPrefix(descriptor.prefix);
            validateDescriptorShapes(descriptor.children);
        },
    };
}

fn validateChildRoutePath(comptime path: []const u8) void {
    if (path.len == 0 or path[0] != '/') {
        @compileError("PLOOF-E3076 child route path must begin with '/'");
    }
}

fn validateGroupPrefix(comptime prefix: []const u8) void {
    if (prefix.len == 0) return;
    if (prefix[0] != '/') @compileError("PLOOF-E3060 group prefix must begin with '/'");
    if (prefix[prefix.len - 1] == '/') {
        @compileError("PLOOF-E3061 group prefix must not end with '/'");
    }
}

pub fn validateMiddlewareBounds(
    comptime middleware: anytype,
    comptime limits: route.GraphLimits,
) void {
    if (middleware.len > limits.middleware_max) {
        @compileError("PLOOF-E3062 route middleware chain exceeds configured limit");
    }
    const States = StateTuple(middleware);
    if (@sizeOf(States) > limits.middleware_state_bytes_max) {
        @compileError("PLOOF-E3063 route middleware state exceeds configured byte limit");
    }
}

pub fn validateMiddlewareTuple(
    comptime middleware: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime Bodyless: type,
    comptime Outcome: type,
) void {
    validateMiddlewareTupleForHandler(
        middleware,
        ContextType,
        Response,
        AppError,
        Bodyless,
        Outcome,
        false,
    );
}

fn validateMiddlewareTupleForHandler(
    comptime middleware: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime Bodyless: type,
    comptime Outcome: type,
    comptime stream_enabled: bool,
) void {
    validateTuple(middleware, "PLOOF-E3064 middleware chain must be a tuple");
    inline for (middleware) |item| {
        validateMiddleware(
            item,
            ContextType,
            Response,
            AppError,
            Bodyless,
            Outcome,
            stream_enabled,
        );
    }
}

fn validateMiddleware(
    comptime item: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime Bodyless: type,
    comptime Outcome: type,
    comptime stream_enabled: bool,
) void {
    const Middleware = @TypeOf(item);
    if (!@hasDecl(Middleware, "State")) {
        @compileError("PLOOF-E3065 middleware must declare State");
    }
    const State = Middleware.State;
    if (@TypeOf(State) != type) {
        @compileError("PLOOF-E3066 middleware State must be a type");
    }
    if (State != void) validateInit(Middleware, State);
    if (@hasDecl(Middleware, "head")) validatePhase(
        Middleware.head,
        &.{ Middleware, *ContextType, *State },
        ?Response,
        AppError,
        "PLOOF-E3069 invalid head signature",
    );
    if (@hasDecl(Middleware, "body")) validateBodyPhase(
        Middleware.body,
        &.{ Middleware, *ContextType, *State },
        Bodyless,
        ?Response,
        AppError,
        "PLOOF-E3070 invalid body signature",
    );
    if (@hasDecl(Middleware, "response")) validateResponsePhase(
        Middleware.response,
        &.{ Middleware, *ContextType, *State },
        Response,
        AppError,
        stream_enabled,
        "PLOOF-E3071 invalid response signature",
    );
    if (@hasDecl(Middleware, "after")) validateMethod(
        Middleware.after,
        &.{ Middleware, *const ContextType, *State, Outcome, void },
        "PLOOF-E3072 invalid after signature",
    );
}

fn validateInit(comptime Middleware: type, comptime State: type) void {
    if (!@hasDecl(Middleware, "init")) {
        @compileError("PLOOF-E3067 non-void middleware State requires init");
    }
    validateMethod(
        Middleware.init,
        &.{ Middleware, State },
        "PLOOF-E3068 invalid init signature",
    );
}

fn validateHandler(
    comptime handler: anytype,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime BodyInput: type,
) StreamLayout {
    if (application_body.isEndpoint(handler)) {
        const Handler = @TypeOf(handler);
        if (comptime @hasDecl(Handler, "ploof_multipart_endpoint") and
            Handler.ploof_multipart_endpoint)
        {
            return validateMultipartHandler(
                Handler,
                ContextType,
                Response,
                AppError,
                BodyInput,
            );
        }
        return validateHandlerFunction(
            @TypeOf(handler).handler_fn,
            &.{ *ContextType, BodyInput },
            ContextType,
            Response,
            AppError,
            "PLOOF-E3073 invalid handler signature",
        );
    }
    const Handler = @TypeOf(handler);
    if (@typeInfo(Handler) == .@"fn") {
        return validateHandlerFunction(
            handler,
            &.{*ContextType},
            ContextType,
            Response,
            AppError,
            "PLOOF-E3073 invalid handler signature",
        );
    }
    if (@typeInfo(Handler) == .@"struct" and @hasDecl(Handler, "handle")) {
        return validateHandlerFunction(
            Handler.handle,
            &.{ Handler, *ContextType },
            ContextType,
            Response,
            AppError,
            "PLOOF-E3073 invalid handler signature",
        );
    }
    @compileError("PLOOF-E3073 invalid handler signature");
}

fn validateMultipartHandler(
    comptime Handler: type,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime BodyInput: type,
) StreamLayout {
    const Consumer = Handler.MultipartConsumer;
    const State = Handler.MultipartState;
    if (State != void) validateMethod(
        Consumer.init,
        &.{ Consumer, *ContextType, State },
        "PLOOF-E3455 invalid multipart consumer init signature",
    );
    const Field = Handler.definition.MultipartBodySpec.Field;
    if (Field != void) validateMethod(
        Consumer.field,
        &.{ Consumer, *State, Field, void },
        "PLOOF-E3456 invalid multipart consumer field signature",
    );
    const Spec = Handler.definition.MultipartBodySpec;
    if (Spec.FileStart != void) validatePhase(
        Consumer.fileStart,
        &.{ Consumer, *ContextType, *State, Spec.FileStart },
        Spec.FileAdmission(Response),
        AppError,
        "PLOOF-E3459 invalid multipart consumer fileStart signature",
    );
    return application_compile_multipart.validateComplete(
        Consumer.complete,
        &.{ Consumer, *ContextType, *State, BodyInput, Spec.Summaries },
        ContextType,
        Response,
        AppError,
        "PLOOF-E3457 invalid multipart consumer complete signature",
    );
}

fn validateHandlerFunction(
    comptime function: anytype,
    comptime parameters: []const type,
    comptime ContextType: type,
    comptime Response: type,
    comptime AppError: type,
    comptime message: []const u8,
) StreamLayout {
    const info = functionInfo(function, message);
    if (info.params.len != parameters.len) @compileError(message);
    inline for (parameters, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
    const Return = info.return_type.?;
    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
    const layout = application_stream_compile.classifyPayload(Payload, ContextType, Response) orelse
        @compileError(message);
    if (comptime @import("../../html/response.zig").is(Payload)) {
        validateErrorSubset(Payload.ApplicationError, AppError);
    }
    switch (@typeInfo(Return)) {
        .error_union => |error_union| validateErrorSubset(error_union.error_set, AppError),
        else => {},
    }
    return layout;
}

fn validateBodyPhase(
    comptime function: anytype,
    comptime prefix: []const type,
    comptime BodyInput: type,
    comptime payload: type,
    comptime AppError: type,
    comptime message: []const u8,
) void {
    const info = functionInfo(function, message);
    if (info.params.len != prefix.len + 1) @compileError(message);
    inline for (prefix, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
    const body_parameter = info.params[prefix.len].type;
    if (body_parameter != null and body_parameter.? != BodyInput) @compileError(message);
    validatePhaseReturn(info.return_type.?, payload, AppError, message);
}

const ResponseParameter = enum(u8) {
    generic,
    finite,
    invalid,
};

fn validateResponsePhase(
    comptime function: anytype,
    comptime prefix: []const type,
    comptime Response: type,
    comptime AppError: type,
    comptime require_generic: bool,
    comptime message: []const u8,
) void {
    const info = functionInfo(function, message);
    if (info.params.len != prefix.len + 1) @compileError(message);
    inline for (prefix, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
    const response_parameter = classifyResponseParameter(info.params[prefix.len], Response);
    if (!validResponseParameter(response_parameter, require_generic)) @compileError(message);
    validatePhaseReturn(info.return_type.?, void, AppError, message);
}

fn classifyResponseParameter(
    comptime parameter: std.builtin.Type.Fn.Param,
    comptime Response: type,
) ResponseParameter {
    if (parameter.is_generic and parameter.type == null) return .generic;
    if (!parameter.is_generic and parameter.type != null and parameter.type.? == *Response) {
        return .finite;
    }
    return .invalid;
}

fn validResponseParameter(kind: ResponseParameter, require_generic: bool) bool {
    return kind != .invalid and (!require_generic or kind == .generic);
}

fn validateMethod(
    comptime function: anytype,
    comptime types: []const type,
    comptime message: []const u8,
) void {
    const info = functionInfo(function, message);
    const return_type = types[types.len - 1];
    const parameters = types[0 .. types.len - 1];
    if (info.params.len != parameters.len or info.return_type.? != return_type) {
        @compileError(message);
    }
    inline for (parameters, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
}

fn validatePhase(
    comptime function: anytype,
    comptime parameters: []const type,
    comptime payload: type,
    comptime AppError: type,
    comptime message: []const u8,
) void {
    const info = functionInfo(function, message);
    if (info.params.len != parameters.len) @compileError(message);
    inline for (parameters, 0..) |expected, index| {
        if (info.params[index].type == null or info.params[index].type.? != expected) {
            @compileError(message);
        }
    }
    const Return = info.return_type orelse @compileError(message);
    validatePhaseReturn(Return, payload, AppError, message);
}

fn validatePhaseReturn(
    comptime return_type: type,
    comptime payload: type,
    comptime AppError: type,
    comptime message: []const u8,
) void {
    switch (@typeInfo(return_type)) {
        .error_union => |error_union| {
            if (error_union.payload != payload) @compileError(message);
            validateErrorSubset(error_union.error_set, AppError);
        },
        else => if (return_type != payload) @compileError(message),
    }
}

fn functionInfo(
    comptime function: anytype,
    comptime message: []const u8,
) std.builtin.Type.Fn {
    return switch (@typeInfo(@TypeOf(function))) {
        .@"fn" => |info| info,
        else => @compileError(message),
    };
}

const CompileTestContext = application_context.Context(void, response.standard_head_limits);
const CompileTestResponse = response.Response(response.standard_head_limits);
const CompileTestError = error{Expected};
const CompileMultipartSpec = @TypeOf(multipart.decode(.{
    .upload = multipart.file(multipart.DiscardSink, multipart.required),
}, .{}));
const CompileMultipartInput = struct { body: multipart.PushInput };
const CompileMultipartConsumer = struct {
    pub const State = void;

    pub fn fileStart(
        _: @This(),
        _: *CompileTestContext,
        _: *State,
        _: CompileMultipartSpec.FileStart,
    ) CompileTestError!CompileMultipartSpec.FileAdmission(CompileTestResponse) {
        return error.Expected;
    }

    pub fn complete(
        _: @This(),
        _: *CompileTestContext,
        _: *State,
        _: CompileMultipartInput,
        _: CompileMultipartSpec.Summaries,
    ) CompileTestError!multipart.Decision(CompileTestResponse) {
        return error.Expected;
    }
};
const CompileMultipartHandler = struct {
    pub const MultipartConsumer = CompileMultipartConsumer;
    pub const MultipartState = CompileMultipartConsumer.State;
    pub const definition = struct {
        pub const MultipartBodySpec = CompileMultipartSpec;
    };
};
const CompileProducer = struct {
    bytes: [65]u8 align(32),

    pub fn poll(
        _: *@This(),
        _: []u8,
        _: response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult {
        return .pending;
    }
};

fn finiteHandler(_: *CompileTestContext) CompileTestResponse {
    unreachable;
}

fn largeStreamHandler(_: *CompileTestContext) CompileTestContext.StreamResponse(CompileProducer) {
    unreachable;
}

fn alignedStreamHandler(
    _: *CompileTestContext,
) CompileTestError!CompileTestContext.StreamResponse(CompileProducer) {
    unreachable;
}

fn bodyStreamHandler(
    _: *CompileTestContext,
    _: body.Bytes,
) CompileTestContext.StreamResponse(CompileProducer) {
    unreachable;
}

const HandleStreamHandler = struct {
    fn handle(
        _: @This(),
        _: *CompileTestContext,
    ) CompileTestContext.StreamResponse(CompileProducer) {
        unreachable;
    }
};

const GenericResponseMiddleware = struct {
    pub const State = void;

    fn response(_: @This(), _: *CompileTestContext, _: *void, _: anytype) void {}
};

const FiniteResponseMiddleware = struct {
    pub const State = void;

    fn response(_: @This(), _: *CompileTestContext, _: *void, _: *CompileTestResponse) void {}
};

const compile_test_routes = .{
    route.get("/finite", finiteHandler),
    route.group("/nested", .{}, .{
        route.get("/large", largeStreamHandler),
        route.get("/aligned", alignedStreamHandler),
        route.post("/body", body.bytes(.{}, bodyStreamHandler)),
        route.get("/handle", HandleStreamHandler{}),
    }),
};

test "stream handler classification preserves forms errors and recursive layout" {
    const layout = comptime streamLayout(
        compile_test_routes,
        CompileTestContext,
        CompileTestResponse,
        CompileTestError,
    );
    try std.testing.expect(layout.stream_enabled);
    try std.testing.expectEqual(@sizeOf(CompileProducer), layout.producer_bytes_max);
    try std.testing.expectEqual(@alignOf(CompileProducer), layout.producer_alignment_max);

    comptime validateDescriptors(
        compile_test_routes,
        .{},
        .{GenericResponseMiddleware{}},
        CompileTestContext,
        CompileTestResponse,
        CompileTestError,
        response.standard_head_limits,
        route.standard_graph_limits,
        struct {},
    );
    comptime validateMiddlewareTuple(
        .{ GenericResponseMiddleware{}, FiniteResponseMiddleware{} },
        CompileTestContext,
        CompileTestResponse,
        CompileTestError,
        body.None,
        struct {},
    );
}

test "multipart consumer contract accepts declared application error subsets" {
    const layout = comptime validateMultipartHandler(
        CompileMultipartHandler,
        CompileTestContext,
        CompileTestResponse,
        CompileTestError,
        CompileMultipartInput,
    );
    try std.testing.expect(!layout.stream_enabled);
}

test "response middleware parameter classification is exact" {
    try std.testing.expectEqual(
        ResponseParameter.generic,
        classifyResponseParameter(functionInfo(
            GenericResponseMiddleware.response,
            "unreachable",
        ).params[3], CompileTestResponse),
    );
    try std.testing.expectEqual(
        ResponseParameter.finite,
        classifyResponseParameter(functionInfo(
            FiniteResponseMiddleware.response,
            "unreachable",
        ).params[3], CompileTestResponse),
    );
    try std.testing.expect(validResponseParameter(.generic, true));
    try std.testing.expect(validResponseParameter(.finite, false));
    try std.testing.expect(!validResponseParameter(.finite, true));
    try std.testing.expect(!validResponseParameter(.invalid, false));
}
