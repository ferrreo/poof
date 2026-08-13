const source = @import("csrf_test.zig");
const std = source.std;
const application_context = source.application_context;
const csrf = source.csrf;
const csrf_origin = source.csrf_origin;
const csrf_request = source.csrf_request;
const forwarding = source.forwarding;
const limits = source.limits;
const request_head = source.request_head;
const response = source.response;
const Origins = source.Origins;
const Decoder = source.Decoder;
const Response = source.Response;
const ResponseWorkspace = source.ResponseWorkspace;
const AppState = source.AppState;
const MockRequest = source.MockRequest;
const MockContext = source.MockContext;
const originsProvider = source.originsProvider;
const sourceOriginsProvider = source.sourceOriginsProvider;
const loadSession = source.loadSession;
const storeSession = source.storeSession;
const clearSession = source.clearSession;
const keysProvider = source.keysProvider;
const bindingProvider = source.bindingProvider;
const synchronizer_policy = source.synchronizer_policy;
const escaped_name_policy = source.escaped_name_policy;
const signed_policy = source.signed_policy;
const split_synchronizer_policy = source.split_synchronizer_policy;
const split_signed_policy = source.split_signed_policy;
const panicOrigins = source.panicOrigins;
const panicLoad = source.panicLoad;
const panicStore = source.panicStore;
const panicClear = source.panicClear;
const panicKeys = source.panicKeys;
const panicBinding = source.panicBinding;
const inactive_synchronizer = source.inactive_synchronizer;
const inactive_signed = source.inactive_signed;
const appState = source.appState;
const initializedResponseWorkspace = source.initializedResponseWorkspace;
const decodeHead = source.decodeHead;
const mockContext = source.mockContext;
const expectOriginFailure = source.expectOriginFailure;
const forgeOriginEntry = source.forgeOriginEntry;
const expectForgedOriginSet = source.expectForgedOriginSet;
const expectStartupOriginIssue = source.expectStartupOriginIssue;
const expectStartupSourceOriginIssue = source.expectStartupSourceOriginIssue;
const expectHeader = source.expectHeader;

test "signed policy verifies cookie header and issues bound secure token" {
    var app = try appState();
    app.binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x53} ** 32);
    app.keys = try csrf.Keyring.init(
        try csrf.Key.init(9, [_]u8{0x91} ** 32),
        null,
    );
    var encoded = try app.keys.sign(app.binding.?, [_]u8{0x72} ** 32);
    defer encoded.clear();
    var wire_storage: [768]u8 = undefined;
    const wire = try std.fmt.bufPrint(
        &wire_storage,
        "POST / HTTP/1.1\r\n" ++
            "Host: app.example\r\n" ++
            "Cookie: __Host-ploof-csrf={s}\r\n" ++
            "X-CSRF-Token: {s}\r\n\r\n",
        .{ encoded.slice(), encoded.slice() },
    );
    var decoder = try decodeHead(wire);
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "POST");
    var state = signed_policy.init();
    try std.testing.expect(signed_policy.head(&context, &state) == null);

    var issued = try signed_policy.issue(&context, [_]u8{0x73} ** 32);
    defer issued.clear();
    try std.testing.expect(app.keys.verify(app.binding.?, issued.slice()));
    var hidden_storage: [192]u8 = undefined;
    const hidden = try signed_policy.hiddenInput(&context, &issued, &hidden_storage);
    var expected_storage: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_storage,
        "<input type=\"hidden\" name=\"_csrf\" value=\"{s}\">",
        .{issued.slice()},
    );
    try std.testing.expectEqualStrings(expected, hidden);

    var forged = csrf.EncodedSignedToken{
        .bytes = [_]u8{'A'} ** csrf.signed_encoded_bytes,
    };
    forged.bytes[0] = '"';
    var untouched = [_]u8{0xa5} ** 192;
    try std.testing.expectError(
        error.InvalidToken,
        signed_policy.hiddenInput(&context, &forged, &untouched),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 192), &untouched);
    const other = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x54} ** 32);
    var wrong_binding = try app.keys.sign(other, [_]u8{0x74} ** 32);
    defer wrong_binding.clear();
    try std.testing.expectError(
        error.InvalidToken,
        signed_policy.hiddenInput(&context, &wrong_binding, &hidden_storage),
    );
    var value = context.empty(.ok);
    signed_policy.response(&context, &state, &value);
    try expectHeader(&value, "cache-control", "no-store, no-transform");
    var cookie_output: [192]u8 = undefined;
    const cookie = try signed_policy.cookieHeader(&issued, .{}, &cookie_output);
    try std.testing.expect(std.mem.startsWith(u8, cookie, "__Host-ploof-csrf="));
}

test "inactive CSRF token helpers fail before callback access" {
    var app = try appState();
    var decoder = try decodeHead("GET / HTTP/1.1\r\nHost: app.example\r\n\r\n");
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "GET");
    var output: [256]u8 = undefined;

    try std.testing.expectError(error.PolicyNotActive, inactive_synchronizer.token(&context));
    try std.testing.expectError(
        error.PolicyNotActive,
        inactive_synchronizer.hiddenInput(&context, &output),
    );
    try std.testing.expectError(
        error.PolicyNotActive,
        inactive_signed.issue(&context, [_]u8{0x33} ** 32),
    );
    try std.testing.expectError(error.PolicyNotActive, inactive_signed.currentToken(&context));
    const token = csrf.EncodedSignedToken{ .bytes = [_]u8{'A'} ** csrf.signed_encoded_bytes };
    try std.testing.expectError(
        error.PolicyNotActive,
        inactive_signed.hiddenInput(&context, &token, &output),
    );
}
