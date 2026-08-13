const std = @import("std");

pub const Status = enum(u16) {
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_info = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207,
    already_reported = 208,
    im_used = 226,

    multiple_choice = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,

    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_auth_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,

    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,

    _,

    pub fn fromInt(value: u16) error{InvalidStatus}!Status {
        if (value < 200 or value > 599) return error.InvalidStatus;
        return @enumFromInt(value);
    }

    pub fn reasonPhrase(status: Status) []const u8 {
        const value = @intFromEnum(status);
        if (value < 200 or value > 599) return "";
        const index = reason_phrase_index[value - 200];
        return if (index == 0) "" else reason_phrases[index - 1].phrase;
    }

    pub fn codeBytes(status: Status) [3]u8 {
        const value = @intFromEnum(status);
        std.debug.assert(value >= 200);
        std.debug.assert(value <= 599);
        return .{
            '0' + @as(u8, @intCast(value / 100)),
            '0' + @as(u8, @intCast((value / 10) % 10)),
            '0' + @as(u8, @intCast(value % 10)),
        };
    }
};

const ReasonPhrase = struct {
    status: Status,
    phrase: []const u8,
};

const reason_phrases = [_]ReasonPhrase{
    .{ .status = .ok, .phrase = "OK" },
    .{ .status = .created, .phrase = "Created" },
    .{ .status = .accepted, .phrase = "Accepted" },
    .{ .status = .non_authoritative_info, .phrase = "Non-Authoritative Information" },
    .{ .status = .no_content, .phrase = "No Content" },
    .{ .status = .reset_content, .phrase = "Reset Content" },
    .{ .status = .partial_content, .phrase = "Partial Content" },
    .{ .status = .multi_status, .phrase = "Multi-Status" },
    .{ .status = .already_reported, .phrase = "Already Reported" },
    .{ .status = .im_used, .phrase = "IM Used" },
    .{ .status = .multiple_choice, .phrase = "Multiple Choice" },
    .{ .status = .moved_permanently, .phrase = "Moved Permanently" },
    .{ .status = .found, .phrase = "Found" },
    .{ .status = .see_other, .phrase = "See Other" },
    .{ .status = .not_modified, .phrase = "Not Modified" },
    .{ .status = .use_proxy, .phrase = "Use Proxy" },
    .{ .status = .temporary_redirect, .phrase = "Temporary Redirect" },
    .{ .status = .permanent_redirect, .phrase = "Permanent Redirect" },
    .{ .status = .bad_request, .phrase = "Bad Request" },
    .{ .status = .unauthorized, .phrase = "Unauthorized" },
    .{ .status = .payment_required, .phrase = "Payment Required" },
    .{ .status = .forbidden, .phrase = "Forbidden" },
    .{ .status = .not_found, .phrase = "Not Found" },
    .{ .status = .method_not_allowed, .phrase = "Method Not Allowed" },
    .{ .status = .not_acceptable, .phrase = "Not Acceptable" },
    .{ .status = .proxy_auth_required, .phrase = "Proxy Authentication Required" },
    .{ .status = .request_timeout, .phrase = "Request Timeout" },
    .{ .status = .conflict, .phrase = "Conflict" },
    .{ .status = .gone, .phrase = "Gone" },
    .{ .status = .length_required, .phrase = "Length Required" },
    .{ .status = .precondition_failed, .phrase = "Precondition Failed" },
    .{ .status = .payload_too_large, .phrase = "Payload Too Large" },
    .{ .status = .uri_too_long, .phrase = "URI Too Long" },
    .{ .status = .unsupported_media_type, .phrase = "Unsupported Media Type" },
    .{ .status = .range_not_satisfiable, .phrase = "Range Not Satisfiable" },
    .{ .status = .expectation_failed, .phrase = "Expectation Failed" },
    .{ .status = .teapot, .phrase = "I'm a teapot" },
    .{ .status = .misdirected_request, .phrase = "Misdirected Request" },
    .{ .status = .unprocessable_entity, .phrase = "Unprocessable Entity" },
    .{ .status = .locked, .phrase = "Locked" },
    .{ .status = .failed_dependency, .phrase = "Failed Dependency" },
    .{ .status = .too_early, .phrase = "Too Early" },
    .{ .status = .upgrade_required, .phrase = "Upgrade Required" },
    .{ .status = .precondition_required, .phrase = "Precondition Required" },
    .{ .status = .too_many_requests, .phrase = "Too Many Requests" },
    .{ .status = .request_header_fields_too_large, .phrase = "Request Header Fields Too Large" },
    .{ .status = .unavailable_for_legal_reasons, .phrase = "Unavailable For Legal Reasons" },
    .{ .status = .internal_server_error, .phrase = "Internal Server Error" },
    .{ .status = .not_implemented, .phrase = "Not Implemented" },
    .{ .status = .bad_gateway, .phrase = "Bad Gateway" },
    .{ .status = .service_unavailable, .phrase = "Service Unavailable" },
    .{ .status = .gateway_timeout, .phrase = "Gateway Timeout" },
    .{ .status = .http_version_not_supported, .phrase = "HTTP Version Not Supported" },
    .{ .status = .variant_also_negotiates, .phrase = "Variant Also Negotiates" },
    .{ .status = .insufficient_storage, .phrase = "Insufficient Storage" },
    .{ .status = .loop_detected, .phrase = "Loop Detected" },
    .{ .status = .not_extended, .phrase = "Not Extended" },
    .{ .status = .network_authentication_required, .phrase = "Network Authentication Required" },
};

const reason_phrase_index = buildReasonPhraseIndex();

fn buildReasonPhraseIndex() [400]u8 {
    std.debug.assert(reason_phrases.len < 256);
    var index = [_]u8{0} ** 400;
    for (reason_phrases, 0..) |entry, entry_index| {
        const value = @intFromEnum(entry.status);
        std.debug.assert(value >= 200);
        std.debug.assert(value <= 599);
        const slot = value - 200;
        if (index[slot] != 0) @compileError("duplicate status reason phrase");
        index[slot] = @intCast(entry_index + 1);
    }
    return index;
}

test "known statuses round-trip and have canonical reason phrases" {
    var previous: u16 = 199;
    for (reason_phrases) |entry| {
        const value = @intFromEnum(entry.status);
        try std.testing.expect(value > previous);
        try std.testing.expectEqual(entry.status, try Status.fromInt(value));
        try std.testing.expectEqualStrings(entry.phrase, entry.status.reasonPhrase());
        previous = value;
    }
}

test "dynamic status range is inclusive" {
    try std.testing.expectEqual(@as(Status, .ok), try Status.fromInt(200));
    try std.testing.expectEqual(@as(u16, 599), @intFromEnum(try Status.fromInt(599)));
    try std.testing.expectError(error.InvalidStatus, Status.fromInt(0));
    try std.testing.expectError(error.InvalidStatus, Status.fromInt(199));
    try std.testing.expectError(error.InvalidStatus, Status.fromInt(600));
    try std.testing.expectError(error.InvalidStatus, Status.fromInt(std.math.maxInt(u16)));
}

test "unknown extension statuses have empty phrases" {
    try std.testing.expectEqualStrings("", (try Status.fromInt(299)).reasonPhrase());
    try std.testing.expectEqualStrings("", (try Status.fromInt(599)).reasonPhrase());
}

test "status codes serialize as three digits" {
    try std.testing.expectEqualStrings("200", &(try Status.fromInt(200)).codeBytes());
    try std.testing.expectEqualStrings("299", &(try Status.fromInt(299)).codeBytes());
    try std.testing.expectEqualStrings("599", &(try Status.fromInt(599)).codeBytes());
}
