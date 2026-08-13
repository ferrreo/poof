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

test "origin set owns normalized exact origins after moves" {
    const values = [_][]const u8{
        "HTTPS://App.Example:443",
        "http://[2001:db8::1]:8080",
    };
    const original = try Origins.init(&values);
    var moved = original;
    try std.testing.expectEqual(@as(u16, 2), moved.count());
    try std.testing.expectEqualStrings("https://app.example:443", moved.at(0).?);
    try std.testing.expectEqualStrings("http://[2001:db8::1]:8080", moved.at(1).?);
    try std.testing.expect(moved.containsRaw("https://app.example"));
    try std.testing.expect(moved.containsRaw("HTTP://[2001:0db8::1]:8080"));
    try std.testing.expect(!moved.containsRaw("https://other.example"));

    const authority = try @import("../../src/internal/http1/authority.zig").parse(
        "app.example",
        .https,
    );
    try std.testing.expect(moved.containsEffective(.https, authority));
    try std.testing.expect(!moved.containsEffective(.http, authority));
}

test "origin set canonicalizes percent-encoded numeric hosts consistently" {
    const encoded = try Origins.init(&.{"http://%31%39%32%2e0%2e2%2e1"});
    try std.testing.expectEqualStrings("http://192.0.2.1:80", encoded.at(0).?);
    try std.testing.expect(encoded.containsRaw("http://192.0.2.1"));
    try expectOriginFailure(.duplicate_origin, &.{
        "http://%31%39%32%2e0%2e2%2e1",
        "http://192.0.2.1",
    });
}

test "origin set reports empty opaque duplicate and unsupported origins" {
    try expectOriginFailure(.empty, &.{});
    try expectOriginFailure(.opaque_origin, &.{"null"});
    try expectOriginFailure(.unsupported_scheme, &.{"ftp://example.test"});
    try expectOriginFailure(.duplicate_origin, &.{
        "https://example.test",
        "HTTPS://EXAMPLE.TEST:443",
    });
    const zero = Origins{};
    try std.testing.expectEqual(csrf.OriginSetIssue.uninitialized, zero.issue().?);
}

test "forged origin sets fail closed in both policy modes" {
    var empty = Origins{};
    empty.initialized = true;
    try expectForgedOriginSet(.empty, empty);

    var count = try Origins.init(&.{"https://app.example"});
    count.count_value = Origins.origins_max + 1;
    try expectForgedOriginSet(.too_many, count);

    var length = try Origins.init(&.{"https://app.example"});
    length.entries[0].length = @intCast(length.entries[0].bytes.len + 1);
    try expectForgedOriginSet(.host_too_long, length);

    var seal = try Origins.init(&.{"https://app.example"});
    seal.entries[0].seal ^= 1;
    try expectForgedOriginSet(.invalid_origin, seal);

    var nonmatching_seal = try Origins.init(&.{
        "https://app.example",
        "https://other.example",
    });
    nonmatching_seal.entries[1].seal ^= 1;
    try expectForgedOriginSet(.invalid_origin, nonmatching_seal);

    var nonmatching_length = try Origins.init(&.{
        "https://app.example",
        "https://other.example",
    });
    nonmatching_length.entries[1].length = 0;
    try expectForgedOriginSet(.invalid_origin, nonmatching_length);

    var nonmatching_byte = try Origins.init(&.{
        "https://app.example",
        "https://other.example",
    });
    nonmatching_byte.entries[1].bytes[8] ^= 1;
    try expectForgedOriginSet(.invalid_origin, nonmatching_byte);

    const invalid = Origins{ .initialized = true, .count_value = 1 };
    try expectForgedOriginSet(.invalid_origin, invalid);

    var opaque_set = Origins{ .initialized = true, .count_value = 1 };
    forgeOriginEntry(&opaque_set, 0, "null");
    try expectForgedOriginSet(.opaque_origin, opaque_set);

    var unsupported = Origins{ .initialized = true, .count_value = 1 };
    forgeOriginEntry(&unsupported, 0, "ftp://app.example");
    try expectForgedOriginSet(.unsupported_scheme, unsupported);

    var duplicate = try Origins.init(&.{
        "https://app.example",
        "https://other.example",
    });
    duplicate.entries[1] = duplicate.entries[0];
    try expectForgedOriginSet(.invalid_origin, duplicate);

    var nonmatching_duplicate = try Origins.init(&.{
        "https://app.example",
        "https://other.example",
        "https://third.example",
    });
    nonmatching_duplicate.entries[2] = nonmatching_duplicate.entries[1];
    try expectForgedOriginSet(.invalid_origin, nonmatching_duplicate);
}

test "origin gate rejects cross-site and accepts unknown Fetch Metadata fallback" {
    const origins = try Origins.init(&.{"https://app.example"});
    const authority = try @import("../../src/internal/http1/authority.zig").parse(
        "app.example",
        .https,
    );
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{ .fetch_site = .{ .value = "cross-site" } },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.allow, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{ .fetch_site = .{ .value = "future-value" } },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{ .fetch_site = .multiple },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.misdirected, csrf_origin.gate(
        &origins,
        &origins,
        .http,
        authority,
        false,
        .{},
    ));
}

test "separate source origins authorize cross-site without widening effective hosts" {
    const public_origins = try Origins.init(&.{"https://api.example"});
    const source_origins = try Origins.init(&.{"https://app.example"});
    const api = try @import("../../src/internal/http1/authority.zig").parse("api.example", .https);
    const app = try @import("../../src/internal/http1/authority.zig").parse("app.example", .https);
    const explicit = csrf_origin.Headers{
        .fetch_site = .{ .value = "cross-site" },
        .origin = .{ .value = "https://app.example" },
    };

    try std.testing.expectEqual(csrf_origin.GateDecision.allow, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        api,
        true,
        explicit,
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.allow, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        api,
        true,
        .{
            .fetch_site = .{ .value = "cross-site" },
            .referer = .{ .value = "https://app.example/page" },
        },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        api,
        true,
        .{
            .fetch_site = .multiple,
            .origin = .{ .value = "https://app.example" },
        },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        api,
        true,
        .{ .fetch_site = .{ .value = "cross-site" } },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        api,
        true,
        .{ .origin = .{ .value = "https://other.example" } },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.misdirected, csrf_origin.gate(
        &public_origins,
        &source_origins,
        .https,
        app,
        true,
        explicit,
    ));
}

test "explicit malformed source origins have distinct startup provenance" {
    var source_origins = try Origins.init(&.{"https://app.example"});
    source_origins.entries[0].length = 0;
    const state = AppState{
        .origins = try Origins.init(&.{"https://api.example"}),
        .source_origins = source_origins,
    };
    try expectStartupSourceOriginIssue(
        .invalid_origin,
        split_synchronizer_policy.startupIssue(&state).?,
    );
    try expectStartupSourceOriginIssue(
        .invalid_origin,
        split_signed_policy.startupIssue(&state).?,
    );
}

test "Origin precedes strict Referer and opaque values fail" {
    const origins = try Origins.init(&.{"https://app.example"});
    const authority = try @import("../../src/internal/http1/authority.zig").parse(
        "app.example",
        .https,
    );
    try std.testing.expectEqual(csrf_origin.GateDecision.allow, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{ .referer = .{ .value = "https://app.example/path?q=1" } },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{
            .origin = .{ .value = "https://other.example" },
            .referer = .{ .value = "https://app.example/path" },
        },
    ));
    try std.testing.expectEqual(csrf_origin.GateDecision.forbidden, csrf_origin.gate(
        &origins,
        &origins,
        .https,
        authority,
        true,
        .{ .origin = .{ .value = "null" } },
    ));
    try std.testing.expect(csrf_origin.parseRefererOrigin(
        "https://app.example/path#fragment",
    ) == null);
    try std.testing.expect(csrf_origin.parseRefererOrigin(
        "https://app.example/path with-space",
    ) == null);
    try std.testing.expect(csrf_origin.parseRefererOrigin(
        "https://app.example/path%GG",
    ) == null);
}

test "synchronizer tokens use exact canonical base64url" {
    var bytes = [_]u8{0x5a} ** csrf.synchronizer_bytes;
    const token = try csrf.SessionToken.fromRandomBytes(bytes);
    var encoded = try csrf.EncodedSynchronizerToken.init(token);
    defer encoded.clear();
    try std.testing.expectEqual(@as(usize, 43), encoded.slice().len);
    try std.testing.expect(csrf_request.verifySynchronizer(&token.bytes, encoded.slice()));
    try std.testing.expect(!csrf_request.verifySynchronizer(&token.bytes, encoded.slice()[0..42]));

    var padded: [44]u8 = undefined;
    @memcpy(padded[0..43], encoded.slice());
    padded[43] = '=';
    try std.testing.expect(!csrf_request.verifySynchronizer(&token.bytes, &padded));
    bytes[31] ^= 1;
    try std.testing.expect(!csrf_request.verifySynchronizer(&bytes, encoded.slice()));
    try std.testing.expectError(
        error.InvalidRandomValue,
        csrf.SessionToken.fromRandomBytes([_]u8{0} ** csrf.synchronizer_bytes),
    );
}

test "hidden input escapes token-alphabet ampersands without changing field identity" {
    var app = try appState();
    app.session_token = try csrf.SessionToken.fromRandomBytes([_]u8{0x5b} ** 32);
    var encoded = try csrf.EncodedSynchronizerToken.init(app.session_token.?);
    defer encoded.clear();
    var decoder = try decodeHead("GET / HTTP/1.1\r\nHost: app.example\r\n\r\n");
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "GET");
    var state = escaped_name_policy.init();
    try std.testing.expect(escaped_name_policy.head(&context, &state) == null);
    var output: [192]u8 = undefined;
    const actual = try escaped_name_policy.hiddenInput(&context, &output);
    var expected_storage: [192]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_storage,
        "<input type=\"hidden\" name=\"csrf&amp;amp\" value=\"{s}\">",
        .{encoded.slice()},
    );
    try std.testing.expectEqualStrings(expected, actual);

    var hostile_output: [192]u8 = undefined;
    const hostile = try csrf_request.writeHiddenInput(
        "csrf&amp",
        "\"<>&",
        &hostile_output,
    );
    try std.testing.expectEqualStrings(
        "<input type=\"hidden\" name=\"csrf&amp;amp\" " ++
            "value=\"&quot;&lt;&gt;&amp;\">",
        hostile,
    );
}

test "signed token KAT binding and key rotation" {
    const key_one = try csrf.Key.init(7, [_]u8{0x11} ** 32);
    const key_two = try csrf.Key.init(8, [_]u8{0x44} ** 32);
    const binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x22} ** 32);
    const other_binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x23} ** 32);
    const nonce = [_]u8{0x33} ** 32;
    const old_keys = try csrf.Keyring.init(key_one, null);
    var encoded = try old_keys.sign(binding, nonce);
    defer encoded.clear();
    try std.testing.expectEqualStrings(
        "AQczMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM8HJABqmBpO0-p6yrtkC00iECHKW8UHyFBTrN9SucJLv",
        encoded.slice(),
    );
    try std.testing.expect(old_keys.verify(binding, encoded.slice()));
    try std.testing.expect(!old_keys.verify(other_binding, encoded.slice()));

    const rotated = try csrf.Keyring.init(key_two, key_one);
    try std.testing.expect(rotated.verify(binding, encoded.slice()));
    const retired = try csrf.Keyring.init(key_two, null);
    try std.testing.expect(!retired.verify(binding, encoded.slice()));
    try std.testing.expectError(
        error.InvalidNonce,
        old_keys.sign(binding, [_]u8{0} ** 32),
    );

    var raw: [csrf_request.signed_bytes]u8 = undefined;
    try std.testing.expect(csrf_request.decodeSigned(encoded.slice(), &raw));
    raw[0] += 1;
    const unsupported_version = csrf_request.encodeSigned(&raw);
    try std.testing.expect(!old_keys.verify(binding, &unsupported_version));
}

test "signed token rejects tampering version and duplicate key IDs" {
    const key = try csrf.Key.init(1, [_]u8{0xa5} ** 32);
    const binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x7c} ** 32);
    const keys = try csrf.Keyring.init(key, null);
    var encoded = try keys.sign(binding, [_]u8{0x3d} ** 32);
    defer encoded.clear();

    var tampered = encoded;
    tampered.bytes[20] = if (tampered.bytes[20] == 'A') 'B' else 'A';
    try std.testing.expect(!keys.verify(binding, tampered.slice()));
    const same_id = try csrf.Key.init(1, [_]u8{0x5a} ** 32);
    try std.testing.expectError(error.InvalidKeyring, csrf.Keyring.init(key, same_id));
}

test "direct zero session tokens fail at every public policy boundary" {
    const zero = csrf.SessionToken{ .bytes = [_]u8{0} ** csrf.synchronizer_bytes };
    try std.testing.expect(!zero.valid());
    try std.testing.expectError(
        error.InvalidSessionToken,
        csrf.EncodedSynchronizerToken.init(zero),
    );

    var app = try appState();
    app.session_token = zero;
    var decoder = try decodeHead(
        "POST / HTTP/1.1\r\nHost: app.example\r\n" ++
            "Origin: https://app.example\r\n\r\n",
    );
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "POST");
    var state = synchronizer_policy.init();
    try std.testing.expectEqual(
        response.Status.forbidden,
        synchronizer_policy.head(&context, &state).?.status,
    );

    decoder = try decodeHead("GET / HTTP/1.1\r\nHost: app.example\r\n\r\n");
    context = try mockContext(&app, &workspace, &decoder, "GET");
    state = synchronizer_policy.init();
    try std.testing.expect(synchronizer_policy.head(&context, &state) == null);
    try std.testing.expectError(error.InvalidSessionToken, synchronizer_policy.token(&context));
    try std.testing.expectError(
        error.InvalidSessionToken,
        synchronizer_policy.rotate(&context, zero),
    );
    try std.testing.expect(app.stored == null);
}

test "direct zero login bindings fail at every public policy boundary" {
    const zero = csrf.LoginBinding{ .bytes = [_]u8{0} ** 32 };
    const valid = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x26} ** 32);
    const keys = try csrf.Keyring.init(
        try csrf.Key.init(4, [_]u8{0x41} ** 32),
        null,
    );
    try std.testing.expect(!zero.valid());
    try std.testing.expectError(
        error.InvalidBinding,
        keys.sign(zero, [_]u8{0x27} ** 32),
    );
    var encoded = try keys.sign(valid, [_]u8{0x28} ** 32);
    defer encoded.clear();
    try std.testing.expect(!keys.verify(zero, encoded.slice()));

    var app = try appState();
    app.binding = zero;
    app.keys = keys;
    var wire_storage: [768]u8 = undefined;
    const wire = try std.fmt.bufPrint(
        &wire_storage,
        "POST / HTTP/1.1\r\nHost: app.example\r\n" ++
            "Origin: https://app.example\r\n" ++
            "Cookie: __Host-ploof-csrf={s}\r\n" ++
            "X-CSRF-Token: {s}\r\n\r\n",
        .{ encoded.slice(), encoded.slice() },
    );
    var decoder = try decodeHead(wire);
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "POST");
    var state = signed_policy.init();
    try std.testing.expectEqual(
        response.Status.forbidden,
        signed_policy.head(&context, &state).?.status,
    );

    decoder = try decodeHead("GET / HTTP/1.1\r\nHost: app.example\r\n\r\n");
    context = try mockContext(&app, &workspace, &decoder, "GET");
    state = signed_policy.init();
    try std.testing.expect(signed_policy.head(&context, &state) == null);
    try std.testing.expectError(
        error.InvalidBinding,
        signed_policy.issue(&context, [_]u8{0x29} ** 32),
    );
    try std.testing.expectError(error.InvalidBinding, signed_policy.currentToken(&context));
}

test "secret owner clear methods zero bytes and invalidate values" {
    var session = try csrf.SessionToken.fromRandomBytes([_]u8{0x62} ** 32);
    session.clear();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &session.bytes);
    try std.testing.expect(!session.valid());

    var binding = try csrf.LoginBinding.fromRandomLoginValue([_]u8{0x63} ** 32);
    binding.clear();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &binding.bytes);
    try std.testing.expect(!binding.valid());

    var keys = try csrf.Keyring.init(
        try csrf.Key.init(1, [_]u8{0x64} ** 32),
        try csrf.Key.init(2, [_]u8{0x65} ** 32),
    );
    keys.clear();
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &keys.active_key.bytes);
    try std.testing.expect(keys.previous_key == null);
    try std.testing.expectEqual(csrf.KeyringIssue.uninitialized, keys.issue().?);
}

test "cookie scanner rejects ambiguity and writer emits secure defaults" {
    var scanner = csrf_request.CookieScanner.init("__Host-ploof-csrf");
    scanner.feed("theme=dark; __Host-ploof-csrf=abc-123_;");
    try std.testing.expect(scanner.finish() == .invalid);

    scanner = csrf_request.CookieScanner.init("__Host-ploof-csrf");
    scanner.feed("theme=dark; __Host-ploof-csrf=abc-123_");
    scanner.feed("__Host-ploof-csrf=second");
    try std.testing.expect(scanner.finish() == .duplicate);

    var output: [192]u8 = undefined;
    const written = try csrf_request.writeCookie(
        "__Host-ploof-csrf",
        "abc-123_",
        .{},
        &output,
    );
    try std.testing.expectEqualStrings(
        "__Host-ploof-csrf=abc-123_; Path=/; Secure; HttpOnly; SameSite=Lax",
        written,
    );
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "__Host-ploof-csrf",
        "abc",
        .{ .secure = false },
        &output,
    ));
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "__Secure-ploof-csrf",
        "abc",
        .{ .secure = false },
        &output,
    ));
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "__secure-ploof-csrf",
        "abc",
        .{ .secure = false },
        &output,
    ));
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "__SeCuRe-ploof-csrf",
        "abc",
        .{ .secure = false },
        &output,
    ));
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "__hOsT-ploof-csrf",
        "abc",
        .{ .path = "/csrf" },
        &output,
    ));
    _ = try csrf_request.writeCookie("__hOsT-ploof-csrf", "abc", .{}, &output);
    try std.testing.expectError(error.InvalidCookieOptions, csrf_request.writeCookie(
        "csrf",
        "abc",
        .{ .path = "/caf\xc3\xa9" },
        &output,
    ));
    _ = try csrf_request.writeCookie(
        "csrf",
        "abc",
        .{ .path = "/caf%C3%A9" },
        &output,
    );
}

test "request state rejects duplicate sources and blocks files before validation" {
    const raw = [_]u8{0x42} ** csrf.synchronizer_bytes;
    const encoded = csrf_request.encodeSynchronizer(&raw);
    var state = csrf.RequestState{ .body_source = .multipart };
    state.beginSynchronizer(&raw);
    try std.testing.expect(!state.beforeFile());

    state = .{ .body_source = .multipart };
    state.beginSynchronizer(&raw);
    try std.testing.expect(state.observe(.multipart, &encoded));
    try std.testing.expect(state.beforeFile());
    try std.testing.expect(!state.observe(.header, &encoded));
    try std.testing.expect(!state.completeBody());
    state.clear();
    try std.testing.expectEqual(csrf_request.Status.pending, state.status);
    try std.testing.expect(state.expected == .none);
}

test "synchronizer policy gates head defers form and protects rendered token" {
    var app = try appState();
    app.session_token = try csrf.SessionToken.fromRandomBytes([_]u8{0x6b} ** 32);
    var encoded = try csrf.EncodedSynchronizerToken.init(app.session_token.?);
    defer encoded.clear();
    var wire_storage: [512]u8 = undefined;
    const wire = try std.fmt.bufPrint(
        &wire_storage,
        "POST / HTTP/1.1\r\n" ++
            "Host: app.example\r\n" ++
            "Origin: https://app.example\r\n" ++
            "X-CSRF-Token: {s}\r\n\r\n",
        .{encoded.slice()},
    );
    var decoder = try decodeHead(wire);
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "POST");
    var state = synchronizer_policy.init();
    try std.testing.expect(synchronizer_policy.head(&context, &state) == null);
    try std.testing.expect(state.completeBody());

    var token_output: [160]u8 = undefined;
    const hidden = try synchronizer_policy.hiddenInput(&context, &token_output);
    try std.testing.expect(std.mem.startsWith(u8, hidden, "<input type=\"hidden\""));
    var value = context.empty(.ok);
    synchronizer_policy.response(&context, &state, &value);
    try expectHeader(&value, "cache-control", "no-store, no-transform");

    var form_decoder = try decodeHead(
        "POST / HTTP/1.1\r\nHost: app.example\r\nOrigin: https://app.example\r\n\r\n",
    );
    context = try mockContext(&app, &workspace, &form_decoder, "POST");
    state = synchronizer_policy.init();
    synchronizer_policy.__setBodySource(&state, .form);
    try std.testing.expect(synchronizer_policy.head(&context, &state) == null);
    try std.testing.expect(state.canDeferToBody());
}

test "synchronizer policy rejects cross-site and duplicate headers with no-store" {
    var app = try appState();
    app.session_token = try csrf.SessionToken.fromRandomBytes([_]u8{0x31} ** 32);
    var encoded = try csrf.EncodedSynchronizerToken.init(app.session_token.?);
    defer encoded.clear();
    var wire_storage: [640]u8 = undefined;
    const wire = try std.fmt.bufPrint(
        &wire_storage,
        "POST / HTTP/1.1\r\n" ++
            "Host: app.example\r\n" ++
            "Sec-Fetch-Site: cross-site\r\n" ++
            "X-CSRF-Token: {s}\r\n\r\n",
        .{encoded.slice()},
    );
    var decoder = try decodeHead(wire);
    var workspace = initializedResponseWorkspace();
    var context = try mockContext(&app, &workspace, &decoder, "POST");
    var state = synchronizer_policy.init();
    const denied = synchronizer_policy.head(&context, &state).?;
    try std.testing.expectEqual(response.Status.forbidden, denied.status);
    try expectHeader(&denied, "cache-control", "no-store");

    const duplicate_wire = try std.fmt.bufPrint(
        &wire_storage,
        "POST / HTTP/1.1\r\nHost: app.example\r\nX-CSRF-Token: {s}\r\nX-CSRF-Token: {s}\r\n\r\n",
        .{ encoded.slice(), encoded.slice() },
    );
    decoder = try decodeHead(duplicate_wire);
    context = try mockContext(&app, &workspace, &decoder, "POST");
    state = synchronizer_policy.init();
    try std.testing.expectEqual(
        response.Status.forbidden,
        synchronizer_policy.head(&context, &state).?.status,
    );
}
