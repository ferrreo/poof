const application_body = @import("body.zig");
const application_context = @import("../../application/context.zig");
const application_response_output = @import("response_output.zig");
const application_stream_output = @import("stream_output.zig");

pub fn Result(comptime FiniteResponse: type, comptime StreamResponse: type) type {
    return union(enum) {
        finite: FiniteResponse,
        stream: StreamResponse,
    };
}

pub fn handlerReturn(comptime handler: anytype) type {
    return handlerReturnType(@TypeOf(handler));
}

pub fn invoke(
    handler: anytype,
    context: anytype,
    body_input: anytype,
    handler_state: anytype,
    multipart_summaries: anytype,
) handlerReturnType(@TypeOf(handler)) {
    const Handler = @TypeOf(handler);
    return if (comptime multipartHandler(Handler))
        handler.invokeMultipart(
            context,
            handler_state,
            body_input,
            multipart_summaries,
        )
    else if (comptime application_body.isEndpointType(Handler))
        handler.invoke(context, body_input)
    else if (@typeInfo(Handler) == .@"fn")
        handler(context)
    else
        handler.handle(context);
}

fn handlerReturnType(comptime Handler: type) type {
    if (@typeInfo(Handler) == .@"fn") {
        return @typeInfo(Handler).@"fn".return_type.?;
    }
    const function = if (application_body.isEndpointType(Handler))
        if (comptime @hasDecl(Handler, "ploof_multipart_endpoint") and
            Handler.ploof_multipart_endpoint)
            Handler.MultipartConsumer.complete
        else
            Handler.handler_fn
    else
        Handler.handle;
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

fn multipartHandler(comptime Handler: type) bool {
    return @typeInfo(Handler) == .@"struct" and
        @hasDecl(Handler, "ploof_multipart_endpoint") and
        Handler.ploof_multipart_endpoint;
}

pub fn handlerPayload(comptime handler: anytype) type {
    const Handler = @TypeOf(handler);
    const Return = handlerReturn(handler);
    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
    if (comptime multipartHandler(Handler)) {
        if (@typeInfo(Payload) != .@"union" or !@hasField(Payload, "commit")) {
            @compileError("PLOOF-E3457 invalid multipart consumer complete signature");
        }
        return @FieldType(Payload, "commit");
    }
    return Payload;
}

pub fn request(input: anytype, cors_storage: anytype) application_stream_output.RequestFields {
    return .{
        .method = input.method,
        .accept_encoding = input.accept_encoding,
        .accepts_response_trailers = input.accepts_response_trailers,
        .date = input.date,
        .connection_close = input.connection_close,
        .cors_fields = application_context.storedCorsFields(cors_storage),
    };
}

pub fn prepared(
    value: application_stream_output.Prepared,
) application_response_output.Prepared {
    return .{
        .source = .{ .contiguous_wire = value.bytes },
        .bytes = value.bytes,
        .status = value.status,
        .close_connection = value.close_connection,
        .coding_outcome = switch (value.coding_outcome) {
            .identity => .identity_negotiated,
            .not_acceptable => .not_acceptable,
        },
        .transmission = .{ .stream = .{
            .framing = value.framing,
            .trailers = value.trailers,
        } },
    };
}
