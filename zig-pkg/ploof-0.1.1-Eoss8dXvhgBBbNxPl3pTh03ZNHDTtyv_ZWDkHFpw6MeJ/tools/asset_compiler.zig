const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

pub const assets_default_max: u16 = 256;
pub const assets_hard_max: u16 = 4096;
pub const input_bytes_default_max: u64 = 64 * 1024 * 1024;
pub const input_bytes_hard_max: u64 = 1024 * 1024 * 1024;
pub const generated_bytes_default_max: u64 = 512 * 1024 * 1024;
pub const generated_bytes_hard_max: u64 = 4 * 1024 * 1024 * 1024;
pub const logical_name_bytes_max: u8 = 128;
pub const route_prefix_bytes_max: u8 = 128;
pub const gzip_bytes_min: u64 = 1024;
pub const gzip_bytes_max: u64 = 4 * 1024 * 1024;

pub const Error = error{
    Usage,
    UnknownArgument,
    MissingArgument,
    DuplicateOption,
    InvalidLimit,
    LimitAboveHardMaximum,
    InvalidRoutePrefix,
    AssetCountExceeded,
    InvalidLogicalName,
    DuplicateLogicalName,
    InvalidMediaKind,
    InputReadFailed,
    InputBytesExceeded,
    DigestCollision,
    GeneratedBytesExceeded,
    OutputWriteFailed,
    CompressionFailed,
    OutOfMemory,
};

const MediaKind = enum(u8) {
    css,
    javascript,
    json,
    svg,
    text,
    html,
    xml,
    png,
    jpeg,
    gif,
    webp,
    avif,
    ico,
    woff,
    woff2,
    ttf,
    otf,
    wasm,
    binary,
};

const MediaPolicy = struct {
    media_type: []const u8,
    compressible: bool,
};

const InputSpec = struct {
    logical_name: []const u8,
    media_kind: MediaKind,
    path: []const u8,
};

const Asset = struct {
    logical_name: []const u8,
    media_kind: MediaKind,
    identity: []u8,
    identity_digest: Digest,
    gzip_storage: ?[]u8,
    gzip_length: usize,
    gzip_digest: Digest,

    fn gzipBytes(asset: *const Asset) ?[]const u8 {
        const storage = asset.gzip_storage orelse return null;
        std.debug.assert(asset.gzip_length <= storage.len);
        return storage[0..asset.gzip_length];
    }

    fn deinit(asset: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(asset.identity);
        if (asset.gzip_storage) |storage| allocator.free(storage);
        asset.* = undefined;
    }
};

const Options = struct {
    output_path: []const u8,
    route_prefix: []const u8,
    assets_max: u16,
    input_bytes_max: u64,
    generated_bytes_max: u64,
    inputs: []InputSpec,
};

const ParseState = struct {
    output_path: ?[]const u8 = null,
    route_prefix: ?[]const u8 = null,
    assets_max: ?u64 = null,
    input_bytes_max: ?u64 = null,
    generated_bytes_max: ?u64 = null,
    inputs: std.ArrayList(InputSpec) = .empty,
};

const GzipWorkspace = struct {
    compressor: std.compress.flate.Compress = undefined,
    history: [std.compress.flate.max_window_len]u8 = undefined,
};

pub fn run(init: std.process.Init) Error!void {
    var arguments = std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    ) catch return error.OutOfMemory;
    defer arguments.deinit();
    _ = arguments.next();

    var state = ParseState{};
    defer state.inputs.deinit(init.gpa);
    try parseArguments(init.gpa, &arguments, &state);
    const options = try finishOptions(&state);
    try validateInputs(options.inputs);

    var assets: std.ArrayList(Asset) = .empty;
    defer deinitAssets(init.gpa, &assets);
    try loadAssets(init, &options, &assets);
    try rejectDigestCollisions(assets.items);
    try writeGenerated(init, &options, assets.items);
}

fn parseArguments(
    allocator: std.mem.Allocator,
    arguments: *std.process.Args.Iterator,
    state: *ParseState,
) Error!void {
    var count: u16 = 0;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--output")) {
            try setString(arguments, &state.output_path);
        } else if (std.mem.eql(u8, argument, "--prefix")) {
            try setString(arguments, &state.route_prefix);
        } else if (std.mem.eql(u8, argument, "--assets-max")) {
            try setLimit(u64, arguments, &state.assets_max);
        } else if (std.mem.eql(u8, argument, "--input-bytes-max")) {
            try setLimit(u64, arguments, &state.input_bytes_max);
        } else if (std.mem.eql(u8, argument, "--generated-bytes-max")) {
            try setLimit(u64, arguments, &state.generated_bytes_max);
        } else if (std.mem.eql(u8, argument, "--asset")) {
            if (count == assets_hard_max) return error.AssetCountExceeded;
            count += 1;
            try appendInput(allocator, arguments, &state.inputs);
        } else {
            return error.UnknownArgument;
        }
    }
}

fn setString(
    arguments: *std.process.Args.Iterator,
    target: *?[]const u8,
) Error!void {
    if (target.* != null) return error.DuplicateOption;
    target.* = arguments.next() orelse return error.MissingArgument;
}

fn setLimit(
    comptime T: type,
    arguments: *std.process.Args.Iterator,
    target: *?T,
) Error!void {
    if (target.* != null) return error.DuplicateOption;
    const raw = arguments.next() orelse return error.MissingArgument;
    const value = std.fmt.parseInt(T, raw, 10) catch return error.InvalidLimit;
    if (value == 0) return error.InvalidLimit;
    target.* = value;
}

fn appendInput(
    allocator: std.mem.Allocator,
    arguments: *std.process.Args.Iterator,
    inputs: *std.ArrayList(InputSpec),
) Error!void {
    const name = arguments.next() orelse return error.MissingArgument;
    const raw_kind = arguments.next() orelse return error.MissingArgument;
    const path = arguments.next() orelse return error.MissingArgument;
    const kind = std.meta.stringToEnum(MediaKind, raw_kind) orelse {
        return error.InvalidMediaKind;
    };
    inputs.append(allocator, .{
        .logical_name = name,
        .media_kind = kind,
        .path = path,
    }) catch return error.OutOfMemory;
}

fn finishOptions(state: *const ParseState) Error!Options {
    const output = state.output_path orelse return error.Usage;
    const prefix = state.route_prefix orelse "/assets/";
    const assets_max_raw = state.assets_max orelse assets_default_max;
    const input_max = state.input_bytes_max orelse input_bytes_default_max;
    const generated_max = state.generated_bytes_max orelse generated_bytes_default_max;
    if (assets_max_raw > assets_hard_max) return error.LimitAboveHardMaximum;
    if (input_max > input_bytes_hard_max) return error.LimitAboveHardMaximum;
    if (generated_max > generated_bytes_hard_max) return error.LimitAboveHardMaximum;
    if (!validRoutePrefix(prefix)) return error.InvalidRoutePrefix;
    if (state.inputs.items.len == 0) return error.Usage;
    if (state.inputs.items.len > assets_max_raw) return error.AssetCountExceeded;
    const assets_max: u16 = @intCast(assets_max_raw);
    return .{
        .output_path = output,
        .route_prefix = prefix,
        .assets_max = assets_max,
        .input_bytes_max = input_max,
        .generated_bytes_max = generated_max,
        .inputs = state.inputs.items,
    };
}

fn validRoutePrefix(prefix: []const u8) bool {
    if (prefix.len == 0 or prefix.len > route_prefix_bytes_max) return false;
    if (prefix[0] != '/' or prefix[prefix.len - 1] != '/') return false;
    if (prefix.len == 1) return true;
    var segment_bytes: u8 = 0;
    for (prefix[1..]) |byte| {
        if (byte == '/') {
            if (segment_bytes == 0) return false;
            segment_bytes = 0;
        } else if (isPrefixByte(byte)) {
            segment_bytes += 1;
        } else {
            return false;
        }
    }
    return segment_bytes == 0;
}

fn isPrefixByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= '0' and byte <= '9') or byte == '-' or byte == '_';
}

fn validLogicalName(name: []const u8) bool {
    if (name.len == 0 or name.len > logical_name_bytes_max) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '.' or byte == '_' or byte == '-';
        if (!valid) return false;
    }
    return true;
}

fn loadAssets(
    init: std.process.Init,
    options: *const Options,
    assets: *std.ArrayList(Asset),
) Error!void {
    var input_bytes: u64 = 0;
    var gzip_workspace: GzipWorkspace = undefined;
    for (options.inputs) |input| {
        var asset = try loadAsset(
            init,
            input,
            options.input_bytes_max,
            &input_bytes,
            &gzip_workspace,
        );
        errdefer asset.deinit(init.gpa);
        assets.append(init.gpa, asset) catch return error.OutOfMemory;
    }
    std.debug.assert(assets.items.len <= options.assets_max);
    std.debug.assert(input_bytes <= options.input_bytes_max);
}

fn loadAsset(
    init: std.process.Init,
    input: InputSpec,
    input_bytes_max: u64,
    input_bytes: *u64,
    gzip_workspace: *GzipWorkspace,
) Error!Asset {
    std.debug.assert(input_bytes.* <= input_bytes_max);
    const file = openInput(init.io, input.path) catch return error.InputReadFailed;
    defer file.close(init.io);
    const stat = file.stat(init.io) catch return error.InputReadFailed;
    if (stat.kind != .file) return error.InputReadFailed;
    if (stat.size > input_bytes_max - input_bytes.*) return error.InputBytesExceeded;
    const length: usize = std.math.cast(usize, stat.size) orelse {
        return error.InputBytesExceeded;
    };
    const identity = init.gpa.alloc(u8, length) catch return error.OutOfMemory;
    errdefer init.gpa.free(identity);
    const read = file.readPositionalAll(init.io, identity, 0) catch {
        return error.InputReadFailed;
    };
    if (read != identity.len) return error.InputReadFailed;
    var extra: [1]u8 = undefined;
    const extra_read = file.readPositionalAll(init.io, &extra, stat.size) catch {
        return error.InputReadFailed;
    };
    if (extra_read != 0) return error.InputReadFailed;
    input_bytes.* += stat.size;

    var result = Asset{
        .logical_name = input.logical_name,
        .media_kind = input.media_kind,
        .identity = identity,
        .identity_digest = undefined,
        .gzip_storage = null,
        .gzip_length = 0,
        .gzip_digest = @splat(0),
    };
    Sha256.hash(identity, &result.identity_digest, .{});
    try compressAsset(init.gpa, &result, gzip_workspace);
    return result;
}

fn openInput(io: std.Io, path: []const u8) !std.Io.File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{});
}

fn compressAsset(
    allocator: std.mem.Allocator,
    asset: *Asset,
    workspace: *GzipWorkspace,
) Error!void {
    const length: u64 = asset.identity.len;
    if (!gzipEligible(asset.media_kind, length)) return;
    const bound = gzipBound(asset.identity.len) catch return error.CompressionFailed;
    const storage = allocator.alloc(u8, bound) catch return error.OutOfMemory;
    errdefer allocator.free(storage);
    const bytes = gzipCompress(workspace, asset.identity, storage) catch {
        return error.CompressionFailed;
    };
    asset.gzip_storage = storage;
    asset.gzip_length = bytes.len;
    Sha256.hash(bytes, &asset.gzip_digest, .{});
}

fn gzipEligible(kind: MediaKind, length: u64) bool {
    return mediaPolicy(kind).compressible and
        length >= gzip_bytes_min and length <= gzip_bytes_max;
}

fn gzipBound(input_length: usize) !usize {
    const blocks = if (input_length == 0) 1 else (input_length - 1) / 32_768 + 1;
    const input_bits = try std.math.mul(usize, input_length, 9);
    const block_bits = try std.math.mul(usize, blocks, 10);
    const bits = try std.math.add(usize, input_bits, block_bits);
    const rounded_bits = try std.math.add(usize, bits, 7);
    return std.math.add(usize, rounded_bits / 8, 18);
}

fn gzipCompress(
    workspace: *GzipWorkspace,
    input: []const u8,
    output: []u8,
) ![]u8 {
    var writer = std.Io.Writer.fixed(output);
    workspace.compressor = try std.compress.flate.Compress.init(
        &writer,
        &workspace.history,
        .gzip,
        .best,
    );
    try workspace.compressor.writer.writeAll(input);
    try workspace.compressor.finish();
    const bytes = output[0..writer.end];
    if (bytes.len < 18) return error.InvalidGzip;
    @memset(bytes[4..8], 0);
    bytes[9] = 255;
    return bytes;
}

fn mediaPolicy(kind: MediaKind) MediaPolicy {
    return switch (kind) {
        .css => .{ .media_type = "text/css; charset=utf-8", .compressible = true },
        .javascript => .{ .media_type = "text/javascript; charset=utf-8", .compressible = true },
        .json => .{ .media_type = "application/json; charset=utf-8", .compressible = true },
        .svg => .{ .media_type = "image/svg+xml", .compressible = true },
        .text => .{ .media_type = "text/plain; charset=utf-8", .compressible = true },
        .html => .{ .media_type = "text/html; charset=utf-8", .compressible = true },
        .xml => .{ .media_type = "application/xml", .compressible = true },
        .png => .{ .media_type = "image/png", .compressible = false },
        .jpeg => .{ .media_type = "image/jpeg", .compressible = false },
        .gif => .{ .media_type = "image/gif", .compressible = false },
        .webp => .{ .media_type = "image/webp", .compressible = false },
        .avif => .{ .media_type = "image/avif", .compressible = false },
        .ico => .{ .media_type = "image/x-icon", .compressible = false },
        .woff => .{ .media_type = "font/woff", .compressible = false },
        .woff2 => .{ .media_type = "font/woff2", .compressible = false },
        .ttf => .{ .media_type = "font/ttf", .compressible = false },
        .otf => .{ .media_type = "font/otf", .compressible = false },
        .wasm => .{ .media_type = "application/wasm", .compressible = false },
        .binary => .{ .media_type = "application/octet-stream", .compressible = false },
    };
}

fn deinitAssets(allocator: std.mem.Allocator, assets: *std.ArrayList(Asset)) void {
    for (assets.items) |*asset| asset.deinit(allocator);
    assets.deinit(allocator);
}

fn validateInputs(inputs: []InputSpec) Error!void {
    std.debug.assert(inputs.len > 0);
    for (inputs) |input| {
        if (!validLogicalName(input.logical_name)) return error.InvalidLogicalName;
    }
    std.mem.sortUnstable(InputSpec, inputs, {}, struct {
        fn lessThan(_: void, left: InputSpec, right: InputSpec) bool {
            return std.mem.order(u8, left.logical_name, right.logical_name) == .lt;
        }
    }.lessThan);
    for (inputs[1..], 1..) |input, index| {
        if (std.mem.eql(u8, inputs[index - 1].logical_name, input.logical_name)) {
            return error.DuplicateLogicalName;
        }
    }
}

fn rejectDigestCollisions(assets: []const Asset) Error!void {
    for (assets, 0..) |left, left_index| {
        for (assets[left_index + 1 ..]) |right| {
            if (digestsConflict(left.identity_digest, right.identity_digest)) {
                return error.DigestCollision;
            }
        }
    }
}

fn digestsConflict(left: Digest, right: Digest) bool {
    const same_prefix = std.mem.eql(u8, left[0..16], right[0..16]);
    const same_full = std.mem.eql(u8, &left, &right);
    return same_prefix and !same_full;
}

fn writeGenerated(
    init: std.process.Init,
    options: *const Options,
    assets: []const Asset,
) Error!void {
    var count_buffer: [4096]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&count_buffer);
    writeModule(&counter.writer, options.route_prefix, assets) catch {
        return error.OutputWriteFailed;
    };
    if (counter.fullCount() > options.generated_bytes_max) {
        return error.GeneratedBytesExceeded;
    }

    const file = createOutput(init.io, options.output_path) catch {
        return error.OutputWriteFailed;
    };
    defer file.close(init.io);
    var write_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(init.io, &write_buffer);
    writeModule(&file_writer.interface, options.route_prefix, assets) catch {
        return error.OutputWriteFailed;
    };
    file_writer.flush() catch return error.OutputWriteFailed;
}

fn createOutput(io: std.Io, path: []const u8) !std.Io.File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().createFile(io, path, .{});
}

fn writeModule(
    writer: *std.Io.Writer,
    route_prefix: []const u8,
    assets: []const Asset,
) !void {
    try writer.writeAll(generated_header);
    inline for (std.meta.fields(MediaKind)) |field| {
        try writer.print("    {s},\n", .{field.name});
    }
    try writer.writeAll("};\n\n" ++ generated_types);
    try writer.writeAll("pub const route_prefix =\n");
    try writeAsciiChunks(writer, route_prefix);
    for (assets, 0..) |*asset, index| {
        try writer.print("const asset_{d}_name =\n", .{index});
        try writeAsciiChunks(writer, asset.logical_name);
        try writeBytesDeclaration(writer, "identity", index, asset.identity);
        if (asset.gzipBytes()) |gzip| {
            try writeBytesDeclaration(writer, "gzip", index, gzip);
        }
    }
    try writer.writeAll("pub const assets = [_]Asset{\n");
    for (assets, 0..) |*asset, index| {
        try writeAsset(writer, asset, index);
    }
    try writer.writeAll("};\n");
}

const generated_header =
    "// Generated by ploof-assets. Do not edit.\n" ++
    "pub const format_version: u16 = 1;\n\n" ++
    "pub const MediaKind = enum(u8) {\n";

const generated_types =
    "pub const Representation = struct {\n" ++
    "    bytes: []const u8,\n" ++
    "    digest: [32]u8,\n" ++
    "    etag: []const u8,\n" ++
    "};\n\n" ++
    "pub const Asset = struct {\n" ++
    "    logical_name: []const u8,\n" ++
    "    path: []const u8,\n" ++
    "    media_kind: MediaKind,\n" ++
    "    media_type: []const u8,\n" ++
    "    identity: Representation,\n" ++
    "    gzip: ?Representation,\n" ++
    "};\n\n";

fn writeBytesDeclaration(
    writer: *std.Io.Writer,
    comptime representation: []const u8,
    index: usize,
    bytes: []const u8,
) !void {
    try writer.print("const asset_{d}_{s} =\n", .{ index, representation });
    if (bytes.len == 0) {
        try writer.writeAll("    \"\";\n\n");
        return;
    }
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 20, bytes.len);
        try writer.writeAll("    \"");
        for (bytes[offset..end]) |byte| try writer.print("\\x{x:0>2}", .{byte});
        try writer.writeAll(if (end == bytes.len) "\";\n\n" else "\" ++\n");
        offset = end;
    }
}

fn writeAsset(
    writer: *std.Io.Writer,
    asset: *const Asset,
    index: usize,
) !void {
    const policy = mediaPolicy(asset.media_kind);
    try writer.writeAll("    .{\n");
    try writer.print("        .logical_name = asset_{d}_name,\n", .{index});
    try writer.writeAll("        .path = route_prefix ++ \"");
    try writer.print("{s}/\" ++ asset_{d}_name,\n", .{
        assetPathPrefix(asset.identity_digest),
        index,
    });
    try writer.print("        .media_kind = .{s},\n", .{@tagName(asset.media_kind)});
    try writer.print("        .media_type = \"{s}\",\n", .{policy.media_type});
    try writeRepresentation(writer, asset.identity_digest, "identity", index, false);
    if (asset.gzipBytes() != null) {
        try writeRepresentation(writer, asset.gzip_digest, "gzip", index, true);
    } else {
        try writer.writeAll("        .gzip = null,\n");
    }
    try writer.writeAll("    },\n");
}

fn writeAsciiChunks(writer: *std.Io.Writer, bytes: []const u8) !void {
    std.debug.assert(bytes.len > 0);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 72, bytes.len);
        try writer.print("    \"{s}\"", .{bytes[offset..end]});
        try writer.writeAll(if (end == bytes.len) ";\n\n" else " ++\n");
        offset = end;
    }
}

fn writeRepresentation(
    writer: *std.Io.Writer,
    digest: Digest,
    comptime representation: []const u8,
    index: usize,
    comptime optional: bool,
) !void {
    const field = if (optional) "gzip" else "identity";
    try writer.print("        .{s} = .{{\n", .{field});
    try writer.print("            .bytes = asset_{d}_{s},\n", .{ index, representation });
    try writer.writeAll("            .digest = .{");
    try writeDigestBytes(writer, digest);
    try writer.writeAll("            },\n            .etag = \"\\\"");
    try writer.print("{x}", .{digest});
    try writer.writeAll("\\\"\",\n        },\n");
}

fn writeDigestBytes(writer: *std.Io.Writer, digest: Digest) !void {
    for (digest, 0..) |byte, index| {
        if (index % 8 == 0) try writer.writeAll("\n                ");
        try writer.print("0x{x:0>2},", .{byte});
        if ((index + 1) % 8 != 0) try writer.writeByte(' ');
    }
    try writer.writeByte('\n');
}

fn assetPathPrefix(digest: Digest) [32]u8 {
    var result: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest[0..16]}) catch unreachable;
    return result;
}

pub fn diagnostic(err: Error) []const u8 {
    return switch (err) {
        error.Usage => usage,
        error.UnknownArgument => "PLOOF-E5002 unknown asset compiler argument\n",
        error.MissingArgument => "PLOOF-E5003 asset compiler argument is missing a value\n",
        error.DuplicateOption => "PLOOF-E5004 asset compiler option appears more than once\n",
        error.InvalidLimit => "PLOOF-E5005 asset compiler limit must be a positive integer\n",
        error.LimitAboveHardMaximum => "PLOOF-E5006 asset compiler limit exceeds hard maximum\n",
        error.InvalidRoutePrefix => "PLOOF-E5007 invalid asset route prefix\n",
        error.AssetCountExceeded => "PLOOF-E5008 embedded asset count exceeds configured limit\n",
        error.InvalidLogicalName => "PLOOF-E5009 invalid embedded asset logical name\n",
        error.DuplicateLogicalName => "PLOOF-E5010 duplicate embedded asset logical name\n",
        error.InvalidMediaKind => "PLOOF-E5011 invalid embedded asset media kind\n",
        error.InputReadFailed => "PLOOF-E5012 embedded asset input cannot be read as a file\n",
        error.InputBytesExceeded => "PLOOF-E5013 embedded asset bytes exceed configured limit\n",
        error.DigestCollision => "PLOOF-E5014 embedded asset SHA-256 prefix collision\n",
        error.GeneratedBytesExceeded => "PLOOF-E5015 generated module exceeds configured limit\n",
        error.OutputWriteFailed => "PLOOF-E5016 generated asset module cannot be written\n",
        error.CompressionFailed => "PLOOF-E5017 embedded asset gzip compression failed\n",
        error.OutOfMemory => "PLOOF-E5018 asset compiler exhausted host memory\n",
    };
}

pub fn exitStatus(err: Error) u8 {
    return switch (err) {
        error.Usage,
        error.UnknownArgument,
        error.MissingArgument,
        error.DuplicateOption,
        error.InvalidLimit,
        error.LimitAboveHardMaximum,
        error.InvalidRoutePrefix,
        error.AssetCountExceeded,
        error.InvalidLogicalName,
        error.DuplicateLogicalName,
        error.InvalidMediaKind,
        => 2,
        error.InputReadFailed, error.InputBytesExceeded, error.DigestCollision => 3,
        error.GeneratedBytesExceeded,
        error.OutputWriteFailed,
        error.CompressionFailed,
        error.OutOfMemory,
        => 4,
    };
}

const usage =
    "PLOOF-E5001 usage: ploof-assets --output <generated.zig> " ++
    "[--prefix /assets/] [--assets-max N] [--input-bytes-max N] " ++
    "[--generated-bytes-max N] --asset <logical-name> <media-kind> <path>...\n";

test "logical names and route prefixes use bounded public path grammar" {
    try std.testing.expect(validLogicalName("app.min.css"));
    try std.testing.expect(validLogicalName("logo_2x-dark.svg"));
    try std.testing.expect(!validLogicalName("App.css"));
    try std.testing.expect(!validLogicalName("../app.css"));
    try std.testing.expect(!validLogicalName("."));
    try std.testing.expect(validRoutePrefix("/"));
    try std.testing.expect(validRoutePrefix("/static/assets/"));
    try std.testing.expect(!validRoutePrefix("assets/"));
    try std.testing.expect(!validRoutePrefix("/assets//v1/"));
}

test "media table fixes declared types and gzip size policy" {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mediaPolicy(.css).media_type);
    try std.testing.expect(mediaPolicy(.css).compressible);
    try std.testing.expect(mediaPolicy(.svg).compressible);
    try std.testing.expect(!mediaPolicy(.png).compressible);
    try std.testing.expect(!mediaPolicy(.woff2).compressible);
    try std.testing.expect(!gzipEligible(.css, gzip_bytes_min - 1));
    try std.testing.expect(gzipEligible(.css, gzip_bytes_min));
    try std.testing.expect(gzipEligible(.css, gzip_bytes_max));
    try std.testing.expect(!gzipEligible(.css, gzip_bytes_max + 1));
    try std.testing.expect(!gzipEligible(.png, gzip_bytes_min));
}

test "SHA-256 identity and first 128-bit path are stable" {
    var digest: Digest = undefined;
    Sha256.hash("abc", &digest, .{});
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223",
        &assetPathPrefix(digest),
    );
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{digest});
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hex,
    );
}

test "truncated digest collisions reject only different full digests" {
    const left: Digest = @splat(0x11);
    var right = left;
    try std.testing.expect(!digestsConflict(left, right));
    right[31] = 0x22;
    try std.testing.expect(digestsConflict(left, right));
    right[0] = 0x33;
    try std.testing.expect(!digestsConflict(left, right));
}

test "deterministic gzip normalizes metadata and round trips" {
    const input = "ploof deterministic asset bytes " ** 128;
    var workspace: GzipWorkspace = undefined;
    const bound = try gzipBound(input.len);
    const first = try std.testing.allocator.alloc(u8, bound);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u8, bound);
    defer std.testing.allocator.free(second);
    const first_bytes = try gzipCompress(&workspace, input, first);
    const second_bytes = try gzipCompress(&workspace, input, second);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, first_bytes[4..8]);
    try std.testing.expectEqual(@as(u8, 255), first_bytes[9]);

    var input_reader = std.Io.Reader.fixed(first_bytes);
    var decoder = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});
    var output: [input.len]u8 = undefined;
    var output_writer = std.Io.Writer.fixed(&output);
    const written = try decoder.reader.streamRemaining(&output_writer);
    try std.testing.expectEqual(input.len, written);
    try std.testing.expectEqualStrings(input, output[0..written]);
}

test "diagnostics have stable exit classes" {
    try std.testing.expectEqual(@as(u8, 2), exitStatus(error.InvalidLogicalName));
    try std.testing.expectEqual(@as(u8, 3), exitStatus(error.InputBytesExceeded));
    try std.testing.expectEqual(@as(u8, 4), exitStatus(error.OutputWriteFailed));
    try std.testing.expectEqualStrings(
        "PLOOF-E5014 embedded asset SHA-256 prefix collision\n",
        diagnostic(error.DigestCollision),
    );
}
