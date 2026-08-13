pub const std = @import("std");
pub const application_context = @import("../../src/application/context.zig");
pub const csrf = @import("../../src/csrf.zig");
pub const csrf_origin = @import("../../src/internal/csrf/origin.zig");
pub const csrf_request = @import("../../src/internal/csrf/request.zig");
pub const forwarding = @import("../../src/forwarding.zig");
pub const limits = @import("../../src/internal/http1/limits.zig");
pub const request_head = @import("../../src/internal/http1/request_head.zig");
pub const response = @import("../../src/response.zig");

pub const Origins = csrf.OriginSet(8, 255);
pub const Decoder = request_head.Decoder(limits.standard_request_head_limits);
pub const Response = response.Response(response.standard_head_limits);
pub const ResponseWorkspace = response.Workspace(response.standard_head_limits);

pub const AppState = struct {
    origins: Origins,
    source_origins: Origins = .{},
    session_token: ?csrf.SessionToken = null,
    binding: ?csrf.LoginBinding = null,
    keys: csrf.Keyring = .{},
    stored: ?csrf.SessionToken = null,
};

pub const MockRequest = struct {
    method: []const u8,
    headers: application_context.RequestHeaders,
    scheme: ?forwarding.Scheme,
    authority: ?forwarding.Authority,

    pub fn effectiveScheme(request: MockRequest) ?forwarding.Scheme {
        return request.scheme;
    }

    pub fn effectiveAuthority(request: MockRequest) ?forwarding.Authority {
        return request.authority;
    }
};

pub const MockContext = struct {
    pub const ApplicationState = AppState;
    pub const ResponseType = Response;

    state: *AppState,
    request: MockRequest,
    response_workspace: *ResponseWorkspace,
    csrf_request: ?*csrf.RequestState = null,

    pub fn empty(context: *MockContext, status: response.Status) Response {
        return Response.init(context.response_workspace, status, .none, null) catch unreachable;
    }
};

pub fn originsProvider(state: *const AppState) *const Origins {
    return &state.origins;
}

pub fn sourceOriginsProvider(state: *const AppState) *const Origins {
    return &state.source_origins;
}

pub fn loadSession(context: *MockContext) ?csrf.SessionToken {
    return context.state.session_token;
}

pub fn storeSession(context: *MockContext, token: csrf.SessionToken) void {
    context.state.stored = token;
}

pub fn clearSession(context: *MockContext) void {
    context.state.stored = null;
}

pub fn keysProvider(state: *const AppState) *const csrf.Keyring {
    return &state.keys;
}

pub fn bindingProvider(context: *MockContext) ?csrf.LoginBinding {
    return context.state.binding;
}

pub const synchronizer_policy = csrf.synchronizer(MockContext, .{
    .origins = originsProvider,
    .load = loadSession,
    .store = storeSession,
    .clear = clearSession,
});

pub const escaped_name_policy = csrf.synchronizer(MockContext, .{
    .origins = originsProvider,
    .load = loadSession,
    .store = storeSession,
    .clear = clearSession,
    .form_name = "csrf&amp",
});

pub const signed_policy = csrf.signedDoubleSubmit(MockContext, .{
    .origins = originsProvider,
    .keys = keysProvider,
    .binding = bindingProvider,
});

pub const split_synchronizer_policy = csrf.synchronizer(MockContext, .{
    .origins = originsProvider,
    .source_origins = sourceOriginsProvider,
    .load = loadSession,
    .store = storeSession,
    .clear = clearSession,
});

pub const split_signed_policy = csrf.signedDoubleSubmit(MockContext, .{
    .origins = originsProvider,
    .source_origins = sourceOriginsProvider,
    .keys = keysProvider,
    .binding = bindingProvider,
});

pub fn panicOrigins(_: *const AppState) *const Origins {
    @panic("inactive CSRF policy accessed origins callback");
}

pub fn panicLoad(_: *MockContext) ?csrf.SessionToken {
    @panic("inactive CSRF policy accessed load callback");
}

pub fn panicStore(_: *MockContext, _: csrf.SessionToken) void {
    @panic("inactive CSRF policy accessed store callback");
}

pub fn panicClear(_: *MockContext) void {
    @panic("inactive CSRF policy accessed clear callback");
}

pub fn panicKeys(_: *const AppState) *const csrf.Keyring {
    @panic("inactive CSRF policy accessed keys callback");
}

pub fn panicBinding(_: *MockContext) ?csrf.LoginBinding {
    @panic("inactive CSRF policy accessed binding callback");
}

pub const inactive_synchronizer = csrf.synchronizer(MockContext, .{
    .origins = panicOrigins,
    .load = panicLoad,
    .store = panicStore,
    .clear = panicClear,
});

pub const inactive_signed = csrf.signedDoubleSubmit(MockContext, .{
    .origins = panicOrigins,
    .keys = panicKeys,
    .binding = panicBinding,
});

pub fn appState() !AppState {
    return .{ .origins = try Origins.init(&.{"https://app.example"}) };
}

pub fn initializedResponseWorkspace() ResponseWorkspace {
    var workspace = ResponseWorkspace{};
    workspace.reset(response.standard_head_limits);
    return workspace;
}

pub fn decodeHead(wire: []const u8) !Decoder {
    var decoder = Decoder.init();
    switch (decoder.feed(wire).state) {
        .ready => return decoder,
        else => return error.TestUnexpectedResult,
    }
}

pub fn mockContext(
    app: *AppState,
    workspace: *ResponseWorkspace,
    decoder: *const Decoder,
    method: []const u8,
) !MockContext {
    return .{
        .state = app,
        .request = .{
            .method = method,
            .headers = .{ .bytes = decoder.bytes(), .fields = decoder.fields() },
            .scheme = .https,
            .authority = try @import("../../src/internal/http1/authority.zig").parse(
                "app.example",
                .https,
            ),
        },
        .response_workspace = workspace,
    };
}

pub fn expectOriginFailure(expected: csrf.OriginSetIssue, values: []const []const u8) !void {
    return switch (Origins.initDetailed(values)) {
        .failure => |failure| try std.testing.expectEqual(expected, failure.issue),
        .set => error.TestUnexpectedResult,
    };
}

pub fn forgeOriginEntry(set: *Origins, index: u16, value: []const u8) void {
    @memset(&set.entries[index].bytes, 0);
    @memcpy(set.entries[index].bytes[0..value.len], value);
    set.entries[index].length = @intCast(value.len);
}

pub fn expectForgedOriginSet(expected: csrf.OriginSetIssue, set: Origins) !void {
    try std.testing.expectEqual(expected, set.issue().?);
    try std.testing.expect(set.at(0) == null);
    try std.testing.expect(!set.containsRaw("https://app.example"));
    const authority = try @import("../../src/internal/http1/authority.zig").parse(
        "app.example",
        .https,
    );
    try std.testing.expect(!set.containsEffective(.https, authority));
    try std.testing.expectEqual(csrf_origin.GateDecision.misdirected, csrf_origin.gate(
        &set,
        &set,
        .https,
        authority,
        false,
        .{},
    ));

    const app = AppState{ .origins = set };
    try expectStartupOriginIssue(expected, synchronizer_policy.startupIssue(&app).?);
    try expectStartupOriginIssue(expected, signed_policy.startupIssue(&app).?);
}

pub fn expectStartupOriginIssue(expected: csrf.OriginSetIssue, issue: csrf.StartupIssue) !void {
    return switch (issue) {
        .origins => |actual| std.testing.expectEqual(expected, actual),
        .source_origins => error.TestUnexpectedResult,
        .keyring => error.TestUnexpectedResult,
    };
}

pub fn expectStartupSourceOriginIssue(
    expected: csrf.OriginSetIssue,
    issue: csrf.StartupIssue,
) !void {
    return switch (issue) {
        .source_origins => |actual| std.testing.expectEqual(expected, actual),
        .origins, .keyring => error.TestUnexpectedResult,
    };
}

pub fn expectHeader(value: *const Response, name: []const u8, expected: []const u8) !void {
    for (0..value.headers.len()) |index| {
        const field = value.headers.at(index);
        if (std.ascii.eqlIgnoreCase(field.name, name)) {
            try std.testing.expectEqualStrings(expected, field.value);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test {
    _ = @import("csrf_test_part_1.zig");
    _ = @import("csrf_test_part_2.zig");
}
