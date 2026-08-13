const std = @import("std");
const application_types = @import("internal/application/types.zig");
const csrf_config = @import("internal/csrf/config.zig");
const csrf_origin = @import("internal/csrf/origin.zig");
const csrf_request = @import("internal/csrf/request.zig");
const multipart = @import("multipart.zig");
const response = @import("response.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const signed_version: u8 = 1;
const signed_domain = "ploof.csrf.signed-double-submit.v1\x00";

pub const OriginSet = csrf_origin.OriginSet;
pub const StandardOriginSet = OriginSet(8, 255);
pub const OriginSetIssue = csrf_origin.SetIssue;
pub const OriginSetFailure = csrf_origin.InitFailure;
pub const BodySource = csrf_request.BodySource;
pub const TokenSource = csrf_request.TokenSource;
pub const RequestState = csrf_request.State;
pub const Rejection = csrf_request.Rejection;
pub const SameSite = csrf_request.SameSite;
pub const CookieOptions = csrf_request.CookieOptions;
pub const CookieWriteError = csrf_request.CookieWriteError;

pub const synchronizer_bytes = csrf_request.synchronizer_bytes;
pub const synchronizer_encoded_bytes = csrf_request.synchronizer_encoded_bytes;
pub const signed_encoded_bytes = csrf_request.signed_encoded_bytes;
pub const token_encoded_bytes_max = csrf_request.token_encoded_bytes_max;

pub const Mode = enum(u1) {
    synchronizer,
    signed_double_submit,
};

pub const RandomValueError = error{InvalidRandomValue};
pub const PolicyStateError = error{PolicyNotActive};

pub const SessionToken = struct {
    bytes: [synchronizer_bytes]u8,

    pub fn fromRandomBytes(bytes: [synchronizer_bytes]u8) RandomValueError!SessionToken {
        if (allZero(&bytes)) return error.InvalidRandomValue;
        return .{ .bytes = bytes };
    }

    pub fn valid(token: *const SessionToken) bool {
        return !allZero(&token.bytes);
    }

    pub fn clear(token: *SessionToken) void {
        std.crypto.secureZero(u8, &token.bytes);
    }
};

pub const LoginBinding = struct {
    bytes: [32]u8,

    pub fn fromRandomLoginValue(bytes: [32]u8) RandomValueError!LoginBinding {
        if (allZero(&bytes)) return error.InvalidRandomValue;
        return .{ .bytes = bytes };
    }

    pub fn valid(binding: *const LoginBinding) bool {
        return !allZero(&binding.bytes);
    }

    pub fn clear(binding: *LoginBinding) void {
        std.crypto.secureZero(u8, &binding.bytes);
    }
};

pub const Key = struct {
    id: u8,
    bytes: [32]u8,

    pub fn init(id: u8, bytes: [32]u8) error{InvalidKey}!Key {
        if (allZero(&bytes)) return error.InvalidKey;
        return .{ .id = id, .bytes = bytes };
    }

    pub fn clear(key: *Key) void {
        std.crypto.secureZero(u8, &key.bytes);
        key.id = 0;
    }
};

pub const KeyringIssue = enum(u8) {
    uninitialized,
    active_key_zero,
    previous_key_zero,
    duplicate_key_id,
};

pub const Keyring = struct {
    active_key: Key = .{ .id = 0, .bytes = [_]u8{0} ** 32 },
    previous_key: ?Key = null,
    initialized: bool = false,

    pub fn init(active: Key, previous: ?Key) error{InvalidKeyring}!Keyring {
        const keyring = Keyring{
            .active_key = active,
            .previous_key = previous,
            .initialized = true,
        };
        if (keyring.issue() != null) return error.InvalidKeyring;
        return keyring;
    }

    pub fn issue(keyring: *const Keyring) ?KeyringIssue {
        if (!keyring.initialized) return .uninitialized;
        if (allZero(&keyring.active_key.bytes)) return .active_key_zero;
        if (keyring.previous_key) |*previous| {
            if (allZero(&previous.bytes)) return .previous_key_zero;
            if (previous.id == keyring.active_key.id) return .duplicate_key_id;
        }
        return null;
    }

    pub fn clear(keyring: *Keyring) void {
        keyring.active_key.clear();
        if (keyring.previous_key) |*previous| previous.clear();
        keyring.previous_key = null;
        keyring.initialized = false;
    }

    pub fn sign(
        keyring: *const Keyring,
        binding: LoginBinding,
        nonce: [32]u8,
    ) error{ InvalidBinding, InvalidKeyring, InvalidNonce }!EncodedSignedToken {
        var binding_copy = binding;
        defer binding_copy.clear();
        var nonce_copy = nonce;
        defer std.crypto.secureZero(u8, &nonce_copy);
        if (keyring.issue() != null) return error.InvalidKeyring;
        if (!binding_copy.valid()) return error.InvalidBinding;
        if (allZero(&nonce_copy)) return error.InvalidNonce;
        var raw: [csrf_request.signed_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        raw[0] = signed_version;
        raw[1] = keyring.active_key.id;
        @memcpy(raw[2..34], &nonce_copy);
        mac(&keyring.active_key, &binding_copy, &nonce_copy, raw[34..66]);
        return .{ .bytes = csrf_request.encodeSigned(&raw) };
    }

    pub fn verify(
        keyring: *const Keyring,
        binding: LoginBinding,
        encoded: []const u8,
    ) bool {
        var binding_copy = binding;
        defer binding_copy.clear();
        if (keyring.issue() != null) return false;
        if (!binding_copy.valid()) return false;
        var raw: [csrf_request.signed_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        if (!csrf_request.decodeSigned(encoded, &raw) or raw[0] != signed_version) return false;
        const selected_key = keyring.findKey(raw[1]) orelse return false;
        var expected: [HmacSha256.mac_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &expected);
        mac(selected_key, &binding_copy, &raw[2..34].*, &expected);
        return std.crypto.timing_safe.eql([32]u8, expected, raw[34..66].*);
    }

    fn findKey(keyring: *const Keyring, id: u8) ?*const Key {
        if (keyring.active_key.id == id) return &keyring.active_key;
        if (keyring.previous_key) |*previous| if (previous.id == id) return previous;
        return null;
    }
};

pub const EncodedSynchronizerToken = struct {
    bytes: [synchronizer_encoded_bytes]u8,

    pub fn init(token_value: SessionToken) error{InvalidSessionToken}!EncodedSynchronizerToken {
        var token = token_value;
        defer token.clear();
        if (!token.valid()) return error.InvalidSessionToken;
        return .{ .bytes = csrf_request.encodeSynchronizer(&token.bytes) };
    }

    pub fn slice(token: *const EncodedSynchronizerToken) []const u8 {
        return &token.bytes;
    }

    pub fn clear(token: *EncodedSynchronizerToken) void {
        std.crypto.secureZero(u8, &token.bytes);
    }
};

pub const EncodedSignedToken = struct {
    bytes: [signed_encoded_bytes]u8,

    fn parseUnverified(encoded: []const u8) error{InvalidToken}!EncodedSignedToken {
        var raw: [csrf_request.signed_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &raw);
        if (!csrf_request.decodeSigned(encoded, &raw) or raw[0] != signed_version) {
            return error.InvalidToken;
        }
        return .{ .bytes = encoded[0..signed_encoded_bytes].* };
    }

    pub fn slice(token: *const EncodedSignedToken) []const u8 {
        return &token.bytes;
    }

    pub fn cookieHeader(
        token: *const EncodedSignedToken,
        name: []const u8,
        options: CookieOptions,
        output: []u8,
    ) CookieWriteError![]const u8 {
        return csrf_request.writeCookie(name, token.slice(), options, output);
    }

    pub fn clear(token: *EncodedSignedToken) void {
        std.crypto.secureZero(u8, &token.bytes);
    }
};

pub const StartupIssue = union(enum) {
    origins: OriginSetIssue,
    source_origins: OriginSetIssue,
    keyring: KeyringIssue,
};

pub fn synchronizer(comptime Context: type, comptime config: anytype) SynchronizerPolicy(
    Context,
    config,
) {
    csrf_config.validateSynchronizer(Context, config, SessionToken);
    return .{};
}

pub fn signedDoubleSubmit(comptime Context: type, comptime config: anytype) SignedPolicy(
    Context,
    config,
) {
    csrf_config.validateSigned(Context, config, Keyring, LoginBinding);
    return .{};
}

pub const signed_double_submit = signedDoubleSubmit;

pub fn multipartField() MultipartField {
    return .{};
}

pub const MultipartField = struct {
    pub const ploof_multipart_part = true;
    pub const ploof_csrf_field = true;
    pub const kind: multipart.PartKind = .bytes_field;
    pub const Target = []const u8;
    pub const cardinality: multipart.Cardinality = .optional;
};

fn SynchronizerPolicy(comptime Context: type, comptime config: anytype) type {
    const header = csrf_config.selectedName(config, "header_name", "X-CSRF-Token");
    const form = csrf_config.selectedName(config, "form_name", "_csrf");
    return struct {
        const Self = @This();

        pub const ploof_csrf_policy = true;
        pub const mode: Mode = .synchronizer;
        pub const header_name = header;
        pub const form_name = form;
        pub const State = RequestState;

        pub fn init(_: Self) State {
            return .{};
        }

        pub fn __setBodySource(_: Self, state: *State, source: BodySource) void {
            state.body_source = source;
        }

        pub fn startupIssue(_: Self, state: *const Context.ApplicationState) ?StartupIssue {
            return configuredOriginsIssue(config, state);
        }

        pub fn head(_: Self, context: *Context, state: *State) ?Context.ResponseType {
            context.csrf_request = state;
            if (gateConfiguredRequest(context, config)) |status| {
                rejectForStatus(state, status);
                return rejection(context, status);
            }
            if (!csrf_origin.unsafeMethod(context.request.method)) {
                state.beginSafe();
                return null;
            }
            var expected = config.load(context) orelse {
                state.reject();
                return rejection(context, .forbidden);
            };
            defer expected.clear();
            if (!expected.valid()) {
                state.reject();
                return rejection(context, .forbidden);
            }
            state.beginSynchronizer(&expected.bytes);
            return validateHeaderOrDefer(context, state, header);
        }

        pub fn body(_: Self, context: *Context, state: *State, _: anytype) ?Context.ResponseType {
            return if (state.completeBody()) null else rejection(context, .forbidden);
        }

        pub fn response(_: Self, _: *Context, state: *State, value: anytype) void {
            protectTokenResponse(state, value);
        }

        pub fn after(
            _: Self,
            _: *const Context,
            state: *State,
            _: application_types.Outcome,
        ) void {
            state.clear();
        }

        pub fn token(
            _: Self,
            context: *Context,
        ) error{
            InvalidSessionToken,
            MissingSessionToken,
            PolicyNotActive,
        }!EncodedSynchronizerToken {
            try expose(context);
            var raw = config.load(context) orelse return error.MissingSessionToken;
            defer raw.clear();
            return EncodedSynchronizerToken.init(raw);
        }

        pub fn hiddenInput(
            self: Self,
            context: *Context,
            output: []u8,
        ) error{
            InvalidSessionToken,
            MissingSessionToken,
            PolicyNotActive,
            NoSpaceLeft,
        }![]const u8 {
            var encoded = try self.token(context);
            defer encoded.clear();
            return csrf_request.writeHiddenInput(form, encoded.slice(), output) catch |problem| {
                return switch (problem) {
                    error.NoSpaceLeft => error.NoSpaceLeft,
                    error.InvalidFieldName => unreachable,
                };
            };
        }

        pub fn rotate(
            _: Self,
            context: *Context,
            token_value: SessionToken,
        ) error{InvalidSessionToken}!void {
            var stored_token = token_value;
            defer stored_token.clear();
            if (!stored_token.valid()) return error.InvalidSessionToken;
            config.store(context, stored_token);
        }

        pub fn clear(_: Self, context: *Context) void {
            config.clear(context);
        }
    };
}

fn SignedPolicy(comptime Context: type, comptime config: anytype) type {
    const header = csrf_config.selectedName(config, "header_name", "X-CSRF-Token");
    const form = csrf_config.selectedName(config, "form_name", "_csrf");
    const cookie = csrf_config.selectedName(config, "cookie_name", "__Host-ploof-csrf");
    return struct {
        const Self = @This();

        pub const ploof_csrf_policy = true;
        pub const mode: Mode = .signed_double_submit;
        pub const header_name = header;
        pub const form_name = form;
        pub const cookie_name = cookie;
        pub const State = RequestState;

        pub fn init(_: Self) State {
            return .{};
        }

        pub fn __setBodySource(_: Self, state: *State, source: BodySource) void {
            state.body_source = source;
        }

        pub fn startupIssue(_: Self, state: *const Context.ApplicationState) ?StartupIssue {
            if (configuredOriginsIssue(config, state)) |problem| return problem;
            const keys = config.keys(state);
            return if (keys.issue()) |problem| .{ .keyring = problem } else null;
        }

        pub fn head(_: Self, context: *Context, state: *State) ?Context.ResponseType {
            context.csrf_request = state;
            if (gateConfiguredRequest(context, config)) |status| {
                rejectForStatus(state, status);
                return rejection(context, status);
            }
            if (!csrf_origin.unsafeMethod(context.request.method)) {
                state.beginSafe();
                return null;
            }
            var binding = config.binding(context) orelse {
                state.reject();
                return rejection(context, .forbidden);
            };
            defer binding.clear();
            if (!binding.valid()) {
                state.reject();
                return rejection(context, .forbidden);
            }
            const encoded = requestCookie(context.request.headers, cookie) orelse {
                state.reject();
                return rejection(context, .forbidden);
            };
            const keys = config.keys(context.state);
            if (!keys.verify(binding, encoded) or !state.beginSigned(encoded)) {
                state.reject();
                return rejection(context, .forbidden);
            }
            return validateHeaderOrDefer(context, state, header);
        }

        pub fn body(_: Self, context: *Context, state: *State, _: anytype) ?Context.ResponseType {
            return if (state.completeBody()) null else rejection(context, .forbidden);
        }

        pub fn response(_: Self, _: *Context, state: *State, value: anytype) void {
            protectTokenResponse(state, value);
        }

        pub fn after(
            _: Self,
            _: *const Context,
            state: *State,
            _: application_types.Outcome,
        ) void {
            state.clear();
        }

        pub fn issue(
            _: Self,
            context: *Context,
            nonce: [32]u8,
        ) error{
            MissingBinding,
            InvalidBinding,
            InvalidKeyring,
            InvalidNonce,
            PolicyNotActive,
        }!EncodedSignedToken {
            try expose(context);
            var binding = config.binding(context) orelse return error.MissingBinding;
            defer binding.clear();
            if (!binding.valid()) return error.InvalidBinding;
            const keys = config.keys(context.state);
            const encoded = keys.sign(binding, nonce) catch |problem| return problem;
            return encoded;
        }

        pub fn currentToken(
            _: Self,
            context: *Context,
        ) error{
            InvalidBinding,
            MissingBinding,
            InvalidToken,
            PolicyNotActive,
        }!EncodedSignedToken {
            try expose(context);
            var binding = config.binding(context) orelse return error.MissingBinding;
            defer binding.clear();
            if (!binding.valid()) return error.InvalidBinding;
            const encoded = requestCookie(context.request.headers, cookie) orelse {
                return error.InvalidToken;
            };
            if (!config.keys(context.state).verify(binding, encoded)) return error.InvalidToken;
            return EncodedSignedToken.parseUnverified(encoded) catch error.InvalidToken;
        }

        pub fn hiddenInput(
            _: Self,
            context: *Context,
            token_value: *const EncodedSignedToken,
            output: []u8,
        ) error{
            InvalidBinding,
            InvalidToken,
            MissingBinding,
            PolicyNotActive,
            NoSpaceLeft,
        }![]const u8 {
            try expose(context);
            var binding = config.binding(context) orelse return error.MissingBinding;
            defer binding.clear();
            if (!binding.valid()) return error.InvalidBinding;
            if (!config.keys(context.state).verify(binding, token_value.slice())) {
                return error.InvalidToken;
            }
            return csrf_request.writeHiddenInput(
                form,
                token_value.slice(),
                output,
            ) catch |problem| {
                return switch (problem) {
                    error.NoSpaceLeft => error.NoSpaceLeft,
                    error.InvalidFieldName => unreachable,
                };
            };
        }

        pub fn cookieHeader(
            _: Self,
            token_value: *const EncodedSignedToken,
            options: CookieOptions,
            output: []u8,
        ) CookieWriteError![]const u8 {
            return token_value.cookieHeader(cookie, options, output);
        }
    };
}

fn validateHeaderOrDefer(
    context: anytype,
    state: *RequestState,
    comptime header_name: []const u8,
) ?@TypeOf(context.empty(.forbidden)) {
    return switch (oneHeader(context.request.headers, header_name)) {
        .multiple => blk: {
            state.reject();
            break :blk rejection(context, .forbidden);
        },
        .value => |value| if (state.observe(.header, value)) null else rejection(
            context,
            .forbidden,
        ),
        .absent => if (state.canDeferToBody()) null else blk: {
            state.reject();
            break :blk rejection(context, .forbidden);
        },
    };
}

fn configuredOriginsIssue(comptime config: anytype, state: anytype) ?StartupIssue {
    if (config.origins(state).issue()) |problem| return .{ .origins = problem };
    if (comptime @hasField(@TypeOf(config), "source_origins")) {
        if (config.source_origins(state).issue()) |problem| {
            return .{ .source_origins = problem };
        }
    }
    return null;
}

fn gateConfiguredRequest(context: anytype, comptime config: anytype) ?response.Status {
    const public_origins = config.origins(context.state);
    if (comptime @hasField(@TypeOf(config), "source_origins")) {
        return gateRequest(context, public_origins, config.source_origins(context.state));
    }
    return gateRequest(context, public_origins, public_origins);
}

fn gateRequest(
    context: anytype,
    public_origins: anytype,
    source_origins: anytype,
) ?response.Status {
    const decision = csrf_origin.gate(
        public_origins,
        source_origins,
        context.request.effectiveScheme(),
        context.request.effectiveAuthority(),
        csrf_origin.unsafeMethod(context.request.method),
        .{
            .fetch_site = oneHeader(context.request.headers, "Sec-Fetch-Site"),
            .origin = oneHeader(context.request.headers, "Origin"),
            .referer = oneHeader(context.request.headers, "Referer"),
        },
    );
    return switch (decision) {
        .allow => null,
        .forbidden => .forbidden,
        .misdirected => .misdirected_request,
    };
}

fn oneHeader(headers: anytype, name: []const u8) csrf_origin.HeaderValue {
    const values = headers.all(name);
    return switch (values.count()) {
        0 => .absent,
        1 => .{ .value = values.first().? },
        else => .multiple,
    };
}

fn requestCookie(headers: anytype, name: []const u8) ?[]const u8 {
    var scanner = csrf_request.CookieScanner.init(name);
    var values = headers.all("Cookie").iterator();
    while (values.next()) |value| scanner.feed(value);
    return switch (scanner.finish()) {
        .value => |value| value,
        .absent, .invalid, .duplicate => null,
    };
}

fn rejection(context: anytype, status: response.Status) @TypeOf(context.empty(.forbidden)) {
    var value = switch (status) {
        .forbidden => context.empty(.forbidden),
        .misdirected_request => context.empty(.misdirected_request),
        else => unreachable,
    };
    value.headers.clear();
    value.setHeaderStatic("Cache-Control", "no-store") catch unreachable;
    return value;
}

fn protectTokenResponse(state: *RequestState, value: anytype) void {
    if (!state.token_exposed) return;
    value.setHeaderStatic("Cache-Control", "no-store, no-transform") catch return;
}

fn expose(context: anytype) PolicyStateError!void {
    const state = context.csrf_request orelse return error.PolicyNotActive;
    state.exposeToken();
}

fn rejectForStatus(state: *RequestState, status: response.Status) void {
    if (status == .misdirected_request) state.rejectMisdirected() else state.reject();
}

fn mac(
    key: *const Key,
    binding: *const LoginBinding,
    nonce: *const [32]u8,
    output: *[32]u8,
) void {
    var hmac = HmacSha256.init(&key.bytes);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
    hmac.update(signed_domain);
    hmac.update(&.{ signed_version, key.id });
    hmac.update(&binding.bytes);
    hmac.update(nonce);
    hmac.final(output);
}

fn allZero(bytes: []const u8) bool {
    var combined: u8 = 0;
    for (bytes) |byte| combined |= byte;
    return combined == 0;
}

test {
    std.testing.refAllDecls(@This());
}
