const std = @import("std");
const cors = @import("cors.zig");
const media_type = @import("internal/http1/media_type.zig");
const response = @import("response.zig");
const route = @import("route.zig");
const syntax = @import("internal/http1/syntax.zig");
const static_http = @import("internal/static/http.zig");
const static_media = @import("internal/static/media.zig");
const static_path = @import("internal/static/path.zig");

pub const mount_bytes_hard_max: u16 = 4 * 1024;
pub const root_bytes_hard_max: u16 = 4 * 1024;
pub const path_bytes_hard_max: u16 = 8 * 1024;
pub const index_bytes_hard_max: u16 = 255;
pub const cache_control_bytes_hard_max: u16 = 512;

pub const MediaType = media_type.MediaType;
pub const media_table_version = static_media.table_version;
pub const PathIssue = static_path.Issue;
pub const PathSelection = static_path.Selection;
pub const SelectedPath = static_path.Selected;
pub const StatIdentity = static_http.StatIdentity;
pub const Validators = static_http.Validators;
pub const ValidatorError = static_http.ValidatorError;
pub const Preconditions = static_http.Preconditions;
pub const PreconditionDecision = static_http.PreconditionDecision;
pub const Method = static_http.Method;
pub const Span = static_http.Span;
pub const ContentRange = static_http.ContentRange;
pub const RangeDecision = static_http.RangeDecision;
pub const content_range_bytes_max = static_http.content_range_bytes_max;

pub const RuntimeFile = struct {
    identity: StatIdentity,
    message_epoch_second: i64,
    filename: []const u8,
};

pub const RuntimeResolution = union(enum) {
    file: RuntimeFile,
    not_found,
    redirect_directory,
    unavailable,
    internal_error,
};

pub const LimitIssue = enum(u8) {
    zero,
    mount_above_hard_max,
    root_above_hard_max,
    path_above_hard_max,
    index_above_hard_max,
    cache_control_above_hard_max,
};

pub const Limits = struct {
    mount_bytes_max: u16 = 1024,
    root_bytes_max: u16 = 4 * 1024,
    path_bytes_max: u16 = 4 * 1024,
    index_bytes_max: u16 = 255,
    cache_control_bytes_max: u16 = 256,

    pub fn issue(limits: Limits) ?LimitIssue {
        if (limits.mount_bytes_max == 0 or limits.root_bytes_max == 0 or
            limits.path_bytes_max == 0 or limits.index_bytes_max == 0 or
            limits.cache_control_bytes_max == 0) return .zero;
        if (limits.mount_bytes_max > mount_bytes_hard_max) return .mount_above_hard_max;
        if (limits.root_bytes_max > root_bytes_hard_max) return .root_above_hard_max;
        if (limits.path_bytes_max > path_bytes_hard_max) return .path_above_hard_max;
        if (limits.index_bytes_max > index_bytes_hard_max) return .index_above_hard_max;
        if (limits.cache_control_bytes_max > cache_control_bytes_hard_max) {
            return .cache_control_above_hard_max;
        }
        return null;
    }

    pub fn validate(comptime limits: Limits) Limits {
        if (limits.issue() != null) @compileError("PLOOF-E4101 invalid static-file limits");
        return limits;
    }
};

pub const standard_limits = Limits.validate(.{});

pub const DirOptions = struct {
    index: ?[]const u8 = "index.html",
    cache_control: []const u8 = "no-cache",
    limits: Limits = standard_limits,
};

pub const FileOptions = struct {
    cache_control: []const u8 = "no-cache",
    media_type: ?MediaType = null,
    limits: Limits = standard_limits,
};

pub fn StaticDirDescriptor(comptime Middleware: type) type {
    return struct {
        kind: route.DescriptorKind = .static_dir,
        mount_path: []const u8,
        root_path: []const u8,
        index_name: ?[]const u8,
        cache_control: []const u8,
        limits_profile: Limits,
        middleware: Middleware,
        response_head_limits: ?response.HeadLimits,
        cors_policy: ?cors.Policy = null,

        pub fn selectPath(
            self: @This(),
            raw_suffix: []const u8,
            decoded_suffix: []const u8,
        ) PathSelection {
            return static_path.select(
                raw_suffix,
                decoded_suffix,
                self.limits_profile.path_bytes_max,
            );
        }

        pub fn mount(self: @This()) []const u8 {
            return self.mount_path;
        }

        pub fn root(self: @This()) []const u8 {
            return self.root_path;
        }

        pub fn index(self: @This()) ?[]const u8 {
            return self.index_name;
        }

        pub fn cacheControl(self: @This()) []const u8 {
            return self.cache_control;
        }

        pub fn limits(self: @This()) Limits {
            return self.limits_profile;
        }

        pub fn withCors(self: @This(), comptime policy: cors.Policy) @This() {
            var result = self;
            result.cors_policy = cors.validate(policy);
            return result;
        }
    };
}

pub const StaticDir = struct {
    pub fn init(
        comptime mount_path: []const u8,
        comptime root_path: []const u8,
        comptime options: DirOptions,
    ) StaticDirDescriptor(@TypeOf(.{})) {
        return configured(mount_path, root_path, options, .{}, null);
    }

    pub fn configured(
        comptime mount_path: []const u8,
        comptime root_path: []const u8,
        comptime options: DirOptions,
        comptime middleware: anytype,
        comptime response_head_limits: ?response.HeadLimits,
    ) StaticDirDescriptor(@TypeOf(middleware)) {
        const profile = options.limits.validate();
        validateMount(mount_path, profile.mount_bytes_max, true);
        validateRoot(root_path, profile.root_bytes_max);
        if (options.index) |index_name| {
            if (static_path.configuredIndexIssue(index_name, profile.index_bytes_max) != null) {
                @compileError("PLOOF-E4104 invalid static-directory index");
            }
        }
        validateCache(options.cache_control, profile.cache_control_bytes_max);
        return .{
            .mount_path = mount_path,
            .root_path = root_path,
            .index_name = options.index,
            .cache_control = options.cache_control,
            .limits_profile = profile,
            .middleware = middleware,
            .response_head_limits = response_head_limits,
        };
    }
};

pub fn StaticFileDescriptor(comptime Middleware: type) type {
    return struct {
        kind: route.DescriptorKind = .static_file,
        url_path: []const u8,
        root_path: []const u8,
        relative_path: []const u8,
        cache_control: []const u8,
        media_type: MediaType,
        limits_profile: Limits,
        middleware: Middleware,
        response_head_limits: ?response.HeadLimits,
        cors_policy: ?cors.Policy = null,

        pub fn path(self: @This()) []const u8 {
            return self.url_path;
        }

        pub fn root(self: @This()) []const u8 {
            return self.root_path;
        }

        pub fn relativePath(self: @This()) []const u8 {
            return self.relative_path;
        }

        pub fn cacheControl(self: @This()) []const u8 {
            return self.cache_control;
        }

        pub fn mediaType(self: @This()) MediaType {
            return self.media_type;
        }

        pub fn limits(self: @This()) Limits {
            return self.limits_profile;
        }

        pub fn withCors(self: @This(), comptime policy: cors.Policy) @This() {
            var result = self;
            result.cors_policy = cors.validate(policy);
            return result;
        }
    };
}

pub const StaticFile = struct {
    pub fn init(
        comptime url_path: []const u8,
        comptime root_path: []const u8,
        comptime relative_path: []const u8,
        comptime options: FileOptions,
    ) StaticFileDescriptor(@TypeOf(.{})) {
        return configured(url_path, root_path, relative_path, options, .{}, null);
    }

    pub fn configured(
        comptime url_path: []const u8,
        comptime root_path: []const u8,
        comptime relative_path: []const u8,
        comptime options: FileOptions,
        comptime middleware: anytype,
        comptime response_head_limits: ?response.HeadLimits,
    ) StaticFileDescriptor(@TypeOf(middleware)) {
        const profile = options.limits.validate();
        validateMount(url_path, profile.mount_bytes_max, false);
        validateRoot(root_path, profile.root_bytes_max);
        if (static_path.configuredRelativeIssue(relative_path, profile.path_bytes_max) != null) {
            @compileError("PLOOF-E4106 invalid static-file relative path");
        }
        validateCache(options.cache_control, profile.cache_control_bytes_max);
        return .{
            .url_path = url_path,
            .root_path = root_path,
            .relative_path = relative_path,
            .cache_control = options.cache_control,
            .media_type = options.media_type orelse mediaForFilename(relative_path),
            .limits_profile = profile,
            .middleware = middleware,
            .response_head_limits = response_head_limits,
        };
    }
};

pub fn mediaForFilename(filename: []const u8) MediaType {
    return static_media.forFilename(filename);
}

pub const evaluateRequestPreconditions = static_http.evaluateRequestPreconditions;
pub const evaluateRequestRange = static_http.evaluateRequestRange;
pub const referenceYear = static_http.referenceYear;

pub fn buildValidators(
    identity: StatIdentity,
    message_epoch_second: i64,
) ValidatorError!Validators {
    return Validators.init(identity, message_epoch_second);
}

pub fn evaluatePreconditions(
    validators: *const Validators,
    fields: Preconditions,
    reference_year: u16,
) PreconditionDecision {
    return static_http.evaluatePreconditions(validators, fields, reference_year);
}

pub fn evaluateRange(
    method: Method,
    validators: *const Validators,
    range: ?[]const u8,
    if_range: ?[]const u8,
) RangeDecision {
    return static_http.evaluateRange(method, validators, range, if_range);
}

fn validateMount(comptime path: []const u8, comptime bytes_max: u16, comptime dir: bool) void {
    if (path.len == 0 or path.len > bytes_max or path[0] != '/' or
        (!dir and path.len == 1) or (path.len > 1 and path[path.len - 1] == '/'))
    {
        @compileError("PLOOF-E4102 invalid static URL mount");
    }
    var component_start: usize = 1;
    for (path, 0..) |byte, index| {
        if (byte == 0 or byte == '\\' or byte == '?' or byte == '#' or
            (byte != '/' and !syntax.isUriPchar(byte)))
        {
            @compileError("PLOOF-E4102 invalid static URL mount");
        }
        if (index != component_start) continue;
        if (byte == '/' or byte == ':' or byte == '*') {
            @compileError("PLOOF-E4102 invalid static URL mount");
        }
        component_start = std.mem.indexOfScalarPos(u8, path, index, '/') orelse path.len;
        component_start += @intFromBool(component_start < path.len);
    }
}

fn validateRoot(comptime root: []const u8, comptime bytes_max: u16) void {
    if (root.len == 0 or root.len > bytes_max or std.mem.indexOfScalar(u8, root, 0) != null) {
        @compileError("PLOOF-E4103 invalid static filesystem root");
    }
}

fn validateCache(comptime value: []const u8, comptime bytes_max: u16) void {
    if (value.len == 0 or value.len > bytes_max or !syntax.isFieldValue(value) or
        syntax.trimOws(value).len != value.len or !validCacheControl(value))
    {
        @compileError("PLOOF-E4105 invalid static Cache-Control policy");
    }
}

fn validCacheControl(value: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < value.len) {
        if (!consumeToken(value, &cursor)) return false;
        if (cursor < value.len and value[cursor] == '=') {
            cursor += 1;
            if (cursor == value.len) return false;
            if (value[cursor] == '"') {
                if (!consumeQuoted(value, &cursor)) return false;
            } else if (!consumeToken(value, &cursor)) return false;
        }
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) {
            cursor += 1;
        }
        if (cursor == value.len) return true;
        if (value[cursor] != ',') return false;
        cursor += 1;
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) {
            cursor += 1;
        }
        if (cursor == value.len) return false;
    }
    return false;
}

fn consumeToken(value: []const u8, cursor: *usize) bool {
    const start = cursor.*;
    while (cursor.* < value.len and syntax.isTokenByte(value[cursor.*])) cursor.* += 1;
    return cursor.* != start;
}

fn consumeQuoted(value: []const u8, cursor: *usize) bool {
    std.debug.assert(value[cursor.*] == '"');
    cursor.* += 1;
    while (cursor.* < value.len) {
        const byte = value[cursor.*];
        cursor.* += 1;
        if (byte == '"') return true;
        if (byte == '\\') {
            if (cursor.* == value.len or !syntax.isFieldValueByte(value[cursor.*])) return false;
            cursor.* += 1;
        } else if ((byte != '\t' and byte < 0x20) or byte == 0x7f) return false;
    }
    return false;
}

test "static declarations retain exact finite policy" {
    const directory = comptime StaticDir.init("/public", "./web", .{});
    try std.testing.expectEqualStrings("/public", directory.mount());
    try std.testing.expectEqualStrings("index.html", directory.index().?);
    try std.testing.expectEqualStrings("no-cache", directory.cacheControl());
    try std.testing.expectEqualStrings("css/site.css", directory.selectPath(
        "/css/site.css",
        "/css/site.css",
    ).selected.relative_path);

    const file = comptime StaticFile.init("/robots.txt", ".", "robots.txt", .{});
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", file.mediaType().bytes());

    const cached = comptime StaticFile.init("/bundle.js", ".", "bundle.js", .{
        .cache_control = "public, max-age=60, private=\"field, other\"",
    });
    try std.testing.expectEqualStrings(
        "public, max-age=60, private=\"field, other\"",
        cached.cacheControl(),
    );
}

test "static declaration options cover root mount disabled index and explicit media" {
    const directory = comptime StaticDir.init("/", "relative/root", .{ .index = null });
    try std.testing.expectEqualStrings("/", directory.mount());
    try std.testing.expectEqualStrings("relative/root", directory.root());
    try std.testing.expectEqual(@as(?[]const u8, null), directory.index());

    const file = comptime StaticFile.init("/feed", ".", "feed.data", .{
        .media_type = media_type.parseComptime("application/atom+xml"),
    });
    try std.testing.expectEqualStrings("/feed", file.path());
    try std.testing.expectEqualStrings("feed.data", file.relativePath());
    try std.testing.expectEqualStrings("application/atom+xml", file.mediaType().bytes());
}

test "static limits report every hard boundary" {
    try std.testing.expectEqual(LimitIssue.zero, (Limits{ .mount_bytes_max = 0 }).issue().?);
    try std.testing.expectEqual(
        LimitIssue.mount_above_hard_max,
        (Limits{ .mount_bytes_max = mount_bytes_hard_max + 1 }).issue().?,
    );
    try std.testing.expectEqual(
        LimitIssue.root_above_hard_max,
        (Limits{ .root_bytes_max = root_bytes_hard_max + 1 }).issue().?,
    );
    try std.testing.expectEqual(
        LimitIssue.path_above_hard_max,
        (Limits{ .path_bytes_max = path_bytes_hard_max + 1 }).issue().?,
    );
    try std.testing.expectEqual(
        LimitIssue.index_above_hard_max,
        (Limits{ .index_bytes_max = index_bytes_hard_max + 1 }).issue().?,
    );
    try std.testing.expectEqual(
        LimitIssue.cache_control_above_hard_max,
        (Limits{ .cache_control_bytes_max = cache_control_bytes_hard_max + 1 }).issue().?,
    );
}
