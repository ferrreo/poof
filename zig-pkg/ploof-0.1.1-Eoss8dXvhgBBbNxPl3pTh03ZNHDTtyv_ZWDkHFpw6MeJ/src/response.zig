const std = @import("std");
const limits = @import("internal/http1/limits.zig");
const media_type = @import("internal/http1/media_type.zig");
const response_head = @import("internal/http1/response_head.zig");
const response_static = @import("internal/http1/response_static.zig");
const response_headers = @import("internal/http1/response_headers.zig");
const response_transfer = @import("internal/http1/response_transfer.zig");
const status_module = @import("internal/http1/status.zig");

pub const Status = status_module.Status;
pub const MediaType = media_type.MediaType;
pub const HeadLimits = limits.ResponseHeadLimits;
pub const standard_head_limits = limits.standard_response_head_limits;
pub const HeaderMutationError = response_headers.MutationError;
pub const InitError = error{ InvalidMediaType, InvalidResponse };

var rendered_brand_token: u8 = 0;
const rendered_brand = &rendered_brand_token;
var external_brand_token: u8 = 0;
const external_brand = &external_brand_token;
const RenderedBody = struct {
    length: u32,
    brand: *const u8,
};
const ExternalBody = struct {
    length: u64,
    brand: *const u8,
};

pub const media = struct {
    pub const json = media_type.json;
    pub const html = media_type.html;
    pub const text = media_type.text;
    pub const octet_stream = media_type.octet_stream;
};

pub const Body = union(enum) {
    none,
    static: []const u8,
    borrowed: []const u8,
    rendered: RenderedBody,
    external: ExternalBody,

    pub fn bytes(body: Body) []const u8 {
        return switch (body) {
            .none => "",
            .static, .borrowed => |value| value,
            .rendered, .external => "",
        };
    }

    pub fn length(body: Body) usize {
        return switch (body) {
            .none => 0,
            .static, .borrowed => |value| value.len,
            .rendered => |value| value.length,
            .external => |value| std.math.cast(usize, value.length) orelse
                std.math.maxInt(usize),
        };
    }

    pub fn isRendered(body: Body) bool {
        return switch (body) {
            .rendered => true,
            else => false,
        };
    }

    pub fn isExternal(body: Body) bool {
        return switch (body) {
            .external => true,
            else => false,
        };
    }

    pub fn isNone(body: Body) bool {
        return switch (body) {
            .none => true,
            .static, .borrowed, .rendered, .external => false,
        };
    }
};

pub fn parseMediaType(value: []const u8) media_type.ParseError!MediaType {
    return media_type.parse(value);
}

pub fn staticMediaType(comptime value: []const u8) MediaType {
    return media_type.parse(value) catch {
        @compileError("PLOOF-E3041 invalid static response media type");
    };
}

pub fn Workspace(comptime requested_maximum: HeadLimits) type {
    const maximum = comptime requested_maximum.validate();
    return struct {
        const Self = @This();
        pub const HeaderStorage = response_headers.Headers(maximum);

        headers: HeaderStorage = .{},

        pub fn reset(self: *Self, comptime logical_limits: HeadLimits) void {
            self.headers.reset(logical_limits);
        }

        pub fn clear(self: *Self) void {
            self.headers.clear();
        }

        pub fn selectedLimits(self: *const Self) HeadLimits {
            return self.headers.selectedLimits();
        }
    };
}

pub fn Response(comptime requested_maximum: HeadLimits) type {
    const maximum = comptime requested_maximum.validate();
    const WorkspaceType = Workspace(maximum);
    const HeaderStorage = WorkspaceType.HeaderStorage;

    return struct {
        const Self = @This();

        status: Status,
        media_type: ?MediaType,
        body: Body,
        headers: *HeaderStorage,
        __static_head: ?response_static.Plan = null,

        pub fn init(
            workspace: *WorkspaceType,
            status: Status,
            body: Body,
            selected_media_type: ?MediaType,
        ) InitError!Self {
            try validateParts(status, body, selected_media_type);
            return make(workspace, status, body, selected_media_type);
        }

        pub fn empty(workspace: *WorkspaceType, comptime status: Status) Self {
            comptime assertStaticCombination(status, false, null);
            return make(workspace, status, .none, null);
        }

        pub fn textStatic(
            workspace: *WorkspaceType,
            comptime status: Status,
            comptime value: []const u8,
        ) Self {
            return finiteStatic(workspace, status, value, media.text);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn textBorrowed(
            workspace: *WorkspaceType,
            comptime status: Status,
            value: []const u8,
        ) Self {
            return finiteBorrowed(workspace, status, value, media.text);
        }

        pub fn htmlStatic(
            workspace: *WorkspaceType,
            comptime status: Status,
            comptime value: []const u8,
        ) Self {
            return finiteStatic(workspace, status, value, media.html);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn htmlBorrowed(
            workspace: *WorkspaceType,
            comptime status: Status,
            value: []const u8,
        ) Self {
            return finiteBorrowed(workspace, status, value, media.html);
        }

        pub fn jsonStatic(
            workspace: *WorkspaceType,
            comptime status: Status,
            comptime value: []const u8,
        ) Self {
            return finiteStatic(workspace, status, value, media.json);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn jsonBorrowed(
            workspace: *WorkspaceType,
            comptime status: Status,
            value: []const u8,
        ) Self {
            return finiteBorrowed(workspace, status, value, media.json);
        }

        pub fn bytesStatic(
            workspace: *WorkspaceType,
            comptime status: Status,
            comptime value: []const u8,
        ) Self {
            return finiteStatic(workspace, status, value, media.octet_stream);
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn bytesBorrowed(
            workspace: *WorkspaceType,
            comptime status: Status,
            value: []const u8,
        ) Self {
            return finiteBorrowed(workspace, status, value, media.octet_stream);
        }

        pub fn validate(self: *const Self) InitError!void {
            try validateParts(self.status, self.body, self.media_type);
        }

        pub fn bodyBytes(self: *const Self) []const u8 {
            return self.body.bytes();
        }

        pub fn bodyLength(self: *const Self) usize {
            return self.body.length();
        }

        pub fn __renderedHtml(
            workspace: *WorkspaceType,
            status: Status,
            length: u32,
        ) InitError!Self {
            return init(workspace, status, .{ .rendered = .{
                .length = length,
                .brand = rendered_brand,
            } }, media.html);
        }

        pub fn __external(
            workspace: *WorkspaceType,
            status: Status,
            length: u64,
            selected_media_type: MediaType,
        ) InitError!Self {
            return init(workspace, status, .{ .external = .{
                .length = length,
                .brand = external_brand,
            } }, selected_media_type);
        }

        pub fn selectedLimits(self: *const Self) HeadLimits {
            return self.headers.selectedLimits();
        }

        pub fn setStatus(self: *Self, status: Status) InitError!void {
            try validateParts(status, self.body, self.media_type);
            self.status = status;
        }

        pub fn clearBody(self: *Self) void {
            self.body = .none;
            self.media_type = null;
        }

        pub fn setBodyStatic(
            self: *Self,
            comptime value: []const u8,
            selected_media_type: MediaType,
        ) InitError!void {
            const body = Body{ .static = value };
            try validateParts(self.status, body, selected_media_type);
            self.body = body;
            self.media_type = selected_media_type;
        }

        /// SAFETY: value must stay immutable and live through response serialization.
        pub fn setBodyBorrowed(
            self: *Self,
            value: []const u8,
            selected_media_type: MediaType,
        ) InitError!void {
            const body = Body{ .borrowed = value };
            try validateParts(self.status, body, selected_media_type);
            self.body = body;
            self.media_type = selected_media_type;
        }

        pub fn setMediaType(self: *Self, selected_media_type: MediaType) InitError!void {
            try validateParts(self.status, self.body, selected_media_type);
            self.media_type = selected_media_type;
        }

        pub fn setHeader(
            self: *Self,
            name: []const u8,
            value: []const u8,
        ) HeaderMutationError!void {
            try self.headers.set(name, value);
        }

        pub fn appendHeader(
            self: *Self,
            name: []const u8,
            value: []const u8,
        ) HeaderMutationError!void {
            try self.headers.append(name, value);
        }

        pub fn removeHeader(self: *Self, name: []const u8) HeaderMutationError!void {
            try self.headers.remove(name);
        }

        pub fn setHeaderStatic(
            self: *Self,
            comptime name: []const u8,
            comptime value: []const u8,
        ) HeaderMutationError!void {
            comptime response_headers.validateStaticSet(name, value);
            try self.headers.set(name, value);
        }

        pub fn appendHeaderStatic(
            self: *Self,
            comptime name: []const u8,
            comptime value: []const u8,
        ) HeaderMutationError!void {
            comptime response_headers.validateStaticAppend(name, value);
            try self.headers.append(name, value);
        }

        pub fn removeHeaderStatic(
            self: *Self,
            comptime name: []const u8,
        ) HeaderMutationError!void {
            comptime response_headers.validateStaticRemove(name);
            try self.headers.remove(name);
        }

        fn finiteStatic(
            workspace: *WorkspaceType,
            comptime status: Status,
            comptime value: []const u8,
            comptime selected_media_type: MediaType,
        ) Self {
            comptime assertStaticCombination(status, true, selected_media_type);
            var result = make(
                workspace,
                status,
                .{ .static = value },
                selected_media_type,
            );
            result.__static_head = response_static.Plan.init(status, selected_media_type, value);
            return result;
        }

        fn finiteBorrowed(
            workspace: *WorkspaceType,
            comptime status: Status,
            value: []const u8,
            comptime selected_media_type: MediaType,
        ) Self {
            comptime assertStaticCombination(status, true, selected_media_type);
            return make(
                workspace,
                status,
                .{ .borrowed = value },
                selected_media_type,
            );
        }

        fn make(
            workspace: *WorkspaceType,
            status: Status,
            body: Body,
            selected_media_type: ?MediaType,
        ) Self {
            workspace.clear();
            return .{
                .status = status,
                .media_type = selected_media_type,
                .body = body,
                .headers = &workspace.headers,
            };
        }
    };
}

fn validateParts(status: Status, body: Body, selected_media_type: ?MediaType) InitError!void {
    const code = @intFromEnum(status);
    if (code < 200 or code > 599) return error.InvalidResponse;

    if (selected_media_type) |selected| {
        _ = media_type.parse(selected.bytes()) catch return error.InvalidMediaType;
        if (body.isNone()) return error.InvalidResponse;
    } else if (!body.isNone()) {
        return error.InvalidResponse;
    }

    if ((code == 204 or code == 205 or code == 304) and !body.isNone()) {
        return error.InvalidResponse;
    }
    switch (body) {
        .rendered => |value| if (value.brand != rendered_brand) return error.InvalidResponse,
        .external => |value| if (value.brand != external_brand or
            value.length > std.math.maxInt(i64)) return error.InvalidResponse,
        else => {},
    }
}

fn assertStaticCombination(
    comptime status: Status,
    comptime has_body: bool,
    comptime selected_media_type: ?MediaType,
) void {
    const body = if (has_body) Body{ .static = "x" } else Body.none;
    validateParts(status, body, selected_media_type) catch |problem| {
        @compileError(staticCombinationMessage(problem));
    };
}

fn staticCombinationMessage(problem: InitError) []const u8 {
    return switch (problem) {
        error.InvalidMediaType => "PLOOF-E3041 invalid static response media type",
        error.InvalidResponse => "PLOOF-E3040 invalid static response status/body combination",
    };
}

const TestMaximum = HeadLimits.validate(.{
    .head_bytes_max = 512,
    .field_line_bytes_max = 128,
    .fields_max = 16,
});
const TestWorkspace = Workspace(TestMaximum);
const TestResponse = Response(TestMaximum);

test "finite constructors preserve static and explicitly borrowed body storage" {
    var workspace = TestWorkspace{};
    const empty_response = TestResponse.empty(&workspace, .no_content);
    try std.testing.expect(empty_response.body.isNone());
    try std.testing.expectEqual(@as(?MediaType, null), empty_response.media_type);

    const literal = "static body";
    var static_response = TestResponse.textStatic(&workspace, .ok, literal);
    try expectBody(.static, &static_response, literal);

    var borrowed = [_]u8{ 'b', 'o', 'r', 'r', 'o', 'w', 'e', 'd' };
    var borrowed_response = TestResponse.bytesBorrowed(&workspace, .created, &borrowed);
    try expectBody(.borrowed, &borrowed_response, &borrowed);
    try std.testing.expectEqual(
        @intFromPtr(&workspace.headers),
        @intFromPtr(borrowed_response.headers),
    );
    try std.testing.expect(@sizeOf(TestResponse) < @sizeOf(TestWorkspace));
}

test "typed helpers select exact media types" {
    var workspace = TestWorkspace{};
    const static_cases = .{
        .{ TestResponse.textStatic(&workspace, .ok, "text"), media.text },
        .{ TestResponse.htmlStatic(&workspace, .ok, "<p>x</p>"), media.html },
        .{ TestResponse.jsonStatic(&workspace, .ok, "{}"), media.json },
        .{ TestResponse.bytesStatic(&workspace, .ok, "bytes"), media.octet_stream },
    };
    inline for (static_cases) |case| {
        try expectMedia(.static, case[0], case[1]);
    }
    const borrowed_cases = .{
        .{ TestResponse.textBorrowed(&workspace, .ok, "text"), media.text },
        .{ TestResponse.htmlBorrowed(&workspace, .ok, "<p>x</p>"), media.html },
        .{ TestResponse.jsonBorrowed(&workspace, .ok, "{}"), media.json },
        .{ TestResponse.bytesBorrowed(&workspace, .ok, "bytes"), media.octet_stream },
    };
    inline for (borrowed_cases) |case| {
        try expectMedia(.borrowed, case[0], case[1]);
    }
}

fn expectMedia(
    expected_tag: std.meta.Tag(Body),
    response: TestResponse,
    expected_media_type: MediaType,
) !void {
    try std.testing.expectEqual(expected_tag, std.meta.activeTag(response.body));
    try std.testing.expectEqualStrings(
        expected_media_type.bytes(),
        response.media_type.?.bytes(),
    );
}

test "bodyless and dynamic mutations reject transactionally" {
    var workspace = TestWorkspace{};
    try std.testing.expectError(
        error.InvalidResponse,
        TestResponse.init(&workspace, .no_content, .{ .borrowed = "x" }, media.text),
    );

    var response = TestResponse.textBorrowed(&workspace, .ok, "body");
    const before = response;
    try std.testing.expectError(error.InvalidResponse, response.setStatus(.no_content));
    try std.testing.expectEqualDeep(before, response);

    response.clearBody();
    try response.setStatus(.no_content);
    const empty_before = response;
    try std.testing.expectError(
        error.InvalidResponse,
        response.setBodyBorrowed("x", media.text),
    );
    try std.testing.expectEqualDeep(empty_before, response);
    try std.testing.expectError(error.InvalidResponse, response.setMediaType(media.text));
    try std.testing.expectEqualDeep(empty_before, response);
}

test "status body and media mutations preserve a valid finite response" {
    var workspace = TestWorkspace{};
    var response = try TestResponse.init(
        &workspace,
        try Status.fromInt(299),
        .{ .borrowed = "first" },
        media.text,
    );
    try response.setStatus(.created);
    try response.setBodyStatic("second", media.html);
    try std.testing.expectEqual(.static, std.meta.activeTag(response.body));
    try response.setBodyBorrowed("third", media.json);
    try std.testing.expectEqual(.borrowed, std.meta.activeTag(response.body));

    const problem_json = try parseMediaType("application/problem+json");
    try response.setMediaType(problem_json);
    try response.validate();
    try std.testing.expectEqualStrings(
        problem_json.bytes(),
        response.media_type.?.bytes(),
    );
    try std.testing.expectError(
        error.InvalidResponse,
        TestResponse.init(&workspace, @enumFromInt(100), .none, null),
    );
}

test "dynamic media validation and header operations are bounded" {
    var workspace = TestWorkspace{};
    var response = TestResponse.textStatic(&workspace, .ok, "body");
    const before = response;
    try std.testing.expectError(
        error.InvalidMediaType,
        response.setMediaType(.{ .value = "text/plain\r\nx: y" }),
    );
    try std.testing.expectEqualDeep(before, response);

    try response.setHeaderStatic("X-One", "1");
    try response.appendHeader("Set-Cookie", "a=1");
    try response.appendHeaderStatic("Set-Cookie", "b=2");
    try std.testing.expectEqual(@as(usize, 3), response.headers.len());
    try response.removeHeaderStatic("x-one");
    try std.testing.expectEqual(@as(usize, 2), response.headers.len());
}

test "logical route limits govern shared maximum header storage" {
    const CountLimit = comptime HeadLimits.validate(.{
        .head_bytes_max = 64,
        .field_line_bytes_max = 16,
        .fields_max = 1,
    });
    var workspace = TestWorkspace{};
    workspace.reset(CountLimit);
    var response = TestResponse.empty(&workspace, .ok);
    try response.appendHeader("x", "a");
    const before = workspace.headers;
    try std.testing.expectError(
        error.ResponseHeadTooLarge,
        response.appendHeader("y", "b"),
    );
    try std.testing.expectEqualDeep(before, workspace.headers);
    try std.testing.expectEqualDeep(CountLimit, response.selectedLimits());

    workspace.reset(TestMaximum);
    try std.testing.expectEqual(@as(usize, 0), workspace.headers.len());
    try workspace.headers.append("x", "a");
    try workspace.headers.append("y", "b");
}

test "constructing a replacement response clears prior headers but keeps limits" {
    const Logical = comptime HeadLimits.validate(.{
        .head_bytes_max = 64,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    });
    var workspace = TestWorkspace{};
    workspace.reset(Logical);
    var original = TestResponse.textStatic(&workspace, .ok, "secret");
    try original.setHeaderStatic("set-cookie", "secret=value");

    const replacement = TestResponse.empty(&workspace, .internal_server_error);
    try std.testing.expectEqual(@as(usize, 0), replacement.headers.len());
    try std.testing.expectEqualDeep(Logical, replacement.selectedLimits());
}

test "public finite response feeds the HTTP serializer without adaptation copies" {
    var workspace = TestWorkspace{};
    var response = TestResponse.textBorrowed(&workspace, .ok, "pong");
    try response.setHeader("X-Test", "yes");
    var output: [512]u8 = undefined;
    const result = try response_head.write(
        TestMaximum,
        response_transfer.standard_trailer_limits,
        &output,
        .{
            .framing = .{
                .status = response.status,
                .request_is_head = false,
                .request_accepts_trailers = false,
                .body = .{ .fixed = response.bodyBytes().len },
                .trailers_declared = false,
            },
            .default_content_type = response.media_type.?,
            .date = "Tue, 14 Jul 2026 12:00:00 GMT",
        },
        response.headers,
    );
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n" ++
            "x-test: yes\r\n" ++
            "content-type: text/plain; charset=utf-8\r\n" ++
            "content-length: 4\r\n" ++
            "date: Tue, 14 Jul 2026 12:00:00 GMT\r\n\r\n",
        result.bytes,
    );
    try std.testing.expectEqual(@intFromPtr("pong".ptr), @intFromPtr(response.bodyBytes().ptr));
}

fn expectBody(
    expected_tag: std.meta.Tag(Body),
    response: *const TestResponse,
    expected_bytes: []const u8,
) !void {
    try std.testing.expectEqual(expected_tag, std.meta.activeTag(response.body));
    try std.testing.expectEqualStrings(expected_bytes, response.bodyBytes());
    try std.testing.expectEqual(
        @intFromPtr(expected_bytes.ptr),
        @intFromPtr(response.bodyBytes().ptr),
    );
}

test {
    std.testing.refAllDecls(@This());
}
