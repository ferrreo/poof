const std = @import("std");
const response = @import("../response.zig");
const response_stream = @import("stream.zig");
const response_headers = @import("../internal/http1/response_headers.zig");

/// Owned response head paired with a protocol-neutral streaming descriptor.
pub fn Response(
    comptime requested_maximum: response.HeadLimits,
    comptime Producer: type,
) type {
    const maximum = comptime requested_maximum.validate();
    const Workspace = response.Workspace(maximum);
    const HeaderStorage = Workspace.HeaderStorage;
    const Descriptor = response_stream.Response(Producer);

    return struct {
        const Self = @This();

        pub const ProducerType = Producer;
        pub const DescriptorType = Descriptor;
        pub const WorkspaceType = Workspace;

        status: response.Status,
        media_type: response.MediaType,
        headers: *HeaderStorage,
        stream: Descriptor,

        pub fn init(
            workspace: *Workspace,
            status: response.Status,
            selected_media_type: response.MediaType,
            descriptor: Descriptor,
        ) response.InitError!Self {
            try validateParts(status, selected_media_type, descriptor);
            workspace.clear();
            return .{
                .status = status,
                .media_type = selected_media_type,
                .headers = &workspace.headers,
                .stream = descriptor,
            };
        }

        pub fn validate(self: *const Self) response.InitError!void {
            try validateParts(self.status, self.media_type, self.stream);
        }

        pub fn validateOwned(
            self: *const Self,
            workspace: *const Workspace,
        ) response.InitError!void {
            if (self.headers != &workspace.headers) return error.InvalidResponse;
            try self.validate();
        }

        pub fn selectedLimits(self: *const Self) response.HeadLimits {
            return self.headers.selectedLimits();
        }

        pub fn setStatus(self: *Self, status: response.Status) response.InitError!void {
            try validateParts(status, self.media_type, self.stream);
            self.status = status;
        }

        pub fn setMediaType(
            self: *Self,
            selected_media_type: response.MediaType,
        ) response.InitError!void {
            try validateParts(self.status, selected_media_type, self.stream);
            self.media_type = selected_media_type;
        }

        pub fn setHeader(
            self: *Self,
            name: []const u8,
            value: []const u8,
        ) response.HeaderMutationError!void {
            try self.headers.set(name, value);
        }

        pub fn appendHeader(
            self: *Self,
            name: []const u8,
            value: []const u8,
        ) response.HeaderMutationError!void {
            try self.headers.append(name, value);
        }

        pub fn removeHeader(self: *Self, name: []const u8) response.HeaderMutationError!void {
            try self.headers.remove(name);
        }

        pub fn setHeaderStatic(
            self: *Self,
            comptime name: []const u8,
            comptime value: []const u8,
        ) response.HeaderMutationError!void {
            comptime response_headers.validateStaticSet(name, value);
            try self.headers.set(name, value);
        }

        pub fn appendHeaderStatic(
            self: *Self,
            comptime name: []const u8,
            comptime value: []const u8,
        ) response.HeaderMutationError!void {
            comptime response_headers.validateStaticAppend(name, value);
            try self.headers.append(name, value);
        }

        pub fn removeHeaderStatic(
            self: *Self,
            comptime name: []const u8,
        ) response.HeaderMutationError!void {
            comptime response_headers.validateStaticRemove(name);
            try self.headers.remove(name);
        }
    };
}

pub fn assertStaticHead(
    comptime status: response.Status,
    comptime selected_media_type: response.MediaType,
) void {
    validateHead(status, selected_media_type) catch |problem| {
        @compileError(switch (problem) {
            error.InvalidResponse => "PLOOF-E3040 invalid static response status/body combination",
            error.InvalidMediaType => "PLOOF-E3041 invalid static response media type",
        });
    };
}

fn validateParts(
    status: response.Status,
    selected_media_type: response.MediaType,
    descriptor: anytype,
) response.InitError!void {
    try validateHead(status, selected_media_type);
    if (!descriptor.framing.permitsTrailers() and descriptor.trailer_names.len != 0) {
        return error.InvalidResponse;
    }
}

fn validateHead(
    status: response.Status,
    selected_media_type: response.MediaType,
) response.InitError!void {
    const code = @intFromEnum(status);
    if (code < 200 or code > 599 or code == 204 or code == 205 or code == 304) {
        return error.InvalidResponse;
    }
    _ = response.parseMediaType(selected_media_type.bytes()) catch {
        return error.InvalidMediaType;
    };
}

const TestLimits = response.HeadLimits.validate(.{
    .head_bytes_max = 256,
    .field_line_bytes_max = 64,
    .fields_max = 4,
});
const TestWorkspace = response.Workspace(TestLimits);
const TestProducer = struct { id: u32 };
const TestResponse = Response(TestLimits, TestProducer);

test "stream head owns cleared workspace and preserves selected limits" {
    const Logical = comptime response.HeadLimits.validate(.{
        .head_bytes_max = 64,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    });
    var workspace = TestWorkspace{};
    workspace.reset(Logical);
    try workspace.headers.append("x-old", "secret");

    var result = try TestResponse.init(
        &workspace,
        .ok,
        response.media.text,
        response_stream.unknown(TestProducer{ .id = 7 }, &.{"digest"}),
    );
    try result.validateOwned(&workspace);
    try std.testing.expectEqual(@as(usize, 0), result.headers.len());
    try std.testing.expectEqualDeep(Logical, result.selectedLimits());
    try std.testing.expectEqual(@as(u32, 7), result.stream.producer.id);

    try result.setHeaderStatic("x-test", "yes");
    try result.appendHeader("set-cookie", "a=1");
    try result.removeHeaderStatic("x-test");
    try std.testing.expectEqual(@as(usize, 1), result.headers.len());
}

test "stream head rejects invalid status media trailers and ownership" {
    var workspace = TestWorkspace{};
    const exact_with_trailer = response_stream.Response(TestProducer){
        .framing = .{ .exact = 2 },
        .trailer_names = &.{"digest"},
        .producer = .{ .id = 1 },
    };
    try std.testing.expectError(
        error.InvalidResponse,
        TestResponse.init(&workspace, .ok, response.media.text, exact_with_trailer),
    );
    inline for (.{ 199, 204, 205, 304, 600 }) |code| {
        try std.testing.expectError(
            error.InvalidResponse,
            TestResponse.init(
                &workspace,
                @enumFromInt(code),
                response.media.text,
                response_stream.exact(1, TestProducer{ .id = 1 }),
            ),
        );
    }
    try std.testing.expectError(
        error.InvalidMediaType,
        TestResponse.init(
            &workspace,
            .ok,
            .{ .value = "text/plain\r\nx: y" },
            response_stream.exact(1, TestProducer{ .id = 1 }),
        ),
    );

    var other_workspace = TestWorkspace{};
    var result = try TestResponse.init(
        &workspace,
        .ok,
        response.media.text,
        response_stream.exact(1, TestProducer{ .id = 1 }),
    );
    result.headers = &other_workspace.headers;
    try std.testing.expectError(error.InvalidResponse, result.validateOwned(&workspace));
}

test "stream head mutations reject transactionally" {
    var workspace = TestWorkspace{};
    var result = try TestResponse.init(
        &workspace,
        .ok,
        response.media.text,
        response_stream.exact(1, TestProducer{ .id = 1 }),
    );
    const before = result;
    try std.testing.expectError(error.InvalidResponse, result.setStatus(.no_content));
    try std.testing.expectEqualDeep(before, result);
    try std.testing.expectError(
        error.InvalidMediaType,
        result.setMediaType(.{ .value = "bad media" }),
    );
    try std.testing.expectEqualDeep(before, result);
}

test {
    std.testing.refAllDecls(@This());
}
