const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../../app_state.zig");
const request = @import("../request.zig");
const s3 = @import("../../storage/s3.zig");
const image_sink = @import("../../storage/image_sink.zig");

const upload_limits = ploof.Multipart.Limits.validate(.{
    .encoded_wire_bytes_max = 6 * 1024 * 1024,
    .total_body_bytes_max = 5 * 1024 * 1024 + 64 * 1024,
    .file_bytes_max = s3.max_object_bytes,
    .field_bytes_max = 256,
    .parts_max = 4,
    .files_max = 1,
    .part_headers_max = 8,
    .part_header_bytes_max = 4 * 1024,
    .disposition_parameters_max = 8,
    .delimiter_transport_padding_bytes_max = 64,
    .name_bytes_max = 64,
    .filename_bytes_max = 255,
    .boundary_bytes_max = 70,
});

const UploadBody = ploof.Multipart.decode(.{
    ._csrf = ploof.Csrf.multipartField(),
    .file = ploof.Multipart.fileWithPolicy(
        image_sink.ImageSink,
        ploof.Multipart.required,
        ploof.Multipart.claimedMediaTypes(&.{
            "image/png",
            "image/jpeg",
            "image/gif",
            "image/webp",
        }, .reject),
    ),
}, .{ .limits = upload_limits });

pub const UploadDefinition = ploof.Endpoint(.{ .body = UploadBody });
const UploadSpec = @TypeOf(UploadBody);

pub const UploadConsumer = struct {
    pub const State = struct {
        claimed_type: [32]u8 = undefined,
        claimed_len: u8 = 0,
        object_key: [s3.key_bytes_max]u8 = undefined,
        object_key_len: u8 = 0,
    };

    pub fn init(_: UploadConsumer, _: *app_state.Context) State {
        return .{};
    }

    pub fn fileStart(
        _: UploadConsumer,
        context: *app_state.Context,
        state: *State,
        event: UploadSpec.FileStart,
    ) UploadSpec.FileAdmission(app_state.Context.ResponseType) {
        const settings = app_state.config(context) orelse
            return .{ .reject = context.textStatic(.service_unavailable, "Uploads unavailable.") };
        if (settings.rustfs == null) {
            return .{ .reject = context.textStatic(.service_unavailable, "Image storage is not configured.") };
        }
        const principal = (request.principal(context, context.state.allocator orelse
            return .{ .reject = context.empty(.service_unavailable) }) catch
            return .{ .reject = context.empty(.service_unavailable) }) orelse
            return .{ .reject = context.textStatic(.unauthorized, "Sign in to upload images.") };

        _ = principal;
        const metadata = event.file;
        const claimed_media = metadata.claimed_media_type orelse {
            return .{ .reject = context.textStatic(.unsupported_media_type, "Image uploads require a Content-Type.") };
        };
        var type_buf: [32]u8 = undefined;
        const claimed = std.fmt.bufPrint(&type_buf, "{s}/{s}", .{ claimed_media.type, claimed_media.subtype }) catch {
            return .{ .reject = context.empty(.bad_request) };
        };
        const extension = s3.extensionForContentType(claimed) orelse {
            return .{ .reject = context.textStatic(.unsupported_media_type, "Only PNG, JPEG, GIF, and WebP are accepted.") };
        };

        const io = context.state.io orelse
            return .{ .reject = context.empty(.service_unavailable) };
        var raw: [16]u8 = undefined;
        std.Io.random(io, &raw);
        var key_buf: [s3.key_bytes_max]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{
            std.fmt.bytesToHex(raw, .lower),
            extension,
        }) catch return .{ .reject = context.empty(.internal_server_error) };

        @memcpy(state.claimed_type[0..claimed.len], claimed);
        state.claimed_len = @intCast(claimed.len);
        @memcpy(state.object_key[0..key.len], key);
        state.object_key_len = @intCast(key.len);
        return .{ .accept = .{ .file = {} } };
    }

    pub fn complete(
        _: UploadConsumer,
        context: *app_state.Context,
        state: *State,
        _: UploadDefinition.InputType,
        summaries: UploadSpec.Summaries,
    ) ploof.Multipart.Decision(app_state.Context.ResponseType) {
        const settings = app_state.config(context) orelse
            return ploof.Multipart.abort(context.empty(.service_unavailable));
        const rustfs = settings.rustfs orelse
            return ploof.Multipart.abort(context.textStatic(.service_unavailable, "Image storage is not configured."));
        const io = context.state.io orelse
            return ploof.Multipart.abort(context.empty(.service_unavailable));
        const allocator = context.state.allocator orelse
            return ploof.Multipart.abort(context.empty(.service_unavailable));

        const uploads = summaries.file.slice();
        if (uploads.len != 1) {
            return ploof.Multipart.abort(context.textStatic(.bad_request, "Expected one image file."));
        }
        const bytes = uploads[0].bytes;
        const claimed = state.claimed_type[0..state.claimed_len];
        const detected = s3.detectImage(bytes, claimed) orelse {
            return ploof.Multipart.abort(context.textStatic(
                .unsupported_media_type,
                "File contents do not match an allowed image type.",
            ));
        };
        const key = state.object_key[0..state.object_key_len];
        s3.putObject(io, allocator, rustfs.storage(), key, detected.content_type, bytes) catch {
            return ploof.Multipart.abort(context.textStatic(.bad_gateway, "Could not store the image."));
        };

        var json_buf: [768]u8 = undefined;
        const json = std.fmt.bufPrint(
            &json_buf,
            "{{\"url\":\"{s}/media/{s}\",\"content_type\":\"{s}\"}}",
            .{ settings.public_url, key, detected.content_type },
        ) catch return ploof.Multipart.abort(context.empty(.internal_server_error));
        var response = context.bytes(.created, json) catch
            return ploof.Multipart.abort(context.empty(.internal_server_error));
        response.setHeaderStatic("content-type", "application/json; charset=utf-8") catch {};
        response.setHeaderStatic("cache-control", "no-store") catch {};
        return ploof.Multipart.commit(response);
    }
};

/// Streams one object from RustFS. The body lives on the page allocator until join/abort.
pub const MediaProducer = struct {
    bytes: ?[]u8 = null,
    offset: usize = 0,

    pub fn poll(
        self: *MediaProducer,
        output: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        const data = self.bytes orelse return .{ .done = &.{} };
        if (self.offset >= data.len) return .{ .done = &.{} };
        if (output.len == 0) return error.ProducerFailed;
        const remaining = data[self.offset..];
        const used = @min(output.len, remaining.len);
        @memcpy(output[0..used], remaining[0..used]);
        self.offset += used;
        return .{ .progress = used };
    }

    pub fn abort(self: *MediaProducer) void {
        self.clear();
    }

    pub fn join(self: *MediaProducer) void {
        self.clear();
    }

    fn clear(self: *MediaProducer) void {
        if (self.bytes) |buffer| {
            std.heap.page_allocator.free(buffer);
            self.bytes = null;
        }
        self.offset = 0;
    }
};

pub fn serveMedia(
    context: *app_state.Context,
) app_state.Context.StreamResponse(MediaProducer) {
    const unavailable = struct {
        fn call(ctx: *app_state.Context) app_state.Context.StreamResponse(MediaProducer) {
            return ctx.streamExact(
                .service_unavailable,
                ploof.response.media.octet_stream,
                0,
                MediaProducer{},
            );
        }
    }.call;
    const missing = struct {
        fn call(ctx: *app_state.Context) app_state.Context.StreamResponse(MediaProducer) {
            return ctx.streamExact(
                .not_found,
                ploof.response.media.octet_stream,
                0,
                MediaProducer{},
            );
        }
    }.call;

    const settings = app_state.config(context) orelse return unavailable(context);
    const rustfs = settings.rustfs orelse return unavailable(context);
    const key = context.request.param("key") orelse return missing(context);
    s3.validateKey(key) catch return missing(context);

    const io = context.state.io orelse return unavailable(context);
    const allocator = context.state.allocator orelse return unavailable(context);

    const buffer = std.heap.page_allocator.alloc(u8, s3.max_object_bytes) catch
        return unavailable(context);
    errdefer std.heap.page_allocator.free(buffer);

    const fetched = s3.getObject(io, allocator, rustfs.storage(), key, buffer) catch {
        std.heap.page_allocator.free(buffer);
        return missing(context);
    };

    const owned = std.heap.page_allocator.realloc(buffer, fetched.len) catch buffer[0..fetched.len];
    const media_type: ploof.response.MediaType = if (std.ascii.endsWithIgnoreCase(key, ".png"))
        .{ .value = "image/png" }
    else if (std.ascii.endsWithIgnoreCase(key, ".jpg") or std.ascii.endsWithIgnoreCase(key, ".jpeg"))
        .{ .value = "image/jpeg" }
    else if (std.ascii.endsWithIgnoreCase(key, ".gif"))
        .{ .value = "image/gif" }
    else if (std.ascii.endsWithIgnoreCase(key, ".webp"))
        .{ .value = "image/webp" }
    else
        ploof.response.media.octet_stream;

    var response = context.stream(
        .ok,
        media_type,
        ploof.response_stream.exact(owned.len, MediaProducer{ .bytes = owned }),
    ) catch {
        std.heap.page_allocator.free(owned);
        return unavailable(context);
    };
    response.setHeaderStatic("cache-control", "public, max-age=31536000, immutable") catch {};
    return response;
}
