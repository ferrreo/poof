const std = @import("std");

pub const max_object_bytes = 5 * 1024 * 1024;
pub const key_bytes_max = 48;

pub const Config = struct {
    endpoint: []const u8,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    bucket: []const u8,
};

pub const Error = error{
    InvalidEndpoint,
    InvalidObjectKey,
    RequestFailed,
    UnexpectedStatus,
    OutOfMemory,
    NoSpaceLeft,
    BucketUnavailable,
};

pub fn ensureBucket(
    io: std.Io,
    allocator: std.mem.Allocator,
    settings: Config,
) Error!void {
    var url_buf: [512]u8 = undefined;
    const url = try objectUrl(&url_buf, settings, "");
    const head = try signedExchange(
        io,
        allocator,
        settings,
        .HEAD,
        url,
        "",
        "application/xml",
        &.{},
        null,
    );
    if (head == .ok) return;

    const status = try signedExchange(
        io,
        allocator,
        settings,
        .PUT,
        url,
        "",
        "application/xml",
        &.{},
        null,
    );
    if (status == .ok or status == .created) return;
    // Already owned / exists.
    if (@intFromEnum(status) == 409) return;
    if (@intFromEnum(status) == 405) {
        const again = try signedExchange(
            io,
            allocator,
            settings,
            .HEAD,
            url,
            "",
            "application/xml",
            &.{},
            null,
        );
        if (again == .ok) return;
    }
    return error.BucketUnavailable;
}

pub fn putObject(
    io: std.Io,
    allocator: std.mem.Allocator,
    settings: Config,
    key: []const u8,
    content_type: []const u8,
    body: []const u8,
) Error!void {
    try validateKey(key);
    if (body.len == 0 or body.len > max_object_bytes) return error.RequestFailed;
    var url_buf: [512]u8 = undefined;
    const url = try objectUrl(&url_buf, settings, key);
    const status = try signedExchange(
        io,
        allocator,
        settings,
        .PUT,
        url,
        key,
        content_type,
        body,
        null,
    );
    if (status != .ok and status != .created) return error.UnexpectedStatus;
}

pub fn getObject(
    io: std.Io,
    allocator: std.mem.Allocator,
    settings: Config,
    key: []const u8,
    output: []u8,
) Error![]const u8 {
    try validateKey(key);
    var url_buf: [512]u8 = undefined;
    const url = try objectUrl(&url_buf, settings, key);
    var writer = std.Io.Writer.fixed(output);
    const status = try signedExchange(
        io,
        allocator,
        settings,
        .GET,
        url,
        key,
        "application/octet-stream",
        &.{},
        &writer,
    );
    if (status == .not_found) return error.UnexpectedStatus;
    if (status != .ok) return error.UnexpectedStatus;
    return output[0..writer.end];
}

pub fn validateKey(key: []const u8) Error!void {
    if (key.len < 6 or key.len > key_bytes_max) return error.InvalidObjectKey;
    const dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse return error.InvalidObjectKey;
    if (dot == 0 or dot + 1 >= key.len) return error.InvalidObjectKey;
    const name = key[0..dot];
    const ext = key[dot + 1 ..];
    if (name.len != 32) return error.InvalidObjectKey;
    for (name) |byte| {
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidObjectKey;
    }
    inline for (.{ "png", "jpg", "jpeg", "gif", "webp" }) |allowed| {
        if (std.mem.eql(u8, ext, allowed)) return;
    }
    return error.InvalidObjectKey;
}

pub fn contentTypeForKey(key: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(key, ".png")) return "image/png";
    if (std.ascii.endsWithIgnoreCase(key, ".jpg") or
        std.ascii.endsWithIgnoreCase(key, ".jpeg")) return "image/jpeg";
    if (std.ascii.endsWithIgnoreCase(key, ".gif")) return "image/gif";
    if (std.ascii.endsWithIgnoreCase(key, ".webp")) return "image/webp";
    return "application/octet-stream";
}

pub fn extensionForContentType(content_type: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(content_type, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(content_type, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(content_type, "image/gif")) return "gif";
    if (std.ascii.eqlIgnoreCase(content_type, "image/webp")) return "webp";
    return null;
}

pub fn detectImage(
    bytes: []const u8,
    claimed: []const u8,
) ?struct { content_type: []const u8, extension: []const u8 } {
    if (bytes.len < 12) return null;
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        if (!std.ascii.eqlIgnoreCase(claimed, "image/png")) return null;
        return .{ .content_type = "image/png", .extension = "png" };
    }
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) {
        if (!std.ascii.eqlIgnoreCase(claimed, "image/jpeg")) return null;
        return .{ .content_type = "image/jpeg", .extension = "jpg" };
    }
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) {
        if (!std.ascii.eqlIgnoreCase(claimed, "image/gif")) return null;
        return .{ .content_type = "image/gif", .extension = "gif" };
    }
    if (std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        if (!std.ascii.eqlIgnoreCase(claimed, "image/webp")) return null;
        return .{ .content_type = "image/webp", .extension = "webp" };
    }
    return null;
}

fn objectUrl(buffer: []u8, settings: Config, key: []const u8) Error![]const u8 {
    const endpoint = std.mem.trimEnd(u8, settings.endpoint, "/");
    if (endpoint.len == 0) return error.InvalidEndpoint;
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll(endpoint) catch return error.NoSpaceLeft;
    writer.writeByte('/') catch return error.NoSpaceLeft;
    writer.writeAll(settings.bucket) catch return error.NoSpaceLeft;
    if (key.len != 0) {
        writer.writeByte('/') catch return error.NoSpaceLeft;
        try writeUriPath(&writer, key);
    }
    return buffer[0..writer.end];
}

fn writeUriPath(writer: *std.Io.Writer, value: []const u8) Error!void {
    for (value) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (unreserved) {
            writer.writeByte(byte) catch return error.NoSpaceLeft;
        } else {
            writer.print("%{X:0>2}", .{byte}) catch return error.NoSpaceLeft;
        }
    }
}

fn signedExchange(
    io: std.Io,
    allocator: std.mem.Allocator,
    settings: Config,
    method: std.http.Method,
    url: []const u8,
    key: []const u8,
    content_type: []const u8,
    payload: []const u8,
    response_writer: ?*std.Io.Writer,
) Error!std.http.Status {
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    var host_only_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = uri.getHost(&host_only_buf) catch return error.InvalidEndpoint;
    var host_buf: [std.Io.net.HostName.max_len + 8]u8 = undefined;
    const host = blk: {
        const default_port: ?u16 = if (std.mem.eql(u8, uri.scheme, "https"))
            443
        else if (std.mem.eql(u8, uri.scheme, "http"))
            80
        else
            null;
        if (uri.port) |port| {
            if (default_port == null or port != default_port.?) {
                break :blk std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ host_name.bytes, port }) catch
                    return error.NoSpaceLeft;
            }
        }
        break :blk host_name.bytes;
    };

    var payload_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &payload_hash, .{});
    const payload_hex = std.fmt.bytesToHex(payload_hash, .lower);

    const now_sec = std.Io.Clock.real.now(io).toSeconds();
    var amz_date: [16]u8 = undefined;
    var date_stamp: [8]u8 = undefined;
    formatAmzDate(now_sec, &amz_date, &date_stamp) catch return error.RequestFailed;

    var canonical_uri_buf: [256]u8 = undefined;
    const canonical_uri = try canonicalUri(&canonical_uri_buf, settings.bucket, key);

    var canonical_headers_buf: [512]u8 = undefined;
    var signed_headers_buf: [128]u8 = undefined;
    const include_content_type = method == .PUT and payload.len != 0;
    const headers_pair = try canonicalHeaders(
        &canonical_headers_buf,
        &signed_headers_buf,
        host,
        content_type,
        &amz_date,
        &payload_hex,
        include_content_type,
    );

    var canonical_request_buf: [1024]u8 = undefined;
    const canonical_request = std.fmt.bufPrint(&canonical_request_buf, "{s}\n{s}\n\n{s}\n{s}\n{s}", .{
        methodName(method),
        canonical_uri,
        headers_pair.canonical,
        headers_pair.signed,
        payload_hex,
    }) catch return error.NoSpaceLeft;

    var canonical_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_request, &canonical_hash, .{});
    const canonical_hex = std.fmt.bytesToHex(canonical_hash, .lower);

    var scope_buf: [128]u8 = undefined;
    const scope = std.fmt.bufPrint(&scope_buf, "{s}/{s}/s3/aws4_request", .{
        date_stamp,
        settings.region,
    }) catch return error.NoSpaceLeft;

    var string_to_sign_buf: [256]u8 = undefined;
    const string_to_sign = std.fmt.bufPrint(
        &string_to_sign_buf,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ amz_date, scope, canonical_hex },
    ) catch return error.NoSpaceLeft;

    var signing_key: [32]u8 = undefined;
    deriveSigningKey(settings.secret_key, &date_stamp, settings.region, &signing_key);
    var signature: [32]u8 = undefined;
    hmacSha256(&signing_key, string_to_sign, &signature);
    const signature_hex = std.fmt.bytesToHex(signature, .lower);

    var auth_buf: [512]u8 = undefined;
    const authorization = std.fmt.bufPrint(
        &auth_buf,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ settings.access_key, scope, headers_pair.signed, signature_hex },
    ) catch return error.NoSpaceLeft;

    var headers_storage: [5]std.http.Header = undefined;
    var header_count: usize = 0;
    headers_storage[header_count] = .{ .name = "x-amz-date", .value = &amz_date };
    header_count += 1;
    headers_storage[header_count] = .{ .name = "x-amz-content-sha256", .value = &payload_hex };
    header_count += 1;
    headers_storage[header_count] = .{ .name = "authorization", .value = authorization };
    header_count += 1;
    if (include_content_type) {
        headers_storage[header_count] = .{ .name = "content-type", .value = content_type };
        header_count += 1;
    }

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    // Zig 0.16 `fetch` writes into the const `Reader.ending` sentinel for HEAD
    // (`responseHasBody() == false`), which SIGSEGVs. Read headers only.
    if (method == .HEAD) {
        var req = client.request(.HEAD, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers_storage[0..header_count],
        }) catch return error.RequestFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.RequestFailed;
        const response = req.receiveHead(&.{}) catch return error.RequestFailed;
        return response.head.status;
    }

    var discard_buf: [512]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = if (method == .GET) null else payload,
        .extra_headers = headers_storage[0..header_count],
        .response_writer = response_writer orelse &discarding.writer,
        .redirect_behavior = .unhandled,
    }) catch return error.RequestFailed;
    return result.status;
}

fn canonicalUri(buffer: []u8, bucket: []const u8, key: []const u8) Error![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeByte('/') catch return error.NoSpaceLeft;
    try writeUriPath(&writer, bucket);
    if (key.len != 0) {
        writer.writeByte('/') catch return error.NoSpaceLeft;
        try writeUriPath(&writer, key);
    }
    return buffer[0..writer.end];
}

fn canonicalHeaders(
    canonical_buf: []u8,
    signed_buf: []u8,
    host: []const u8,
    content_type: []const u8,
    amz_date: []const u8,
    payload_hex: []const u8,
    include_content_type: bool,
) Error!struct { canonical: []const u8, signed: []const u8 } {
    var canonical = std.Io.Writer.fixed(canonical_buf);
    var signed = std.Io.Writer.fixed(signed_buf);
    if (include_content_type) {
        canonical.print("content-type:{s}\n", .{content_type}) catch return error.NoSpaceLeft;
        signed.writeAll("content-type;") catch return error.NoSpaceLeft;
    }
    canonical.print("host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{
        host,
        payload_hex,
        amz_date,
    }) catch return error.NoSpaceLeft;
    signed.writeAll("host;x-amz-content-sha256;x-amz-date") catch return error.NoSpaceLeft;
    return .{
        .canonical = canonical_buf[0..canonical.end],
        .signed = signed_buf[0..signed.end],
    };
}

fn deriveSigningKey(
    secret: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    out: *[32]u8,
) void {
    var prefix_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "AWS4{s}", .{secret}) catch unreachable;
    var k_date: [32]u8 = undefined;
    hmacSha256(prefix, date_stamp, &k_date);
    var k_region: [32]u8 = undefined;
    hmacSha256(&k_date, region, &k_region);
    var k_service: [32]u8 = undefined;
    hmacSha256(&k_region, "s3", &k_service);
    hmacSha256(&k_service, "aws4_request", out);
}

fn hmacSha256(key: []const u8, message: []const u8, out: *[32]u8) void {
    var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
    mac.update(message);
    mac.final(out);
}

fn formatAmzDate(epoch_sec: i64, amz_date: *[16]u8, date_stamp: *[8]u8) !void {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(epoch_sec, 0)) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    _ = try std.fmt.bufPrint(amz_date, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
    @memcpy(date_stamp, amz_date[0..8]);
}

fn methodName(method: std.http.Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .PUT => "PUT",
        .HEAD => "HEAD",
        .DELETE => "DELETE",
        .POST => "POST",
        else => "GET",
    };
}

test "image detection accepts png magic with matching claim" {
    const png = "\x89PNG\r\n\x1a\n" ++ "xxxxxxxxxx";
    const detected = detectImage(png, "image/png").?;
    try std.testing.expectEqualStrings("png", detected.extension);
}

test "object keys must be lowercase hex plus safe extension" {
    try validateKey("0123456789abcdef0123456789abcdef.png");
    try std.testing.expectError(error.InvalidObjectKey, validateKey("../etc/passwd.png"));
    try std.testing.expectError(error.InvalidObjectKey, validateKey("0123456789ABCDEF0123456789abcdef.png"));
}
