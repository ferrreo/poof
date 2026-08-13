const std = @import("std");
const address = @import("../address.zig");
const forwarding = @import("../forwarding.zig");
const body = @import("../body.zig");
const application_json_response = @import("../internal/application/json_response.zig");
const csrf_request = @import("../internal/csrf/request.zig");
const json_module = @import("../json.zig");
const html_response = @import("../html/response.zig");
const response = @import("../response.zig");
const response_stream = @import("../response/stream.zig");
const stream_response = @import("../response/streaming.zig");
const request_accept_encoding = @import("../internal/http1/request_accept_encoding.zig");
const request_head = @import("../internal/http1/request_head.zig");
const response_cors_fields = @import("../internal/http1/response_cors_fields.zig");
const syntax = @import("../internal/http1/syntax.zig");
const route_graph = @import("../internal/route_graph.zig");

pub const Bodyless = body.None;
pub const ResponseBodyError = error{
    ResponseBodyTooLarge,
    ResponseBodyWorkspaceUnavailable,
};

pub fn CorsStorage(comptime enabled: bool) type {
    return if (enabled) response_cors_fields.Fields else struct {};
}

pub fn storedCorsFields(storage: anytype) response_cors_fields.Fields {
    if (comptime @TypeOf(storage) == response_cors_fields.Fields) return storage;
    comptime std.debug.assert(@sizeOf(@TypeOf(storage)) == 0);
    return .{};
}

comptime {
    if (@sizeOf(CorsStorage(false)) != 0) @compileError("disabled CORS storage must be empty");
}

pub const HeaderOneError = error{
    Missing,
    Multiple,
};

pub const HeaderValues = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
    matches_count: usize,

    pub fn count(self: HeaderValues) usize {
        return self.matches_count;
    }

    pub fn first(self: HeaderValues) ?[]const u8 {
        var values = self.iterator();
        return values.next();
    }

    pub fn one(self: HeaderValues) HeaderOneError![]const u8 {
        return switch (self.matches_count) {
            0 => error.Missing,
            1 => self.first() orelse error.Missing,
            else => error.Multiple,
        };
    }

    pub fn iterator(self: HeaderValues) HeaderValueIterator {
        return .{
            .bytes = self.bytes,
            .fields = self.fields,
            .name = self.name,
        };
    }
};

pub const HeaderValueIterator = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    name: []const u8,
    index: usize = 0,

    pub fn next(self: *HeaderValueIterator) ?[]const u8 {
        while (self.index < self.fields.len) {
            const field = self.fields[self.index];
            self.index += 1;
            const field_name = safeSpan(field.name, self.bytes) orelse continue;
            const value = safeSpan(field.value, self.bytes) orelse continue;
            if (syntax.eqlIgnoreCase(field_name, self.name)) return value;
        }
        return null;
    }
};

pub const RawHeaderField = struct {
    name: []const u8,
    value: []const u8,
};

pub const RawHeaders = struct {
    bytes: []const u8,
    fields: []const request_head.Field,

    pub fn count(self: RawHeaders) usize {
        var fields = self.iterator();
        var total: usize = 0;
        while (fields.next() != null) total += 1;
        return total;
    }

    pub fn iterator(self: RawHeaders) RawHeaderIterator {
        return .{ .bytes = self.bytes, .fields = self.fields };
    }
};

pub const RawHeaderIterator = struct {
    bytes: []const u8,
    fields: []const request_head.Field,
    index: usize = 0,

    pub fn next(self: *RawHeaderIterator) ?RawHeaderField {
        while (self.index < self.fields.len) {
            const field = self.fields[self.index];
            self.index += 1;
            const name = safeSpan(field.name, self.bytes) orelse continue;
            const value = safeSpan(field.raw_value, self.bytes) orelse continue;
            return .{ .name = name, .value = value };
        }
        return null;
    }
};

/// Validated request fields borrowed through request completion or abort.
pub const RequestHeaders = struct {
    pub const OneError = HeaderOneError;
    pub const Values = HeaderValues;
    pub const ValueIterator = HeaderValueIterator;
    pub const Raw = RawHeaders;
    pub const RawIterator = RawHeaderIterator;
    pub const RawField = RawHeaderField;

    bytes: []const u8 = "",
    fields: []const request_head.Field = &.{},

    pub fn all(self: RequestHeaders, name: []const u8) Values {
        var values = HeaderValueIterator{
            .bytes = self.bytes,
            .fields = self.fields,
            .name = name,
        };
        var matches: usize = 0;
        while (values.next() != null) matches += 1;
        return .{
            .bytes = self.bytes,
            .fields = self.fields,
            .name = name,
            .matches_count = matches,
        };
    }

    pub fn first(self: RequestHeaders, name: []const u8) ?[]const u8 {
        var values = ValueIterator{ .bytes = self.bytes, .fields = self.fields, .name = name };
        return values.next();
    }

    pub fn one(self: RequestHeaders, name: []const u8) OneError![]const u8 {
        var values = ValueIterator{ .bytes = self.bytes, .fields = self.fields, .name = name };
        const value = values.next() orelse return error.Missing;
        if (values.next() != null) return error.Multiple;
        return value;
    }

    pub fn raw(self: RequestHeaders) Raw {
        return .{ .bytes = self.bytes, .fields = self.fields };
    }
};

fn safeSpan(span: request_head.Span, bytes: []const u8) ?[]const u8 {
    const start: usize = span.offset;
    const length: usize = span.length;
    if (start > bytes.len or length > bytes.len - start) return null;
    return bytes[start .. start + length];
}

pub const TrailerOneError = error{
    Missing,
    Multiple,
};

pub const TrailerValues = struct {
    section: []const u8,
    name: []const u8,
    matches_count: usize,

    pub fn count(self: TrailerValues) usize {
        return self.matches_count;
    }

    pub fn first(self: TrailerValues) ?[]const u8 {
        var values = self.iterator();
        return values.next();
    }

    pub fn one(self: TrailerValues) TrailerOneError![]const u8 {
        return switch (self.matches_count) {
            0 => error.Missing,
            1 => self.first() orelse error.Missing,
            else => error.Multiple,
        };
    }

    pub fn iterator(self: TrailerValues) TrailerValueIterator {
        return .{ .section = self.section, .name = self.name };
    }
};

pub const TrailerValueIterator = struct {
    section: []const u8,
    name: []const u8,
    cursor: usize = 0,

    pub fn next(self: *TrailerValueIterator) ?[]const u8 {
        while (nextTrailer(self.section, &self.cursor)) |field| {
            if (syntax.eqlIgnoreCase(field.name, self.name)) return field.value;
        }
        return null;
    }
};

pub const RawTrailerField = struct {
    name: []const u8,
    value: []const u8,
};

pub const RawTrailers = struct {
    section: []const u8,

    pub fn count(self: RawTrailers) usize {
        var fields = self.iterator();
        var total: usize = 0;
        while (fields.next() != null) total += 1;
        return total;
    }

    pub fn iterator(self: RawTrailers) RawTrailerIterator {
        return .{ .section = self.section };
    }
};

pub const RawTrailerIterator = struct {
    section: []const u8,
    cursor: usize = 0,

    pub fn next(self: *RawTrailerIterator) ?RawTrailerField {
        const field = nextTrailer(self.section, &self.cursor) orelse return null;
        return .{ .name = field.name, .value = field.raw_value };
    }
};

/// Validated trailer section borrowed through request completion or abort.
pub const RequestTrailers = struct {
    pub const OneError = TrailerOneError;
    pub const Values = TrailerValues;
    pub const ValueIterator = TrailerValueIterator;
    pub const Raw = RawTrailers;
    pub const RawIterator = RawTrailerIterator;
    pub const RawField = RawTrailerField;

    section: []const u8 = "",

    pub fn all(self: RequestTrailers, name: []const u8) Values {
        const section = if (sectionValid(self.section)) self.section else "";
        var cursor: usize = 0;
        var matches: usize = 0;
        while (nextTrailer(section, &cursor)) |field| {
            if (syntax.eqlIgnoreCase(field.name, name)) matches += 1;
        }
        return .{ .section = section, .name = name, .matches_count = matches };
    }

    pub fn raw(self: RequestTrailers) Raw {
        return .{ .section = if (sectionValid(self.section)) self.section else "" };
    }
};

const ParsedTrailer = struct {
    name: []const u8,
    raw_value: []const u8,
    value: []const u8,
};

fn sectionValid(section: []const u8) bool {
    if (section.len == 0) return true;
    var cursor: usize = 0;
    while (cursor < section.len) {
        const line_end = std.mem.indexOfPos(u8, section, cursor, "\r\n") orelse {
            return false;
        };
        if (line_end == cursor) return line_end + 2 == section.len;
        const line = section[cursor..line_end];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
        if (colon == 0) return false;
        if (!syntax.isToken(line[0..colon])) return false;
        if (!syntax.isFieldValue(line[colon + 1 ..])) return false;
        cursor = line_end + 2;
    }
    return false;
}

fn nextTrailer(section: []const u8, cursor: *usize) ?ParsedTrailer {
    if (cursor.* >= section.len) return null;
    const line_start = cursor.*;
    const relative_end = std.mem.indexOfPos(u8, section, line_start, "\r\n") orelse {
        cursor.* = section.len;
        return null;
    };
    cursor.* = relative_end + 2;
    if (relative_end == line_start) {
        cursor.* = section.len;
        return null;
    }
    const line = section[line_start..relative_end];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
        cursor.* = section.len;
        return null;
    };
    if (colon == 0) {
        cursor.* = section.len;
        return null;
    }
    const raw_value = line[colon + 1 ..];
    return .{
        .name = line[0..colon],
        .raw_value = raw_value,
        .value = syntax.trimOws(raw_value),
    };
}

/// Semantically admitted request data borrowed through `complete` or `abort`.
pub const Input = struct {
    pub const ploof_template_helper_capability = true;

    method: []const u8,
    path: []const u8,
    raw_target: []const u8,
    raw_path: []const u8,
    raw_query: ?[]const u8 = null,
    date: []const u8,
    connection_close: bool = false,
    accept_encoding: request_accept_encoding.Preferences = .{},
    accepts_response_trailers: bool = false,
    body: body.Decoded = .none,
    trailers: RequestTrailers = .{},
    headers: RequestHeaders = .{},
    /// Live listeners set this before routing. Borrowed text shares request-head lifetime.
    forwarding: ?forwarding.Metadata = null,
};

pub const Request = struct {
    pub const ploof_template_helper_capability = true;

    method: []const u8,
    raw_target: []const u8,
    raw_path: []const u8,
    path: []const u8,
    raw_query: ?[]const u8,
    route_pattern: ?[]const u8 = null,
    captures: []const route_graph.Capture = &.{},
    accepts_response_trailers: bool = false,
    trailers: RequestTrailers = .{},
    headers: RequestHeaders = .{},
    /// Null only for direct semantic application calls outside a listener.
    forwarding: ?forwarding.Metadata = null,

    pub fn param(request: Request, name: []const u8) ?[]const u8 {
        for (request.captures) |capture| {
            if (std.mem.eql(u8, capture.name, name)) return capture.value(request.path);
        }
        return null;
    }

    /// Resolved client endpoint after the listener's forwarding policy.
    pub fn clientEndpoint(request: Request) ?address.Endpoint {
        const metadata = request.forwarding orelse return null;
        return metadata.client;
    }

    /// Resolved client IP after the listener's forwarding policy.
    pub fn clientIp(request: Request) ?address.Address {
        const endpoint = request.clientEndpoint() orelse return null;
        return endpoint.address;
    }

    /// Immutable socket peer authenticated by the listener.
    pub fn transportPeer(request: Request) ?address.Endpoint {
        const metadata = request.forwarding orelse return null;
        return metadata.transport_peer;
    }

    /// Effective normalized authority. Host text retains request lifetime.
    pub fn effectiveAuthority(request: Request) ?forwarding.Authority {
        const metadata = request.forwarding orelse return null;
        return metadata.authority;
    }

    /// Effective host without its normalized port. Text retains request lifetime.
    pub fn effectiveHost(request: Request) ?forwarding.Host {
        const effective = request.effectiveAuthority() orelse return null;
        return effective.host;
    }

    pub fn effectiveScheme(request: Request) ?forwarding.Scheme {
        const metadata = request.forwarding orelse return null;
        return metadata.scheme;
    }

    /// Typed trust provenance for audit and logging decisions.
    pub fn forwardingProvenance(request: Request) ?forwarding.Provenance {
        const metadata = request.forwarding orelse return null;
        return metadata.provenance();
    }
};

pub fn Context(comptime State: type, comptime requested_maximum: response.HeadLimits) type {
    const maximum = comptime requested_maximum.validate();
    const ResponseWorkspace = response.Workspace(maximum);
    const Response = response.Response(maximum);

    return struct {
        const Self = @This();

        pub const ploof_template_helper_capability = true;
        pub const ApplicationState = State;
        pub const ResponseType = Response;
        pub const ResponseWorkspaceType = ResponseWorkspace;

        pub fn StreamResponse(comptime Producer: type) type {
            return stream_response.Response(maximum, Producer);
        }

        state: *State,
        request: Request,
        response_workspace: *ResponseWorkspace,
        response_body: ?[]u8 = null,
        json_response: ?*application_json_response.Binding = null,
        csrf_request: ?*csrf_request.State = null,

        pub fn __finiteResponseOutput(
            self: *const Self,
            body_bytes: []const u8,
            fallback: []u8,
        ) []u8 {
            return application_json_response.outputFor(
                self.json_response,
                body_bytes,
                fallback,
            );
        }

        pub fn html(
            _: *Self,
            status: response.Status,
            comptime Page: type,
            view: Page.View,
        ) html_response.TemplateResponse(Page) {
            return .{ .status = status, .view = view };
        }

        pub fn htmlLayout(
            _: *Self,
            status: response.Status,
            comptime Layout: type,
            comptime Body: type,
            layout_view: Layout.View,
            body_view: Layout.LayoutBodyView(Body),
        ) html_response.LayoutResponse(Layout, Body) {
            return .{
                .status = status,
                .layout_view = layout_view,
                .body_view = body_view,
            };
        }

        pub fn stream(
            self: *Self,
            status: response.Status,
            selected_media_type: response.MediaType,
            descriptor: anytype,
        ) response.InitError!StreamResponse(response_stream.producerType(@TypeOf(descriptor))) {
            const Producer = response_stream.producerType(@TypeOf(descriptor));
            return StreamResponse(Producer).init(
                self.response_workspace,
                status,
                selected_media_type,
                descriptor,
            );
        }

        pub fn streamUnknown(
            self: *Self,
            comptime status: response.Status,
            comptime selected_media_type: response.MediaType,
            producer: anytype,
            trailer_names: []const []const u8,
        ) StreamResponse(@TypeOf(producer)) {
            comptime stream_response.assertStaticHead(status, selected_media_type);
            return StreamResponse(@TypeOf(producer)).init(
                self.response_workspace,
                status,
                selected_media_type,
                response_stream.unknown(producer, trailer_names),
            ) catch unreachable;
        }

        pub fn streamExact(
            self: *Self,
            comptime status: response.Status,
            comptime selected_media_type: response.MediaType,
            length: u64,
            producer: anytype,
        ) StreamResponse(@TypeOf(producer)) {
            comptime stream_response.assertStaticHead(status, selected_media_type);
            return StreamResponse(@TypeOf(producer)).init(
                self.response_workspace,
                status,
                selected_media_type,
                response_stream.exact(length, producer),
            ) catch unreachable;
        }

        pub fn empty(self: *Self, comptime status: response.Status) Response {
            return Response.empty(self.response_workspace, status);
        }

        /// Copies dynamic text into fixed request-owned storage before returning.
        pub fn text(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) ResponseBodyError!Response {
            return Response.textBorrowed(
                self.response_workspace,
                status,
                try self.copyResponseBody(value),
            );
        }

        /// Formats dynamic text directly into fixed request-owned storage.
        pub fn textFormat(
            self: *Self,
            comptime status: response.Status,
            comptime format: []const u8,
            arguments: anytype,
        ) ResponseBodyError!Response {
            const output = self.response_body orelse
                return error.ResponseBodyWorkspaceUnavailable;
            const rendered = std.fmt.bufPrint(output, format, arguments) catch
                return error.ResponseBodyTooLarge;
            return Response.textBorrowed(self.response_workspace, status, rendered);
        }

        pub fn textStatic(
            self: *Self,
            comptime status: response.Status,
            comptime value: []const u8,
        ) Response {
            return Response.textStatic(self.response_workspace, status, value);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn textBorrowed(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) Response {
            return Response.textBorrowed(self.response_workspace, status, value);
        }

        pub fn htmlStatic(
            self: *Self,
            comptime status: response.Status,
            comptime value: []const u8,
        ) Response {
            return Response.htmlStatic(self.response_workspace, status, value);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn htmlBorrowed(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) Response {
            return Response.htmlBorrowed(self.response_workspace, status, value);
        }

        pub fn jsonStatic(
            self: *Self,
            comptime status: response.Status,
            comptime value: []const u8,
        ) Response {
            return Response.jsonStatic(self.response_workspace, status, value);
        }

        pub fn json(
            self: *Self,
            comptime status: response.Status,
            value: anytype,
        ) application_json_response.Error(@TypeOf(value))!Response {
            return application_json_response.encode(
                Response,
                self.response_workspace,
                self.json_response,
                json_module.Options{ .encoded_bytes_max = std.math.maxInt(usize) },
                status,
                value,
            );
        }

        pub fn jsonWith(
            self: *Self,
            comptime options: json_module.Options,
            comptime status: response.Status,
            value: anytype,
        ) application_json_response.Error(@TypeOf(value))!Response {
            return application_json_response.encode(
                Response,
                self.response_workspace,
                self.json_response,
                options,
                status,
                value,
            );
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn jsonBorrowed(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) Response {
            return Response.jsonBorrowed(self.response_workspace, status, value);
        }

        pub fn bytesStatic(
            self: *Self,
            comptime status: response.Status,
            comptime value: []const u8,
        ) Response {
            return Response.bytesStatic(self.response_workspace, status, value);
        }

        /// Copies dynamic bytes into fixed request-owned storage before returning.
        pub fn bytes(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) ResponseBodyError!Response {
            return Response.bytesBorrowed(
                self.response_workspace,
                status,
                try self.copyResponseBody(value),
            );
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn bytesBorrowed(
            self: *Self,
            comptime status: response.Status,
            value: []const u8,
        ) Response {
            return Response.bytesBorrowed(self.response_workspace, status, value);
        }

        fn copyResponseBody(self: *Self, value: []const u8) ResponseBodyError![]const u8 {
            const output = self.response_body orelse
                return error.ResponseBodyWorkspaceUnavailable;
            if (value.len > output.len) return error.ResponseBodyTooLarge;
            std.mem.copyForwards(u8, output[0..value.len], value);
            return output[0..value.len];
        }
    };
}
